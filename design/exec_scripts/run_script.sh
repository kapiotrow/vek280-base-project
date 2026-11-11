#!/bin/bash
# run_script.sh -- the script that runs ON the target, in emulation or on the
# board. Packaged onto the SD card by `make package`.
#
# THIS FILE IS A TEMPLATE. @EMU_MODE@ is substituted by the Makefile at package
# time: "hw_emu" for TARGET=hw_emu, and EMPTY for TARGET=hw.
#
# That substitution is load-bearing. XCL_EMULATION_MODE tells XRT to open the
# emulation driver instead of the real device, so a hardware image built from a
# verbatim copy of this file cannot talk to its own hardware. The reference
# project shipped a version that exported the variable unconditionally AND
# misspelled it (XLC_ for XCL_) -- the typo is the only reason hw_emu still
# worked, because XRT was inferring emulation from the packaged xclbin instead.
# Both halves are fixed here.

echo ""
date
echo ""
SECONDS=0

EMU_MODE="@EMU_MODE@"
if [ -n "$EMU_MODE" ]; then
    export XCL_EMULATION_MODE=$EMU_MODE
    echo "INFO: XCL_EMULATION_MODE=$XCL_EMULATION_MODE"
    echo "INFO: wall-clock timings from this run are SIMULATOR time and mean nothing."
else
    unset XCL_EMULATION_MODE
    echo "INFO: real hardware -- XCL_EMULATION_MODE not set"
fi
export XILINX_XRT=/usr

./base_host.elf a.xclbin
return_code=$?

duration=$SECONDS

echo ""
if [ $return_code -ne 0 ]; then
    echo "ERROR: run failed, RC=$return_code"
else
    echo "INFO: TEST PASSED, RC=0"
fi
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
date
echo ""

exit $return_code
