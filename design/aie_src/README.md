# `design/aie_src/`

The AI Engine graph and its kernels.

## What is here (phase 1)

| file | what it is |
|---|---|
| `echo_kernel.{h,cpp}` | one AIE kernel, in a vectorized and a scalar implementation that must be bit-identical. **This is the extension point.** |
| `echo_graph.h` | the graph: `gmio_echo_in` → kernel → `gmio_echo_out` |
| `echo_graph.cpp` | graph instantiation, plus the harness that serves both x86sim and aiesim |
| `aiesim_data/echo/` | generated stimulus and golden. Gitignored — `make gen_vectors` writes it |

The graph is **not in the xclbin yet**. It joins the system in phase 2, and it
stays out until then on purpose: x86sim and aiesim need no Vivado, so a kernel
can be written, proven bit-exact against a golden, and costed without ever
paying for a link.

## What arrives later

| phase | file | what it is |
|---|---|---|
| 2 | `base_graph.{h,cpp}` | the real graph: PLIO in from `data_src`, PLIO out to `data_sink` |
| 2 | `constraints.aiecst` | PLIO shim placement, if the compiler's choice needs overriding |
| 3 | `fft_graph.h` | DSPLib `fft_ifft_dit_1ch` wrapped for this geometry |
| 3 | `cmul_kernel.{h,cpp}` | per-bin complex multiply by host-supplied coefficients |

## Two rules this directory is built around

**The geometry is never defined twice.** `ECHO_N`, `ECHO_TOTAL`, `ECHO_SHIFT`,
`ECHO_BIAS` and `ECHO_VECTORIZE` all come from one Makefile variable each,
reaching the kernel and the graph through `--Xpreproc` and the Python golden
through a command-line argument. The `#ifndef` fallbacks in `echo_kernel.h`
exist so the headers compile standalone — they are not where the defaults live.

**Keep the scalar branch.** It is slower and that is fine: its job is to be
obviously correct, so the vectorized branch has something to be checked
against. `make x86sim_both` is what makes "bit-identical" a claim rather than a
hope.
