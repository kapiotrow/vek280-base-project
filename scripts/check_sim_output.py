#!/usr/bin/env python3
"""
check_sim_output.py -- compare a simulator's dump against the golden.

Used by `make x86sim` and `make aiesim`. Exit 0 = match, 1 = mismatch.

TWO THINGS IT REFUSES TO DO, both of which would make it useless:

  - It will not pass on a missing or short file. A checker that finds nothing
    looks exactly like a clean run, which is why the reference project's advice
    is to test an analysis tool against a known-bad input before trusting it.
    `--expect-fail` is how this one is tested: with a mutant armed, a MATCH is
    the failure.

  - It will not pass on an all-poison dump. The harness fills its output buffer
    with 0xA5 before the run, so "the kernel never ran" is distinguishable from
    "the kernel wrote zeros" -- two situations that are otherwise identical in
    a hexdump.
"""

import argparse
import struct
import sys

POISON = 0xA5A5A5A5


def read_u32(path):
    try:
        data = open(path, "rb").read()
    except OSError as e:
        sys.exit("ERROR: cannot read %s: %s" % (path, e))
    if not data:
        sys.exit("ERROR: %s is empty -- the simulation produced no output" % path)
    if len(data) % 4:
        sys.exit("ERROR: %s is not a whole number of int32 (%d bytes)" % (path, len(data)))
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--actual", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--max-report", type=int, default=8)
    ap.add_argument("--expect-fail", action="store_true",
                    help="a mutant is armed: a MATCH is the failure")
    args = ap.parse_args()

    got = read_u32(args.actual)
    want = read_u32(args.golden)

    if len(got) != len(want):
        print("LENGTH MISMATCH: %s has %d int32, golden has %d"
              % (args.actual, len(got), len(want)))
        sys.exit(0 if args.expect_fail else 1)

    poisoned = sum(1 for v in got if v == POISON)
    if poisoned == len(got):
        print("ALL %d ELEMENTS STILL POISONED (0x%08X): nothing was written."
              % (len(got), POISON))
        print("  The kernel almost certainly never ran. This is not a numerical")
        print("  failure -- check the drive order and the GMIO waits first.")
        sys.exit(0 if args.expect_fail else 1)
    if poisoned:
        print("WARNING: %d of %d elements still poisoned -- a PARTIAL run."
              % (poisoned, len(got)))

    bad = [i for i in range(len(got)) if got[i] != want[i]]

    if args.expect_fail:
        if not bad:
            print("EXPECTED FAILURE DID NOT HAPPEN: all %d elements match the golden,"
                  % len(got))
            print("  but a mutant is armed. The comparison is not comparing anything.")
            sys.exit(1)
        print("mutant detected: %d of %d elements differ -- the check works."
              % (len(bad), len(got)))
        for i in bad[:args.max_report]:
            print("  [%d] got 0x%08x want 0x%08x" % (i, got[i], want[i]))
        sys.exit(0)

    if bad:
        print("FAIL: %d of %d elements differ" % (len(bad), len(got)))
        for i in bad[:args.max_report]:
            print("  [%d] got 0x%08x want 0x%08x" % (i, got[i], want[i]))
        if len(bad) > args.max_report:
            print("  ... and %d more" % (len(bad) - args.max_report))
        sys.exit(1)

    print("PASS: all %d elements bit-exact against the golden" % len(got))
    sys.exit(0)


if __name__ == "__main__":
    main()
