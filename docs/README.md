# Documentation index

**Status:** current as of phase 2 — PS + PL + AI Engine, all in one datapath.

Each file carries its own `**Status:**` header saying what it covers and when it
was last true. Read that line before trusting the file.

| file | what it is |
|---|---|
| [01-environment.md](01-environment.md) | tools, versions, `setup_env.sh`, what every variable is for |
| [02-build-flow.md](02-build-flow.md) | what each `make` target produces, and what an `.xo`/`.xsa`/`libadf.a`/`.xclbin` actually is |
| [03-data-movement.md](03-data-movement.md) | PLIO vs GMIO vs AXI4-Lite vs `m_axi` — when to use which, and the deadlock rules for each |
| [04-dev-cycle.md](04-dev-cycle.md) | **the development cycle. Read this one.** The rungs, what each can and cannot see, and the mutant switch |
| [05-extending.md](05-extending.md) | recipes: add a PL or AIE kernel, add a PLIO port, debug a stream that will not move |
| [06-traps.md](06-traps.md) | things that cost someone a week. Symptom first, cause second |
| [07-roadmap.md](07-roadmap.md) | **what is left to build** — phases 3–5, what is known in advance, and the known rough edges |

If you read only one, read **04-dev-cycle.md**. The point of this project is not
the design — the design computes one shift and one add — it is the order in
which you check things, and knowing which questions no cheap check can answer.
