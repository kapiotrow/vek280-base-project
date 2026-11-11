# Data movement

**Status:** stub — phase 0 only has `m_axi` and AXI4-Lite. PLIO arrives in
phase 2 and GMIO in phase 1; this page is written then, when there is something
measured to say.

## What exists in phase 0

| mechanism | used for | where |
|---|---|---|
| `m_axi` | PL kernel reads/writes LPDDR directly | `data_src.in`, `data_sink.out` |
| AXI4-Lite | the host setting scalars and `ap_start`/`ap_done` | both kernels, `bundle=control` |
| AXI4-Stream | kernel to kernel, and later kernel to AIE | `data_src.out` → `data_sink.in` |

## What arrives later

- **GMIO** (phase 1) — AIE to and from DDR, driven by the APU. The easiest way
  to get data into the array, and the one that needs no PL at all.
- **PLIO** (phase 2) — the PL↔AIE stream. 32 bits wide in this project,
  deliberately: a 128-bit PLIO on this platform delivers one beat per
  `readincr()` on the AIE side and starves the kernel.

The comparison table — which mechanism to use, and what each one measured —
belongs here once both have run.
