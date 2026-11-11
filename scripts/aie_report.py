#!/usr/bin/env python3
"""
aie_report.py <Work dir> -- read the three things an AIE graph compile tells you
that nothing cheaper can, and say plainly what kind of number each one is.

Run by `make graph`. It parses the compiler's own reports; it measures nothing.

  1. RESOURCES        how many cores and tiles, out of the array's 304 and 76.
  2. PLACEMENT        where each kernel landed, and whether its buffers are
                      double-buffered (a ping and a pong at different addresses).
  3. THE SCHEDULE     how many VLIW bundles the inner loop was scheduled into.

ON (3), AND THIS IS THE WHOLE POINT OF THE DISTINCTION:

The schedule is what the compiler BELIEVES the loop costs -- a static count of
instruction bundles, with no DMA contention, no stream back-pressure and no
competition for memory banks. It is a ceiling on how good the code can be and a
floor on what it will cost. It is NOT a measurement.

`make aiesim` gives the simulated figure, which includes the DMAs and is the
honest one. On the reference project the two differed enough that every AIE cost
number in its documentation is labelled with which of the two it is. Keep that
habit: a figure whose provenance is unstated will eventually be quoted as the
other kind.
"""

import csv
import os
import re
import sys

# VEK280 / AIE-ML array. Quoted so a utilization line means something.
ARRAY_CORES = 304
ARRAY_MEMTILES = 76


def section(title):
    print("    %s" % title)


def read_complexity(work):
    path = os.path.join(work, "reports", "complexity.csv")
    if not os.path.exists(path):
        return None
    d = {}
    with open(path) as f:
        for row in csv.reader(f):
            if len(row) >= 2:
                d[row[0].strip()] = row[1].strip()
    return d


def report_resources(work):
    d = read_complexity(work)
    if not d:
        section("resources: no complexity.csv -- did the compile finish?")
        return
    cores = int(d.get("total_num_cores", 0))
    tiles = int(d.get("total_num_tiles", 0))
    util = d.get("total_core_util", "?")
    section("resources")
    print("      cores   %d of %d  (%.1f%% of the array)"
          % (cores, ARRAY_CORES, 100.0 * cores / ARRAY_CORES))
    print("      tiles   %d" % tiles)
    print("      kernels %s   gmio %s   plio %s"
          % (d.get("total_num_kernels", "?"),
             d.get("gmio_node_count", "?"), d.get("plio_node_count", "?")))
    print("      total_core_util = %s -- this is the runtime<ratio> HINT you" % util)
    print("      wrote in the graph, echoed back. It is NOT a utilization")
    print("      measurement and NOT a performance figure.")


def report_placement(work):
    path = os.path.join(work, "reports")
    rep = None
    for f in os.listdir(path) if os.path.isdir(path) else []:
        if f.endswith("_mapping_analysis_report.txt"):
            rep = os.path.join(path, f)
            break
    if not rep:
        return
    text = open(rep).read()

    section("placement")
    for m in re.finditer(r"^(i\d+):(\S+)\s+(CR\(\d+,\d+\)|IO\(\d+\))", text, re.M):
        print("      %-14s %s" % (m.group(2), m.group(3)))

    # buf0 / buf0d is a ping/pong pair: the same logical port, two addresses.
    bufs = re.findall(r"^\S+\s+\S+\s+\S+\s+\S+\s+(buf\S+)", text, re.M)
    pairs = sorted({b[:-1] for b in bufs if b.endswith("d")})
    if pairs:
        print("      double-buffered ports: %s" % ", ".join(pairs))
        print("      (a ping and a pong at DIFFERENT addresses, filled by")
        print("       different DMA descriptors -- which is why a one-firing")
        print("       test cannot catch a kernel that only works the first time)")


def report_schedule(work):
    """Count VLIW bundles in each kernel's scheduled inner loop.

    In a .lst the scheduled assembly is bracketed by .begin_of_loop and
    .end_of_loop, and every line beginning with a cycle number is one VLIW
    bundle = one cycle.
    """
    aie = os.path.join(work, "aie")
    if not os.path.isdir(aie):
        return
    lsts = []
    for root, _dirs, files in os.walk(aie):
        for f in files:
            if f.endswith(".lst") and not f.endswith(".o.lst"):
                lsts.append(os.path.join(root, f))
    if not lsts:
        return

    section("schedule (the compiler's static count, NOT a measurement)")
    bundle = re.compile(r"^\s+\d+\s+0x")
    for lst in sorted(lsts):
        text = open(lst, errors="replace").read().splitlines()
        depth, loops = 0, []
        count = 0
        for line in text:
            if ".begin_of_loop" in line:
                depth += 1
                count = 0
                continue
            if ".end_of_loop" in line:
                if depth > 0 and count:
                    loops.append(count)
                depth = max(0, depth - 1)
                continue
            if depth > 0 and bundle.match(line):
                count += 1
        if loops:
            inner = min(loops)
            print("      %s: innermost loop body = %d VLIW bundle%s = %d cycle%s"
                  " per iteration" % (os.path.basename(lst), inner,
                                      "" if inner == 1 else "s",
                                      inner, "" if inner == 1 else "s"))
            if len(loops) > 1:
                print("        (%d scheduled loops in this core: %s)"
                      % (len(loops), ", ".join(str(x) for x in loops)))
        else:
            print("      %s: no scheduled loop found" % os.path.basename(lst))


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: aie_report.py <Work dir>")
    work = sys.argv[1]
    if not os.path.isdir(work):
        print("    (no Work directory at %s)" % work)
        return
    report_resources(work)
    report_placement(work)
    report_schedule(work)


if __name__ == "__main__":
    main()
