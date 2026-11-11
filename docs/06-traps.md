# Traps

**Status:** current 2026-11-11 — phase 1. The ones this project can hit today,
plus those carried forward because they shape the design. Symptom first, cause
second.

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

## PLIO

**Symptom: a PLIO design hangs. No error, no timeout, no output.**
Work through these in order, because they are ordered by how often they are the
cause and how cheap they are to check.

1. **The PLIO name contract.** The string in `input_plio::create("StreamIn", …)`
   must match `stream_connect=…:ai_engine_0.StreamIn` in the linker config. A
   typo is an error in neither file — it is a connection that does not exist.
2. **XRT argument indices.** See the XRT section above. This is `MUTANT=argidx`
   and it is the single most likely cause on a design that used to work.
3. **The width.** 32 bits here, matching `axis_word_t`. A 128-bit PLIO on this
   platform delivers one beat per `readincr()` and starves the kernel.
4. **Then measure instead of guessing**: `make debug_sim && make probe_emu`.

**Symptom: `aiesim` passes and the linked design deadlocks.**
Expected, not surprising. `aiesim` feeds a PLIO from a **text file** — there is
no PL in an AI Engine simulation at all, and the producer it gives you is
perfectly behaved by construction. This is the ladder's most important
limitation. `MUTANT=argidx` demonstrates it in one command.

## The AI Engine toolchain

**Symptom: `make graph` fails with `use of undeclared identifier 'argc'`, on a
line that is obviously correct, during a step called "Compiling PL Block".**
For `--target=hw`, aiecompiler compiles the graph `.cpp` a *second* time as a PS
testbench wrapper, with `-D main\(...\)=ps_main\(...\)` on the command line.
The replacement text is the **literal** `ps_main(...)`, not
`ps_main(__VA_ARGS__)` — so `main(int argc, char **argv)` expands to
`ps_main(...)` and the parameter names are gone. Any body that then mentions
`argc` or `argv` fails to compile.

x86sim is unaffected, so the graph builds and simulates perfectly right up until
the first `make graph`. **Declare the harness `int main(void)`** and take
configuration from the environment. (Hit during this project's own phase 1. The
reference project avoids it by convention — its graph `main`s never reference
their parameters — rather than by knowing why.)

**Symptom: `aiesim` never finishes, or always takes exactly as long as the
timeout.**
It is not stuck. The harness runs `run(-1)` and never calls `end()`, both
deliberately: with `run(N)` the ADF runtime begins tearing down after N
invocations, and during teardown no cycles are driven for the shim DMA, so a
GMIO `wait()` that has not completed never will. `end()` and the cycle timeout
then deadlock each other, and the graph destructor hangs talking to a stopped
event loop — which is why the harness leaves by `_exit()`.

The run is therefore ended from outside, by the wall-clock `timeout`, and takes
exactly that long whatever you set. The verdict comes from the checker reading
the dumped file, **not** from aiesimulator's exit status.

**Symptom: an AIE kernel deadlocks on its first GMIO transfer.**
Three independent causes, each sufficient. Arm the output drain **before**
sending the input — a full output window stalls the kernel, and a stalled kernel
stops consuming the input DMA you are waiting on. Issue **one transfer per
invocation** — `aie2gm_nb()` moves one invocation's worth, not the whole buffer.
And keep **one outstanding async per port** — XRT permits exactly one.

**Symptom: an AIE buffer works on the first firing and not afterwards.**
Buffers are double-buffered: the compiler allocates a ping and a pong at
different addresses, filled by different DMA descriptors (`make graph` prints
them: `buf0`/`buf0d`). A single-invocation test cannot see this. Drive several.

Relatedly: an AIE `input_buffer` is acquired **per firing**, not per logical
unit of work. On the reference project, feeding a kernel's weights once per frame
instead of once per invocation deadlocked it, and the symptom was indistinguishable
from a broken PLIO.

**Symptom: the link fails with `Source file does not exist: libadf_<something>.a`.**
`aiecompiler` writes its output archive as **`libadf.a`**, with that exact name,
into the directory it is run from. The name is not configurable. So two graphs
in one project cannot be distinguished by filename — they need separate
directories (`build/<target>/aie_<graph>/`). Hit during this project's phase 2,
where the compile succeeded and the link then asked for a name nothing had ever
been going to create.

