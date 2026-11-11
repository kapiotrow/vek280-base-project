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


def read_plio_text(path):
    """Read an aiesim PLIO output file.

    THE FORMAT IS NOT ONE VALUE PER LINE. aiesimulator interleaves a timestamp
    line before each beat:

        T 1388 ns
        983583391
        T 1392 ns
        -426041380

    So the file has twice as many lines as there are data words. A tokeniser
    that just picks out everything that parses as an integer silently accepts
    the timestamps as data -- 1388 is a perfectly good int32 -- and you get
    double the expected count with every other value wrong. (That is exactly
    what happened the first time this ran, and the length check below is what
    caught it.)

    Parse by LINE and drop the timestamp lines.
    """
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        sys.exit("ERROR: cannot read %s: %s" % (path, e))

    vals = []
    for line in lines:
        tok = line.split()
        if not tok:
            continue
        # Timestamp lines: "T <n> ns". Data lines: a single integer.
        if tok[0] == "T":
            continue
        if len(tok) != 1:
            continue
        try:
            vals.append(int(tok[0]) & 0xFFFFFFFF)
        except ValueError:
            continue

    if not vals:
        sys.exit("ERROR: %s parsed to zero values -- the simulation wrote no "
                 "PLIO output. That is 'the stream never delivered', not a "
                 "numerical failure." % path)
    return vals


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
    ap.add_argument("--actual-text", action="store_true",
                    help="--actual is a PLIO text dump, not a .bin")
    ap.add_argument("--golden", required=True)
    ap.add_argument("--max-report", type=int, default=8)
    ap.add_argument("--expect-fail", action="store_true",
                    help="a mutant is armed: a MATCH is the failure")
    ap.add_argument("--synth-period", type=int, default=0,
                    help="ECHO_N: the synthesised index restarts every "
                         "invocation, so the pattern repeats with this period")
    ap.add_argument("--synth-probe", action="store_true",
                    help="ECHO_SRC=synth: this is a DIAGNOSTIC build, not a "
                         "test. Report whether the core ran at all; the golden "
                         "is irrelevant because the kernel deliberately did not "
                         "read its input.")
    args = ap.parse_args()

    got = read_plio_text(args.actual) if args.actual_text else read_u32(args.actual)

    # ---- the bisect build ----
    #
    # ECHO_SRC=synth makes the kernel emit 0xBEEF0000+i WITHOUT reading its
    # input. Comparing that against the golden is meaningless -- it is supposed
    # to differ -- and reporting FAIL for it would train you to ignore the one
    # rung you reached for precisely because you were stuck.
    #
    # The question this build asks is narrower: DID THE CORE RUN AT ALL?
    if args.synth_probe:
        # THE PATTERN REPEATS PER INVOCATION. The kernel's loop index runs
        # 0..ECHO_N-1 on every firing, so a 4-invocation run emits the same 256
        # values four times -- not a 1024-long ramp. Comparing against a global
        # ramp reported "256 of 1024 matched / PARTIAL: the core stopped", which
        # was wrong about a design that had worked perfectly.
        period = args.synth_period if args.synth_period > 0 else len(got)
        expected_pat = [(0xBEEF0000 + (i % period)) & 0xFFFFFFFF
                        for i in range(len(got))]
        hits = sum(1 for a, b in zip(got, expected_pat) if a == b)
        print("BISECT BUILD (ECHO_SRC=synth) -- the kernel did not read its input.")
        print("  synthesised pattern matched: %d of %d elements" % (hits, len(got)))
        print("")
        if hits == len(got):
            print("THE CORE RAN. Output appeared without the kernel reading its")
            print("input, so the core is alive and scheduled. The fault is")
            print("UPSTREAM of it -- in the producer, the stream, or how the")
            print("host configured them.")
            sys.exit(0)
        if hits == 0:
            print("THE CORE DID NOT RUN. Nothing was produced even with the")
            print("input dependence removed, so the input is a red herring.")
            print("Look at whether the graph was started and placed at all.")
            sys.exit(1)
        print("PARTIAL: the core ran for some of the stream and stopped.")
        sys.exit(1)

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
