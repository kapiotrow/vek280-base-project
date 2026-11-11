# Extending the design

**Status:** stub — the three extension points exist in phase 0; the recipes that
need the AI Engine are written as those phases land.

## The three extension points

| what you want to change | file |
|---|---|
| the PL datapath | `design/pl_src/data_sink/data_sink.cpp` (phase 4 adds a dedicated `axis_gain` stage) |
| the AIE datapath | `design/aie_src/` — empty until phase 1 |
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

## Recipes that need later phases

- add an AIE kernel — phase 1
- change the FFT point size — phase 3
- stream from PL into the array — phase 2
- raise the PL clock, and find out what it costs — phase 4
- go to a 2-D transform with a memory-tile transpose — out of scope; this is
  where the reference project's real complexity lives (memory tiles, and a
  one-sided configuration flag that is a board deadlock rather than a compile
  error). `design/aie_src/` in the reference repo is the worked example.
