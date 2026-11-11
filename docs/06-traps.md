# Traps

**Status:** current 2026-11-11 — the ones phase 0 can hit, plus those carried
forward because they shape the design. Symptom first, cause second.

Every entry here cost somebody real time, mostly on the reference project this
is derived from. None of them produces a sensible error message.

## XRT and the host

**Symptom: the stream delivers nothing. TVALID never rises. The consumer waits
forever.**
An AXI4-Stream port **occupies a positional argument slot** in the kernel's
`kernel.xml`, even though it is not a settable register. For
`data_src(in, out_stream, n)` the indices are `in`=0, `out_stream`=1, `n`=2, so
`run(bo, n)` writes `n` into the *stream port* and leaves the real `n` at its
reset value of zero. The kernel runs a zero-trip loop and asserts `ap_done` a
few cycles after `ap_start`.

The symptom points at the AIE array, the PLIO width and the shim placement, and
it is none of those. On the reference project this consumed about a week.
**Always `set_arg()` by explicit index.** `design/host_app_src/base_host.cpp`
declares the indices in a named block for this reason, and they were verified
against the generated `kernel.xml`, not assumed.

**Symptom: the host reads zeros, or its poison pattern comes back unchanged.**
Memory bank. The VEK280 has **LPDDR4**, so its sptags are `LPDDR1`/`LPDDR2`, not
`DDR` — an `sp=` line naming `DDR` does not link, and copying a config from a
VCK190 example is the usual way to find that out. On the host side, take the
bank from `kernel.group_id(arg_index)` rather than passing a literal index; a
hardcoded `0` is right by luck or wrong silently.

The `sp=` left-hand side names the m_axi **argument** (`in`, `out`), not the HLS
bundle (`gmem`). Some tool versions accept the bundle name and some ignore it.

**Symptom: everything works but is inexplicably slow.**
Never compute against a BO mapping. Measured on the reference design: BO writes
run at ~3470 MB/s and reads at ~696. Five sites that read back through a mapping
cost ~33 ms per frame. Fill a heap buffer, `memcpy` it in, `sync()`.

**Symptom: each kernel launch costs about half a second.**
The CU completion interrupt is never delivered on this platform, so every KDS
launch pays ~503 ms. The fix is to drive the CU as a user-managed IP through
`xrt::ip` — writing `ap_start` and polling `ap_done` yourself — which was worth
**20.6×** on frame rate in the reference design. This only appears on real
hardware; emulation shows nothing. Phase 4 covers it.

## Packaging and boot

**Symptom: packaging succeeds; every run afterwards dies during boot.**
`v++ --package` writes into the rootfs image, and the 2025.2 common-image
`rootfs.ext4` carries ext4 features its packaging step mishandles. The result is
a corrupted filesystem and a design that looks broken and is not.
`make rootfs` takes a **copy** and strips the features:

```
tune2fs -O ^orphan_file,^metadata_csum_seed,^metadata_csum
```

Working on a copy matters — you will need the pristine image again.

**Symptom: on real hardware, XRT cannot find the device.**
`XCL_EMULATION_MODE` was baked into the image. It must be set for `hw_emu` and
unset for `hw`; the Makefile generates `run_script.sh` per target for this
reason. For extra credit, the reference project's version both exported it
unconditionally *and* misspelled it (`XLC_` for `XCL_`) — and the typo is the
only reason emulation still worked, because XRT was inferring the mode from the
packaged xclbin instead.

**Symptom: a setting in `xrt.ini` has no effect.**
Two independent causes. An unrecognised key is **silently ignored** — no warning
for typos, none for keys that do not exist in this release. Confirm on the
board: `strings /usr/lib/libxrt_core.so* | grep -i <key>`. And the file must be
in the **process's working directory**, which is the FAT partition root; a copy
in a subdirectory is inert.

## Simulation

**Symptom: `make test_pl` hangs with no output at all.**
`hls::stream::read()` on an empty stream does not warn and does not return a
default value. It blocks on a condition variable, forever. `test_pl` therefore
checks the stream depth *before* draining — see `MUTANT=short`.

**Symptom: hw_emu wall-clock time is absurd / meaningless.**
It is simulator time, not hardware time. Its **simulated PL cycle counts are
RTL-accurate** and are a real measurement. Do not quote one as the other.

**Symptom: `aiesim` passes, hardware deadlocks.** *(from phase 1)*
`aiesim` feeds PLIO from text files — it does not simulate the PL at all. This
is the ladder's most important limitation and the reason phase 2 exists.

**Symptom: waveform capture produces nothing, but the log says it succeeded.**
*(from phase 2)* Three independent causes, each sufficient: `v++` generates
`elaborate.sh` with `xelab --debug off`, so there is no trace information;
packaging **regenerates** that script, dropping any patch you made; and the
generated script carries relative include paths that resolve only in the Vivado
project tree where v++ first ran it, so in the copied package tree they dangle
and `xelab` fails to compile the SystemC interface **while still printing
"Built simulation snapshot"**.

## Build hygiene

**Symptom: "it worked yesterday" / two configurations give identical results.**
Flag stamps. A make variable touches no source file. See
[02-build-flow.md](02-build-flow.md).

**Symptom: a stale report tells you about a build that failed.**
Reports survive a failed compile. Check the timestamp, not just the contents.

**Symptom: a feature flag appears to be absent from a build.**
Verify a flag on a build that can actually exercise it. `strings` can report a
false absence.

**Never kill a board run mid-sequence.** On the reference project the next
process then stalls and only a reboot clears it.

## And one that is not a trap

`runtime<ratio>` in an AIE graph is **not** a utilization figure and not a
performance knob — it is a hint to the placer about how much of a core's time a
kernel wants. Reading it as "the design uses 90% of the array" is wrong.
