# Extending the design

**Status:** current 2026-11-11 — phase 2. The recipes below are real; the ones
marked with a phase are written as that phase lands.

## The three extension points

| what you want to change | file |
|---|---|
| the PL datapath | `design/pl_src/data_sink/data_sink.cpp` (phase 4 adds a dedicated `axis_gain` stage) |
| the AIE datapath | `design/aie_src/echo_kernel.cpp` |
| what the answer *should* be | `design/host_app_src/golden.cpp` |

Those three are meant to be edited. Everything else is plumbing.

## Recipe: change the data length

`make ... BASE_N=4096`. It reaches the host through `GCC_FLAGS` and is on the
app's flag stamp, so the ELF rebuilds. Nothing else needs to.

Emulation time scales with it. Keep it small until rung 6.

## Recipe: add a PL kernel

1. `design/pl_src/<name>/<name>.cpp` + `.h`, using `axis_word_t` from
   `design/pl_src/base_axis.h` for any stream port.
2. A `v++ -c` rule and an `.xo` in `KERNEL_XOS` in the Makefile.
3. `nk=` and the `stream_connect=` / `sp=` lines in
   `design/system_configs/base.cfg.in`.
4. `--clock.freqHz $(VPP_CLOCK_FREQ):<name>_0` in `VPP_LINK_FLAGS`.
5. A case in `design/pl_src/test/` so it has a rung-3 test, and a mutant so the
   test is known to be able to fail.

Step 5 is not optional. A kernel with no rung-3 test can only be debugged at
rung 5, which costs about a thousand times more per iteration.

## Recipe: add a host buffer

Allocate with `kernel.group_id(arg_index)` — never a literal bank index. See
[06-traps.md](06-traps.md).

## Recipe: change what the AIE kernel computes

Edit the body of `echo_kernel()` in `design/aie_src/echo_kernel.cpp`, both
branches, then:

```bash
make x86sim_both      # the two branches agree, and both match the golden
```

The golden lives in `golden()` in `scripts/gen_vectors.py`. Change it in the
same commit — a kernel and a model that disagree about what the answer is will
produce a rung that fails for a reason that is not a bug.

Keeping the scalar branch is not optional busywork. It is what makes the
vectorized one checkable, and the check is cheap enough to run on every edit.

## Recipe: add a new constant to the AIE kernel

One Makefile variable, three consumers:

1. `FOO ?= <default>` in the knob block at the top of the Makefile.
2. `AIE_DEFS += --Xpreproc="-DFOO=$(FOO)"` — this is how a make variable
   becomes a `#define` inside an AIE kernel.
3. A `#ifndef FOO` fallback in `echo_kernel.h`, so the file still compiles
   standalone.

If the Python golden needs it too, pass it on the `gen_vectors.py` command line
in the `gen_vectors` target — **not** by re-reading the environment in two
places.

It is already on the AIE flag stamp, because the stamp is built from
`$(AIE_FLAGS)` as a whole. Nothing else to do; that is the point of building the
stamp from the flag list rather than enumerating knobs.

## Recipe: change the AIE geometry

`ECHO_N` is elements per invocation, `ECHO_TOTAL` is how many the harness sends.
`ECHO_N` must divide `ECHO_TOTAL` and be a multiple of the kernel's vector width
(8). The harness fires `ECHO_TOTAL / ECHO_N` times, and more than one firing
matters — see the double-buffering note in `echo_kernel.h`.

```bash
make x86sim ECHO_N=512 ECHO_TOTAL=4096
```

A bigger graph may need a bigger `SIM_WALL_TIMEOUT` for rung 4. The test is
whether the log still contains the `[echo] wrote ... echo_out.bin` line.

## Recipe: add a PLIO port

Four things have to agree, and **three of the four fail silently**:

1. `design/aie_src/base_graph.h` — `input_plio::create("MyPort", plio_32_bits, "my_in.txt")`
2. `design/system_configs/base.cfg.in` — `stream_connect=<cu>.<port>:ai_engine_0.MyPort`
3. The width: `plio_32_bits` must match the PL side's `axis_word_t`.
4. `--clock.freqHz` for the new CU, in `VPP_LINK_FLAGS`.

A mismatch in (1) vs (2) is an error in neither file — it is a connection that
does not exist, and therefore a deadlock. A mismatch in (3) links and starves.

Then: `make graph` (does it compile and place?), `make aiesim` (does the graph
compute?), `make run_emu` (does the link actually move data?). All three, in
that order — and remember that the second one proves nothing about the third.

## Recipe: debug a PLIO that does not move

```bash
make debug_sim                               # once per package
make probe_emu LAUNCH_HW_EMU_EXEC=1          # PL -> AIE direction
make probe_emu LAUNCH_HW_EMU_EXEC=1 PROBE_CU=data_sink_0 PROBE_PORT=in   # the other way
```

The verdict and what each outcome means are in
[`04-dev-cycle.md`](04-dev-cycle.md). If the probe says the producer produced
and data still never arrived, reach for the bisect build:
`make aiesim ECHO_SRC=synth`.

## Recipe: run the array with no PL at all

```bash
make aiesim GRAPH=echo       # GMIO in, GMIO out -- no PL, no linker config
make x86sim GRAPH=echo       # ...and functionally, in seconds
```

`GRAPH=echo` wraps **the same kernel** in a GMIO-only graph. It is the right
place to debug the kernel, because nothing about the PL can be wrong in it.
`GRAPH=base` is the PLIO graph that goes into the xclbin.

Keeping both is worth the handful of lines: the alternative is debugging kernel
arithmetic through a linked system, which costs ~100× per iteration and can fail
for reasons that have nothing to do with your kernel.

## Recipes that need later phases

- change the FFT point size — phase 3
- stream from PL into the array — phase 2
- raise the PL clock, and find out what it costs — phase 4
- go to a 2-D transform with a memory-tile transpose — out of scope; this is
  where the reference project's real complexity lives (memory tiles, and a
  one-sided configuration flag that is a board deadlock rather than a compile
  error). `design/aie_src/` in the reference repo is the worked example.
