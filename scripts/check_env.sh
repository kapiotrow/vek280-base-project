#!/bin/bash
# check_env.sh -- validate the toolchain before anything expensive runs.
#
# Every failure here is a failure that would otherwise appear twenty minutes
# into a v++ invocation, as a message about something unrelated. Run it first.
#
# Exit 0 = everything the current phase needs is present.
# Exit 1 = something required is missing (the output names it).

fail=0
warn=0

say_ok()   { printf "  \033[32m  ok\033[0m  %s\n" "$1"; }
say_bad()  { printf "  \033[31mMISSING\033[0m %s\n" "$1"; fail=$((fail+1)); }
say_warn() { printf "  \033[33m  warn\033[0m %s\n" "$1"; warn=$((warn+1)); }

need_var() {
    local name=$1 hint=$2
    if [ -z "${!name}" ]; then
        say_bad "\$$name is not set -- $hint"
    else
        say_ok "\$$name = ${!name}"
    fi
}

need_path() {
    local name=$1 p=${!1}
    if [ -z "$p" ]; then
        say_bad "\$$name is not set"
    elif [ ! -e "$p" ]; then
        say_bad "\$$name points at something that does not exist: $p"
    else
        say_ok "\$$name = $p"
    fi
}

need_tool() {
    local t=$1
    if command -v "$t" >/dev/null 2>&1; then
        say_ok "$t -> $(command -v "$t")"
    else
        say_bad "$t is not on PATH -- did you 'source setup_env.sh'?"
    fi
}

echo ""
echo "=== environment variables ==="
need_path XILINX_VITIS
need_path PLATFORM
need_path COMMON_IMAGE_VERSAL
need_path SDKTARGETSYSROOT
need_var  CXX "source setup_env.sh; the PetaLinux script sets it"

echo ""
echo "=== tools ==="
need_tool v++
need_tool vivado
need_tool aiecompiler
need_tool python3

echo ""
echo "=== files the build reads ==="
for f in "$COMMON_IMAGE_VERSAL/Image" "$COMMON_IMAGE_VERSAL/rootfs.ext4"; do
    if [ -f "$f" ]; then say_ok "$(basename "$f")"; else say_bad "$f"; fi
done
if [ -f "$XILINX_VITIS/include/hls_stream.h" ]; then
    say_ok "HLS headers ($XILINX_VITIS/include)"
else
    say_bad "$XILINX_VITIS/include/hls_stream.h -- needed by 'make test_pl'"
fi

# tune2fs/e2fsck are what `make rootfs` uses to strip the ext4 features that
# v++ --package cannot handle. Without them, packaging produces an image that
# fails to boot -- see docs/06-traps.md.
echo ""
echo "=== rootfs tooling (needed by 'make rootfs') ==="
for t in tune2fs e2fsck debugfs; do
    if command -v $t >/dev/null 2>&1; then say_ok "$t"; else say_bad "$t (install e2fsprogs)"; fi
done

echo ""
echo "=== not needed until later phases ==="
# vitis_hls as a standalone binary is NOT required by this project. In the 2025.2
# unified flow `v++ -c` drives the HLS engine itself, and the cost report phase 4
# reads comes out of the v++ build directory. It is only on PATH if Vitis_HLS was
# installed separately, so a missing one here is information, not a problem.
if command -v vitis_hls >/dev/null 2>&1; then
    say_ok "vitis_hls (standalone; not required -- v++ -c drives HLS)"
else
    say_warn "vitis_hls not on PATH -- fine: v++ -c drives the HLS engine itself"
fi

if [ -d "$DSPLIB_VITIS/dsp" ]; then
    say_ok "\$DSPLIB_VITIS/dsp (phase 3)"
else
    say_warn "\$DSPLIB_VITIS/dsp not found -- fine until phase 3 (the DSPLib FFT)"
fi

echo ""
if [ $fail -gt 0 ]; then
    echo "check_env: $fail problem(s). Fix them before building."
    exit 1
fi
echo "check_env: OK$( [ $warn -gt 0 ] && echo " ($warn warning(s) about later phases)" )"
exit 0
