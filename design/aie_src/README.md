# `design/aie_src/` — empty until phase 1

The AI Engine graph and kernels live here. Phase 0 is PS + PL only, deliberately:
an image with no AIE graph builds and boots markedly faster, so the first time
you fight packaging and XRT you are fighting only packaging and XRT.

What arrives, and when:

| phase | file | what it is |
|---|---|---|
| 1 | `echo_kernel.{h,cpp}` | one AIE kernel, GMIO in → GMIO out. The hello world |
| 1 | `echo_graph.{h,cpp}` | the graph that holds it, plus the x86sim/aiesim harness |
| 2 | `base_graph.{h,cpp}` | the real graph: PLIO in, PLIO out |
| 3 | `fft_graph.h` | DSPLib `fft_ifft_dit_1ch` wrapped for this geometry |
| 3 | `cmul_kernel.{h,cpp}` | **extension point**: per-bin complex multiply by host-supplied coefficients |
| 2+ | `constraints.aiecst` | PLIO shim placement, if the compiler's choice needs overriding |

Phase 1 is where the two cheapest AIE rungs appear — `x86sim` (functional,
seconds) and `aiesim` (cycle-accurate, minutes) — and neither needs Vivado.
