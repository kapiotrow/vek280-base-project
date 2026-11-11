# Extending the design

**Status:** current 2026-11-11 — phase 1. The AIE recipes below are real; the
ones marked with a phase are written as that phase lands.

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

## Recipes that need later phases

- stream from PL into the array (PLIO) — phase 2
- change the FFT point size — phase 3
- stream from PL into the array — phase 2
- raise the PL clock, and find out what it costs — phase 4
- go to a 2-D transform with a memory-tile transpose — out of scope; this is
  where the reference project's real complexity lives (memory tiles, and a
  one-sided configuration flag that is a board deadlock rather than a compile
  error). `design/aie_src/` in the reference repo is the worked example.
