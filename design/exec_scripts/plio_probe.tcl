# plio_probe.tcl -- xsim pre-simulation hook that captures the PL<->AIE AXI4-Stream
# handshake to a VCD.
#
# Sourced by the Vitis-generated tb.tcl through USER_PRE_SIM_SCRIPT, i.e. BEFORE
# `run all`. `make probe_emu` sets that variable.
#
# WHY THIS EXISTS
# ---------------
# A PLIO design that hangs gives you nothing: no error, no timeout, no output.
# The two candidate faults are "the producer never produced" and "the consumer
# never accepted", and they are indistinguishable from the host. TVALID and
# TREADY distinguish them in one glance.
#
# READING THE RESULT
#   TVALID=0 forever        the PL kernel never produced. Look at the
#                           ap_*_blocking_n signals below to see why:
#                             ap_ext_blocking_n=0  stalled on m_axi / DDR
#                             ap_str_blocking_n=0  stalled writing the stream
#                             ap_int_blocking_n=0  stalled on internal dataflow
#                           ...and if ap_done asserted a few cycles after
#                           ap_start with no beats at all, the kernel ran a
#                           zero-trip loop -- which is MUTANT=argidx.
#   TVALID=1, TREADY=0      the AIE side never accepts. Suspect the PLIO name
#                           contract, the width, or a kernel blocked elsewhere.
#   both toggle, count < N  a mid-stream stall. Compare against expected beats.
#
# A NOTE ON WHAT IS AND IS NOT AN RTL WIRE
# ----------------------------------------
# ai_engine_0's AXIS ports are SystemC/TLM sockets -- they have no RTL signals,
# so they cannot be probed. The VitisRegion boundary port is the last RTL point
# before the TLM adapter, and its TREADY is driven BY that adapter. So it is
# exactly the AIE-side backpressure signal, which is what we want anyway.
#
# Parameterised so one script serves both directions and any future kernel:
#   PROBE_CU    PL kernel instance   (default data_src_0)
#   PROBE_PORT  AXIS port base name  (default out)
#   PROBE_VCD   output file          (default plio_probe.vcd)

proc envOr {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default
}

set CU   [envOr PROBE_CU   data_src_0]
set PORT [envOr PROBE_PORT out]
set VCD  [envOr PROBE_VCD  plio_probe.vcd]

set BASE   /tb/DUT/vitis_design_wrapper_i/vitis_design_i
set CUPATH $BASE/VitisRegion/$CU

puts "=== plio_probe: CU=$CU PORT=$PORT VCD=$VCD ==="

# Naming convention: UPPER CASE inside the CU, lower case at the VitisRegion
# boundary. Both are listed because having them in one capture is what shows
# whether anything sits between the two.
#
# label -> path, relative to $BASE. Anything that does not resolve is REPORTED
# and skipped, so a renamed signal degrades to a smaller capture rather than
# taking the emulation down.
set probes [list \
    [list clk            VitisRegion/ap_clk] \
    [list rstn           VitisRegion/ap_rst_n] \
    \
    [list ap_start       VitisRegion/$CU/inst/ap_start] \
    [list ap_done        VitisRegion/$CU/inst/ap_done] \
    [list ap_idle        VitisRegion/$CU/inst/ap_idle] \
    [list ap_ready       VitisRegion/$CU/inst/ap_ready] \
    \
    [list m_arvalid      VitisRegion/$CU/m_axi_gmem_ARVALID] \
    [list m_arready      VitisRegion/$CU/m_axi_gmem_ARREADY] \
    [list m_rvalid       VitisRegion/$CU/m_axi_gmem_RVALID] \
    [list m_rready       VitisRegion/$CU/m_axi_gmem_RREADY] \
]

set found {}
puts "=== plio_probe: resolving named signals ==="
foreach p $probes {
    set label [lindex $p 0]
    set path  $BASE/[lindex $p 1]
    if {[get_objects -quiet $path] ne {}} {
        lappend found $path
        puts [format "  OK      %-12s %s" $label $path]
    } else {
        puts [format "  MISSING %-12s %s" $label $path]
    }
}

