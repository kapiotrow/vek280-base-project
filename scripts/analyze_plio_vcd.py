#!/usr/bin/env python3
"""
analyze_plio_vcd.py -- read a plio_probe.vcd and say what the AXI4-Stream did.

Usage: analyze_plio_vcd.py <plio_probe.vcd> [expected_beats]

Answers the four questions a hung PLIO design raises, in order:

  1. did the producer ever assert TVALID?
  2. did the consumer ever assert TREADY?
  3. how many beats actually completed (TVALID & TREADY on a rising clock)?
  4. if it stalled, what was the kernel blocked on?

THE VCD IS EXPECTED TO BE TRUNCATED. The probe writes it incrementally and the
case this tool exists for is a hang, which ends with the simulation being
killed. A parser that needs a well-formed trailer would fail precisely when it
is needed.

ONE THING THIS TOOL WILL NOT DO: report a clean result for a file it could not
find signals in. A probe that resolved nothing and a link that moved no data
produce the same empty VCD, and the difference matters -- so an absent signal is
reported as absent, never as zero.
"""

import re
import sys
from collections import OrderedDict


def parse_vcd(path):
    """Return (id -> [names], [(time, id, value)]).

    An id maps to a LIST of names, not one: xsim gives aliased nets the same VCD
    identifier. `data_src_0/out_TVALID` and `VitisRegion/out_tvalid` sharing an
    id means they are the same net with nothing in between -- which is itself
    useful evidence, so it must not be flattened away.
    """
    names = OrderedDict()
    changes = []
    time = 0
    var_re = re.compile(r"^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(.+?)\s*\$end")

    try:
        fh = open(path, "r", errors="replace")
    except OSError as e:
        sys.exit("ERROR: cannot read %s: %s\n"
                 "       Did the run actually arm the probe? Look for\n"
                 "       '=== plio_probe: armed' in the emulation log." % (path, e))

    with fh:
        in_defs = True
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                m = var_re.match(line)
                if m:
                    _w, ident, name = m.groups()
                    names.setdefault(ident, []).append(name.strip())
                    continue
                if line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line.startswith("#"):
                try:
                    time = int(line[1:])
                except ValueError:
                    pass
                continue
            if line[0] in "01xzXZ" and len(line) > 1:
                changes.append((time, line[1:], line[0]))
            elif line[0] in "bB":
                parts = line.split()
                if len(parts) == 2:
                    changes.append((time, parts[1], parts[0][1:]))
    return names, changes


def find_id(names, *suffixes):
    """Find the VCD id whose name ends with any of `suffixes` (case-insensitive)."""
    for ident, nms in names.items():
        for n in nms:
            low = n.lower()
            for suf in suffixes:
                if low.endswith(suf.lower()):
                    return ident
    return None


def timeline(changes, ident):
    """[(time, value)] for one id, in order."""
    return [(t, v) for (t, i, v) in changes if i == ident]


def value_at(tl, t):
    """The value of a timeline at time t (last change at or before t)."""
    val = "x"
    for (tt, vv) in tl:
        if tt > t:
            break
        val = vv
    return val


