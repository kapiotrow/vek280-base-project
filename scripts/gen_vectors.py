#!/usr/bin/env python3
"""
gen_vectors.py -- generate the simulation stimulus AND its golden output.

ONE script produces both, from one function each, because a stimulus and a
golden that are written separately will eventually describe different
experiments and nothing will say so.

Writes, into --out-dir (default design/aie_src/aiesim_data/echo/):

    in.bin         ECHO_TOTAL little-endian int32 -- for the GMIO harness
    golden.bin     ECHO_TOTAL little-endian int32 -- what the kernel must produce
    stream_in.txt  the same stimulus as decimal text, one value per line --
                   this is what aiesim feeds a PLIO with INSTEAD OF A PL KERNEL

Geometry and the kernel constants come from the environment so that the Makefile
is the single source of truth for every default:

    ECHO_TOTAL ECHO_SHIFT ECHO_BIAS

CROSS-IMPLEMENTATION CHECK
--------------------------
The stimulus is also implemented in C++, in design/host_app_src/golden.cpp,
because the host needs it from phase 2 on. Two implementations of one contract
is exactly the situation that produces a silent mismatch, so `--check-cpp FILE`
compares this generator against a dump from the C++ one and fails if they
differ. `make gen_vectors` runs that check; it is the only thing standing
between the two copies and a slow divergence.
"""

import argparse
import os
import struct
import sys

MASK32 = 0xFFFFFFFF


def fill_input(n):
    """Mirror of base_fill_input() in design/host_app_src/golden.cpp.

    Numerical Recipes LCG followed by an xorshift. Deterministic from a fixed
    seed, full 32-bit range, non-monotone, distinct over the lengths used here
    -- which is what makes dropped, duplicated and reordered words visible. A
    plain counter would be none of those things; see the comment in golden.cpp.

    Returns unsigned values; the .bin is written as raw 32-bit words, so the
    signed/unsigned distinction only matters to whoever interprets it.
    """
    out = []
    s = 0x12345678
    for _ in range(n):
        s = (1664525 * s + 1013904223) & MASK32
        v = s
        v ^= v >> 13
        out.append(v & MASK32)
    return out


def to_signed(u):
    return u - (1 << 32) if u & 0x80000000 else u


def golden(words, shift, bias):
    """Mirror of echo_kernel: out = (in >> shift) + bias, on SIGNED int32.

    The shift is ARITHMETIC, matching both the kernel's `>>` on int32 and
    aie::downshift. Python's >> on a negative int is already arithmetic, so
    converting to signed first is the whole of it -- and getting that wrong is
    the single most likely way for this model to disagree with the hardware.
    """
    res = []
    for u in words:
        v = to_signed(u) >> shift
        v = (v + bias) & MASK32
        res.append(v)
    return res


def write_plio_text(path, words):
    """Write the stimulus in the text format aiesim feeds a PLIO from.

    For plio_32_bits carrying int32, that is one SIGNED decimal value per line.

    THIS FILE IS THE REASON PHASE 2 EXISTS. When aiesim runs a PLIO graph it
    reads this file -- there is no PL in an AIE simulation at all. So the
    producer aiesim gives the graph is perfectly behaved and infinitely patient,
    which is exactly what a real data_src under a buggy host is not. A graph can
    pass aiesim against this file and deadlock the instant it is linked.
    """
    with open(path, "w") as f:
        for u in words:
            f.write("%d\n" % to_signed(u))
    print("  wrote %-14s %5d lines (PLIO text -- aiesim's fake producer)"
          % (os.path.basename(path), len(words)))


def write_u32(path, words):
    with open(path, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    print("  wrote %-10s %5d int32  (%d bytes)" % (os.path.basename(path), len(words), 4 * len(words)))


def read_u32(path):
    data = open(path, "rb").read()
    if len(data) % 4:
        sys.exit("ERROR: %s is not a whole number of int32" % path)
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="design/aie_src/aiesim_data/echo")
    ap.add_argument("--total", type=int, default=int(os.environ.get("ECHO_TOTAL", 1024)))
    ap.add_argument("--shift", type=int, default=int(os.environ.get("ECHO_SHIFT", 1)))
    ap.add_argument("--bias", type=int, default=int(os.environ.get("ECHO_BIAS", 1000)))
    ap.add_argument("--check-cpp", metavar="FILE",
                    help="compare this generator's stimulus against a dump from "
                         "the C++ base_fill_input(); exit 1 if they differ")
    args = ap.parse_args()

    stim = fill_input(args.total)

    if args.check_cpp:
        if not os.path.exists(args.check_cpp):
            sys.exit("ERROR: --check-cpp %s does not exist. Run 'make test_host' first."
                     % args.check_cpp)
        cpp = read_u32(args.check_cpp)
        n = min(len(cpp), len(stim))
        if n == 0:
            sys.exit("ERROR: --check-cpp dump is empty")
        bad = [i for i in range(n) if cpp[i] != stim[i]]
        if bad:
            i = bad[0]
            print("CROSS-CHECK FAILED: the Python and C++ stimulus generators disagree.")
            print("  first difference at [%d]: C++ 0x%08x, Python 0x%08x (%d of %d differ)"
                  % (i, cpp[i], stim[i], len(bad), n))
            print("  fill_input() in scripts/gen_vectors.py and base_fill_input() in")
            print("  design/host_app_src/golden.cpp implement ONE contract. Make them agree.")
            sys.exit(1)
        print("  cross-check OK: %d words identical to the C++ generator" % n)

    os.makedirs(args.out_dir, exist_ok=True)
    print("gen_vectors: total=%d shift=%d bias=%d -> %s"
          % (args.total, args.shift, args.bias, args.out_dir))
    write_u32(os.path.join(args.out_dir, "in.bin"), stim)
    write_u32(os.path.join(args.out_dir, "golden.bin"), golden(stim, args.shift, args.bias))
    write_plio_text(os.path.join(args.out_dir, "stream_in.txt"), stim)


if __name__ == "__main__":
    main()
