# VEK280 base project

A minimal, documented, end-to-end design for the AMD Versal VEK280, intended as
a starting point for projects that use the **PS**, the **PL** and the **AI
Engine** together.

It is deliberately small. The design in it computes almost nothing — what the
project is actually for is the **development cycle**: knowing which of the five
or six ways to check something is the right one, and what each of them cannot
see. On this toolchain that is where the time goes.

> **Read [`docs/04-dev-cycle.md`](docs/04-dev-cycle.md) first.** If you read
> nothing else, read that.

## Status: phase 0 — PS + PL, no AI Engine yet

The project is built in phases, each one a working design, each one adding both
a piece of hardware and the verification rung that goes with it.

| phase | design | rungs it introduces |
|---|---|---|
| **0 (here)** | `data_src` → AXI4-Stream → `data_sink`, driven by XRT | `check_env`, HLS C-sim, hw_emu |
| 1 | a GMIO echo kernel on the AI Engine | x86sim, aiesim |
| 2 | the AI Engine fed by the real PL stream (PLIO) | the AXI-Stream probe, the bisect build |
| 3 | DSPLib FFT / IFFT with a host-supplied coefficient vector | *back down* to x86sim — on purpose |
| 4 | a PL processing stage with a runtime register | the HLS cost report, cycle measurement |
| 5 | real hardware | the board |

Phase 0 targets `hw_emu`, so none of it needs a board.

## Quickstart

```bash
cp setup_env.sh.example setup_env.sh    # edit the five paths at the top
source setup_env.sh
make check_env                          # validates the toolchain; run it first

make test_host                          # rung 1: the golden model      (ms)
make test_pl                            # rung 3: the PL kernels        (s)

make sd_card                            # kernels + link + host + package  (~5 min)
make run_emu LAUNCH_HW_EMU_EXEC=1       # rung 5: the whole system        (~4 min)
```

`make help` lists everything with its current knob values.

## What phase 0 does

```
                        LPDDR4
                          │
        ┌─────────────────┼─────────────────┐
        │ m_axi           │           m_axi │
        ▼                 │                 ▲
   ┌──────────┐     AXI4-Stream       ┌───────────┐
   │ data_src │ ─────────────────────▶│ data_sink │      PL (HLS)
   └──────────┘        32-bit         └───────────┘
        ▲                                   ▲
        │ AXI4-Lite: ap_start, n            │
        └───────────────┬───────────────────┘
                        │
                   base_host.elf                          PS (A72, XRT)
          fills a BO, launches both CUs, reads the
          result back and compares it against a
          host-side golden model
```

The host generates a deterministic stimulus, computes what the answer should be,
runs the design, and checks. It prints `PASS` or `FAIL` and nothing is left for
you to eyeball. On `hw_emu` it reads:

```
[host] phase 0: PL loopback, 1024 words (4096 bytes)
[host] PASS -- all 1024 words correct
```

## The mutant switch

```bash
make test_pl MUTANT=value     # one word is corrupted -> the check must FAIL
make test_pl MUTANT=short     # one word is missing   -> the design DEADLOCKS
```

Every verification step in this project can be made to fail on purpose, and with
a mutant armed the harness **inverts its verdict** — a pass becomes the failure.

Run each one once. A check that has never been observed to fail is not known to
work, and from the outside the two are identical: a comparison that silently
compares nothing prints exactly what a passing one prints.

## Layout

```
design/
├── pl_src/              PL kernels (HLS C++)
│   ├── base_axis.h      THE stream-word definition. One place, on purpose
│   ├── data_src/        LPDDR -> AXI4-Stream
│   ├── data_sink/       AXI4-Stream -> LPDDR
│   └── test/            rung 3: HLS C simulation, native, seconds
├── aie_src/             AI Engine graph and kernels -- empty until phase 1
├── host_app_src/
│   ├── base_host.cpp    the XRT host: BOs, CU launch, verification
│   ├── golden.{h,cpp}   the reference model. NO XRT HEADER -- that is a rule
│   └── test/            rung 1: the model and the checker, native, ms
├── system_configs/      v++ linker config TEMPLATE (generated, not committed)
├── directives/          Vivado post-link Tcl (the AIE clock)
├── profiling_configs/   xrt.ini, packaged onto the card
└── exec_scripts/        the on-target run script TEMPLATE

scripts/check_env.sh     validates the toolchain before anything expensive runs
docs/                    one file per topic; each carries a status header
```

## Conventions worth keeping

- **Every knob's default lives in the Makefile and nowhere else.** Documentation
  quotes `make print-<KNOB>` instead of copying a value, so the two cannot drift.
- **A constant two toolchains both need is passed to both from one Makefile
  variable.** Deriving it twice means it will eventually disagree with itself,
  and a `#ifndef` default is what makes that silent.
- **Anything carrying an absolute path is generated, not committed.** That is why
  the linker config and the run script are templates.
- **The golden model includes no XRT and no ADF header**, so it compiles with the
  system `g++` and runs in milliseconds. Keep every line of real computation on
  that side of the boundary.
- **A measured number in a comment says where it came from.** A figure with no
  provenance cannot be re-checked and will outlive its truth.

## Where this came from

Extracted from a Versal MOSSE correlation-filter tracker (AIE-ML FFT/IFFT, PL
preprocessing, APU orchestration) built on the same board and toolchain. The
traps in [`docs/06-traps.md`](docs/06-traps.md) are that project's scar tissue;
each one cost real time and none of them produces a sensible error message.

## Licence

MIT. See `LICENSE`.
