# post_sys_link.tcl -- runs inside Vivado after v++ has built the block design.
#
# Invoked through param=compiler.userPostSysLinkOverlayTcl in the linker config.
# This is the hook for anything that has to be said to Vivado directly, which in
# practice means block-design properties v++ exposes no switch for.
#
# Right now it does one thing: set the AI Engine array reference clock to
# 1000 MHz. The platform's default is lower, and the AIE kernels' cycle budgets
# are all quoted against 1 GHz.
#
# NOTE: ai_engine_0 is present in the block design from phase 0 onward, because
# the VEK280 base platform instantiates the array whether or not a graph is
# loaded onto it. So this property does get set even before there is any AIE
# code -- what phase 0 lacks is a libadf.a, not the hardware.
#
# The -quiet guard stays anyway. It costs nothing, and it is what keeps this
# script from failing the link on a platform that does expose the array
# differently.

puts ""
puts "post_sys_link.tcl: pwd = [pwd]"

set aie_cells [get_bd_cells -quiet *ai_engine_0*]
if {[llength $aie_cells] > 0} {
    puts "post_sys_link.tcl: setting AIE_CORE_REF_CTRL_FREQMHZ = 1000 on $aie_cells"
    set_property CONFIG.AIE_CORE_REF_CTRL_FREQMHZ 1000 $aie_cells
} else {
    puts "post_sys_link.tcl: no ai_engine_0 in this design (expected before phase 2) -- skipping"
}
puts ""