def ever_high(tl):
    return any(v == "1" for (_t, v) in tl)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("expected_beats", nargs="?", type=int, default=None)
    ap.add_argument("--max-report", type=int, default=8)
    ap.add_argument("--min-window-ps", type=float, default=10e9,
                    help="simulated-time window below which the capture is "
                         "treated as boot-only (default 10 ms)")
    args = ap.parse_args()
    path = args.vcd
    expected = args.expected_beats

    names, changes = parse_vcd(path)
    if not names:
        sys.exit("ERROR: %s declares no signals. The probe did not arm.\n"
                 "       Run 'make debug_sim' (the snapshot needs --debug typical),\n"
                 "       then 'make probe_emu'." % path)

    print("plio_probe: %d signals, %d value changes" % (len(names), len(changes)))

    clk = find_id(names, "ap_clk")
    tv = find_id(names, "_tvalid")
    tr = find_id(names, "_tready")

    missing = [n for n, i in (("ap_clk", clk), ("TVALID", tv), ("TREADY", tr)) if i is None]
    if missing:
        print("")
        print("CANNOT ANALYSE: these signals are not in the capture: %s"
              % ", ".join(missing))
        print("  That is a PROBE problem, not a design result -- check")
        print("  PROBE_CU / PROBE_PORT against the names in the emulation log.")
        print("  Signals that ARE present:")
        for nms in list(names.values())[:40]:
            print("    %s" % nms[0])
        sys.exit(2)

    clk_tl, tv_tl, tr_tl = timeline(changes, clk), timeline(changes, tv), timeline(changes, tr)

    print("")
    print("  TVALID ever asserted : %s" % ("YES" if ever_high(tv_tl) else "NO"))
    print("  TREADY ever asserted : %s" % ("YES" if ever_high(tr_tl) else "NO"))

    # Count beats: TVALID & TREADY sampled on each rising clock edge.
    beats = 0
    for (t, v) in clk_tl:
        if v != "1":
            continue
        if value_at(tv_tl, t) == "1" and value_at(tr_tl, t) == "1":
            beats += 1
    print("  beats completed      : %d%s"
          % (beats, "" if expected is None else " of %d expected" % expected))

    # The kernel's own stall reasons, if they were captured.
    print("")
    for label, suf in (("stalled on m_axi/DDR", "ap_ext_blocking_n"),
                       ("stalled on a stream", "ap_str_blocking_n"),
                       ("stalled on dataflow", "ap_int_blocking_n")):
        i = find_id(names, suf)
        if i is None:
            continue
        tl = timeline(changes, i)
        # blocking_n is LOW while blocked.
        blocked = any(v == "0" for (_t, v) in tl)
        print("  %-22s : %s" % (label, "YES" if blocked else "no"))

    # NOTE THE BARE NAMES. A VCD $var declaration carries the LEAF name, with
    # the hierarchy expressed as separate $scope records -- so matching on
    # "inst/ap_start" matches nothing, which is how these lines silently failed
    # to print on this tool's first real run. Several scopes declare an
    # `ap_start` (the CU and each pipelined sub-loop); the first declared is the
    # CU's, which is the one wanted here.
    ap_start_id = find_id(names, "ap_start")
    ap_done_id = find_id(names, "ap_done")
    for label, i in (("ap_start", ap_start_id), ("ap_done", ap_done_id)):
        if i is None:
            continue
        tl = timeline(changes, i)
        print("  %-22s : %s" % (label, "asserted" if ever_high(tl) else "NEVER asserted"))

    # ---- is the capture even usable? ----
    #
    # THIS CHECK EXISTS BECAUSE THE TOOL GOT IT WRONG WITHOUT IT. On its first
    # real run against a genuine deadlock it reported "the producer never
    # produced" -- confidently, and about the wrong thing. The capture covered
    # 91.79 us of SIMULATED time, which is the boot phase; the application had
    # not started yet, so of course nothing had been produced.
    #
    # WHY THE CAPTURE IS SHORT. xsim buffers the VCD and only flushes fully on
    # close_vcd, which runs on a clean exit. A deadlocked emulation never exits
    # cleanly -- it gets killed -- so what survives is the flushed PREFIX. In a
    # full-system emulation the prefix is Linux booting.
    #
    # THE DISCRIMINATOR IS THE LENGTH OF THE CAPTURE WINDOW, not a signal.
    #
    # ap_start looked like the natural choice and is not usable: it glitches
    # high during reset, so `ever asserted` is true in a capture that stops long
    # before the CU is ever launched. (Measured: ap_start reads as asserted in a
    # 91.79 us window during which Linux had not finished booting.)
    #
    # Simulated time is unambiguous. Booting Linux in a full-system emulation
    # takes on the order of hundreds of milliseconds to seconds of SIMULATED
    # time; an application-phase capture is therefore many milliseconds long at
    # minimum. A window four orders of magnitude shorter than that cannot
    # contain a running application, whatever the signals appear to say.
    last_t = max((t for (t, _i, _v) in changes), default=0)
    print("")
    print("  capture window       : 0 .. %d ps (%.2f us of simulated time)"
          % (last_t, last_t / 1e6))

    # 10 ms of simulated time. Generous: the real boot is far longer, so this
    # does not reject a capture that genuinely reached the application, and it
    # comfortably rejects a boot-only prefix. Override with --min-window-ps if
    # your design runs standalone with no OS.
    covers_app = last_t >= args.min_window_ps

    if not covers_app:
        print("")
        print("INSUFFICIENT CAPTURE -- NO VERDICT.")
        print("  The capture spans %.2f us of simulated time, below the %.2f ms"
              % (last_t / 1e6, args.min_window_ps / 1e9))
        print("  needed to contain a booted Linux running the application. So")
        print("  the application had not begun, and nothing here says anything")
        print("  about the stream.")
        print("")
        print("  (Do not be reassured by the signal lines above. ap_start reads")
        print("   as 'asserted' in a window like this because it glitches during")
        print("   reset -- which is exactly why the window, not a signal, is the")
        print("   test used here.)")
        print("")
        print("  xsim buffers the VCD and flushes it fully only on close_vcd,")
        print("  which runs on a CLEAN exit. A deadlocked run is killed instead,")
        print("  so what survives is the flushed prefix -- in a full-system")
        print("  emulation, that is Linux booting.")
        print("")
        print("  Options, in order of how well they work:")
        print("    * Raise PROBE_WALL_TIMEOUT a lot and re-run. The capture has")
        print("      to reach the application before the kill, and tracing makes")
        print("      the emulation substantially slower than an untraced one.")
        print("    * Open the .wdb in the Vivado waveform viewer. log_wave is")
        print("      armed alongside log_vcd and the wave database is written")
        print("      continuously, so it covers more than the VCD does.")
        print("    * Narrow the question instead: `make aiesim ECHO_SRC=synth`")
        print("      distinguishes 'the input never delivered' from 'the core")
        print("      never ran' without needing a waveform at all.")
        sys.exit(2)

    # ---- the verdict ----
    print("")
    if not ever_high(tv_tl):
        print("VERDICT: THE PRODUCER NEVER PRODUCED.")
        print("  TVALID never rose, so nothing was ever offered to the consumer.")
        print("  The fault is upstream of the stream, in the PL kernel or in how")
        print("  the host configured it. Check the blocking_n lines above; if")
        print("  ap_done asserted with zero beats, the kernel ran a zero-trip")
        print("  loop, which means its trip count was never written -- see the")
        print("  XRT argument-index trap in docs/06-traps.md.")
    elif not ever_high(tr_tl):
        print("VERDICT: THE CONSUMER NEVER ACCEPTED.")
        print("  TVALID rose but TREADY never did. Suspect, in this order: the")
        print("  PLIO name contract between base_graph.h and base.cfg.in; the")
        print("  stream width; and the consumer being blocked on something else.")
    elif expected is not None and beats < expected:
        print("VERDICT: MID-STREAM STALL -- %d of %d beats." % (beats, expected))
        print("  Both sides handshook at least once, so the link works and")
        print("  something later stopped it. A consumer that asks for more beats")
        print("  than the producer sends looks exactly like this.")
    else:
        print("VERDICT: the stream moved%s."
              % ("" if expected is None else " all %d beats" % expected))
        print("  If the design still failed, the fault is not in this handshake.")


if __name__ == "__main__":
    main()