**Symptom: an aiesim PLIO output file has twice as many values as expected, and
every other one is wrong.**
The format interleaves a timestamp line before each beat:

```
T 1388 ns
983583391
T 1392 ns
-426041380
```

A parser that picks out everything which parses as an integer accepts the
timestamps as data — `1388` is a perfectly good `int32`. Parse by line and drop
the `T` lines. (Caught here only because the checker compares lengths; without
that it would have reported a numerical failure and sent someone looking at the
kernel.)

**Symptom: `import argparse` fails with `AssertionError: SRE module mismatch`.**
`source settings64.sh` sets `PYTHONHOME`/`PYTHONPATH` to Vivado's bundled
interpreter, so `python3` runs whatever binary is on `PATH` against *Vivado's*
standard library. The script works fine in a clean shell, which makes it look
like a Makefile problem. Every python call in this project goes through
`$(PYTHON)`, which is `env -u PYTHONHOME -u PYTHONPATH python3`.

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
Three independent causes, each sufficient: `v++` generates `elaborate.sh` with
`xelab --debug off`, so there is no trace information; packaging **regenerates**
that script, dropping any patch you made; and the generated script carries
relative include paths that resolve only in the Vivado project tree where v++
first ran it, so in the copied package tree they dangle and `xelab` fails to
compile the SystemC interface **while still printing "Built simulation
snapshot"**. `make debug_sim` handles all three and fails loudly if the tool's
generated command has changed.

**Symptom: a probe VCD from a hung run contains only the boot phase.**
`xsim` buffers the VCD and flushes it fully only on `close_vcd`, which runs on a
clean exit. A deadlocked run is killed, so what survives is the flushed prefix.
Measured here: a 420 s budget against a real deadlock yielded **91.79 µs of
simulated time** — Linux had not finished booting. `analyze_plio_vcd.py` detects
this by the window length and declines to issue a verdict; without that check it
reported "the producer never produced" about a window in which nothing had
started. **`ap_start` is not a usable discriminator** — it glitches high during
reset and reads as asserted in such a capture.

**Symptom: a probe resolves none of the signals it was told to capture.**
HLS decorates port names: an AXIS argument called `out` becomes `out_r`, and the
decoration depends on the argument name and the tool version. Sweep by wildcard
instead of naming paths. A probe that resolved nothing looks exactly like a link
that moved no data.

**Symptom: an `xrt::graph` design hangs with no error.**
Somebody has to start the graph. `--package.defer_aie_run` means loading the
xclbin does **not** enable the cores, and a graph whose cores are not running
never drains its input PLIO. With PLIO no data passes through the host at all,
which makes it easy to conclude that no AIE-aware host code is needed — it is
needed for exactly one thing. This is `MUTANT=nograph`.

**Symptom: `xrt::run`'s positional call operator throws `bad command state,
can't launch`.**
An AXI4-Stream port occupies an argument slot, so a positional assignment puts
your scalar on the stream port. On XRT 2025.2 this aborts at launch, which is
the good outcome. **Do not count on it** — the same mistake elsewhere produced a
silent zero-trip loop and a hang. Always `set_arg()` by explicit index on a
kernel with a stream port.

## Build hygiene

**Symptom: "it worked yesterday" / two configurations give identical results.**
Flag stamps. A make variable touches no source file. See
[02-build-flow.md](02-build-flow.md).

**Symptom: a stale report tells you about a build that failed.**
Reports survive a failed compile. Check the timestamp, not just the contents.

**Symptom: a Makefile variable expands to nothing, with no warning.**
`:=` expands immediately, so a variable used before it is defined becomes the
empty string silently. In phase 1 this produced `--simulation-cycle-timeout=`
and a simulator that refused to start. If a knob appears to have no effect,
print it: `make print-<KNOB>`.

**Symptom: a feature flag appears to be absent from a build.**
Verify a flag on a build that can actually exercise it. `strings` can report a
false absence.

**Never kill a board run mid-sequence.** On the reference project the next
process then stalls and only a reboot clears it.

## And one that is not a trap

`runtime<ratio>` in an AIE graph is **not** a utilization figure and not a
performance knob — it is a hint to the placer about how much of a core's time a
kernel wants. Reading it as "the design uses 90% of the array" is wrong.