# ---------------------------------------------------------------------------
# DISCOVER the AXI4-Stream and stall signals instead of naming them.
#
# THE NAMES ARE NOT PREDICTABLE. HLS decorates port names -- an AXIS argument
# called `out` becomes `out_r` when the bare name would collide with something
# reserved -- and the decoration depends on the kernel, the argument name and
# the tool version. Hardcoding `${PORT}_TVALID` here found nothing on the very
# first run of this probe, and a probe that resolves nothing looks exactly like
# a link that moved no data.
#
# So sweep for them. A wildcard that matches is self-documenting; a wildcard
# that matches nothing is reported as such and is still better than a guess,
# because the analyzer refuses to issue a verdict from an incomplete capture.
# ---------------------------------------------------------------------------
puts "=== plio_probe: discovering AXIS and stall signals ==="
set patterns [list \
    $CUPATH/*TVALID* $CUPATH/*TREADY* $CUPATH/*TDATA* $CUPATH/*TLAST* \
    $CUPATH/inst/*TVALID* $CUPATH/inst/*TREADY* \
    $BASE/VitisRegion/*tvalid* $BASE/VitisRegion/*tready* \
    $CUPATH/inst/ap_*blocking_n \
]
foreach pat $patterns {
    set hits {}
    catch {set hits [get_objects -quiet $pat]}
    foreach h $hits {
        if {[lsearch -exact $found $h] >= 0} { continue }
        lappend found $h
        puts [format "  FOUND   %s" $h]
    }
}

# Vitis names a kernel's pipelined sub-loops grp_<kernel>_Pipeline_<LOOP>_fu_<N>,
# and the _fu_<N> suffix is assigned by HLS -- IT CHANGES BETWEEN BUILDS.
# Hardcoding it would silently stop matching after any rebuild, which is a probe
# that quietly captures less than you think. Sweep for it instead.
puts "=== plio_probe: sweeping for pipelined sub-loops ==="
set subscopes {}
if {[catch {set subscopes [get_scopes -quiet $CUPATH/inst/*]} msg]} {
    puts "  get_scopes unavailable ($msg) -- skipping sub-loop sweep"
}
foreach sc $subscopes {
    set nm [file tail $sc]
    if {![string match "grp_*" $nm]} { continue }
    puts "  loop: $nm"
    foreach sig {ap_start ap_done ap_idle ap_str_blocking_n ap_ext_blocking_n} {
        set path $sc/$sig
        if {[get_objects -quiet $path] ne {}} {
            lappend found $path
            puts [format "    OK    %s" $path]
        }
    }
}

puts "=== plio_probe: logging [llength $found] signals to $VCD ==="

# open_vcd/log_vcd require the snapshot to have been elaborated with
# `xelab --debug typical` (or all). The Vitis-generated elaborate.sh uses
# `--debug off`, which makes log_vcd fail with
#     [Simulator 45-10] The current simulation was compiled without trace information
# and because simulate.sh runs xsim with `-onerror quit`, that error KILLS the
# whole emulation before Linux even boots.
#
# Hence the catch: A PROBE THAT CANNOT ARM MUST NOT TAKE THE RUN DOWN WITH IT.
# Run `make debug_sim` to re-elaborate, then `make probe_emu`.
if {[llength $found] > 0} {
    if {[catch {
        open_vcd $VCD
        log_vcd $found
    } msg]} {
        puts "plio_probe: WARNING -- VCD logging unavailable: $msg"
        puts "plio_probe: run 'make debug_sim' first, then 'make probe_emu'."
    }
    # Also push them into the wave database, so the .wdb is usable in the GUI.
    foreach sg $found { catch {log_wave -quiet $sg} }
} else {
    puts "plio_probe: WARNING -- nothing resolved; check PROBE_CU / PROBE_PORT."
}

# The VCD is written incrementally, so even if the emulation hangs and is killed
# the file is truncated-but-parseable. close_vcd only runs on a clean exit, and
# a hang is exactly the case this tool is for -- so the analyzer must tolerate a
# truncated file, and it does.
puts "=== plio_probe: armed, handing back to tb.tcl ==="
