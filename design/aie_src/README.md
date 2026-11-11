# `design/aie_src/`

The AI Engine graphs and their kernel.

## What is here (phase 2)

| file | what it is |
|---|---|
| `echo_kernel.{h,cpp}` | **the** AIE kernel, in a vectorized and a scalar implementation that must be bit-identical. Also carries the `ECHO_SRC=synth` bisect build. **This is the extension point.** |
| `base_graph.{h,cpp}` | PLIO in / PLIO out — **this is what goes into the xclbin** |
| `echo_graph.{h,cpp}` | GMIO in / GMIO out — simulation only, no PL, no linker config |
| `aiesim_data/echo/` | generated stimulus, golden and PLIO text input. Gitignored — `make gen_vectors` writes it |

## Two graphs, one kernel, and why both are kept

`GRAPH=base` is the real design. `GRAPH=echo` wraps the identical kernel in a
GMIO-only graph that needs **no PL, no `stream_connect`, no linker config and no
Vivado**.

That is not redundancy, it is the division of labour the development cycle rests
on. "Does my kernel compute the right thing" is answered on `echo`, in seconds,
where nothing about the PL can be wrong. "Does my plumbing work" is answered on
`base`, and only rung 5 can answer it. Debugging kernel arithmetic through a
linked system costs ~100× per iteration and can fail for reasons that have
nothing to do with your kernel.

Phase 2 moved the kernel from one to the other **without changing a line of it**.
Giving a buffer port `dimensions()` is what makes the compiler insert the
stream-to-buffer DMA.

## What arrives later

See [`../../docs/07-roadmap.md`](../../docs/07-roadmap.md) for the full plan.

| phase | file | what it is |
|---|---|---|
| 3 | `fft_graph.h` | DSPLib `fft_ifft_dit_1ch`, 64-point, **1-D only** |
| 3 | `cmul_kernel.{h,cpp}` | per-bin complex multiply by host-supplied coefficients |
| 3 | — | `gmio_coeff`: the first time the host sends the array data rather than a start command |
| 2+ | `constraints.aiecst` | PLIO shim placement, if the compiler's choice ever needs overriding. Not needed so far |

## Three rules this directory is built around

**The geometry is never defined twice.** `ECHO_N`, `ECHO_TOTAL`, `ECHO_SHIFT`,
`ECHO_BIAS`, `ECHO_VECTORIZE` and `ECHO_SRC_SYNTH` each come from one Makefile
variable, reaching the kernel and graph through `--Xpreproc`, the host through
`-D` (as `BASE_ECHO_*`), and the Python golden through a command-line argument.
The `#ifndef` fallbacks in `echo_kernel.h` exist so the headers compile
standalone — they are not where the defaults live.

**Keep the scalar branch.** It is slower and that is fine: its job is to be
obviously correct, so the vectorized branch has something to be checked against.
`make x86sim_both` is what makes "bit-identical" a claim rather than a hope.

**`int main(void)` in a graph file, never `main(int argc, char **argv)`.** For
`--target=hw` the graph file is recompiled as a PS testbench with
`-D main(...)=ps_main(...)`, where the replacement is the *literal* `...`, so
parameter names are discarded and any reference to `argc`/`argv` fails to
compile — during a step you did not ask for, on a line that is obviously fine.
x86sim is unaffected, so this bites on the first `make graph` and not before.
