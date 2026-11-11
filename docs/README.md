# Documentation index

**Status:** current as of phase 0 — PS + PL, no AI Engine yet.

Each file carries its own `**Status:**` header saying what it covers and when it
was last true. Read that line before trusting the file.

| file | what it is |
|---|---|
| [01-environment.md](01-environment.md) | tools, versions, `setup_env.sh`, what every variable is for |
| [02-build-flow.md](02-build-flow.md) | what each `make` target produces, and what an `.xo`/`.xsa`/`libadf.a`/`.xclbin` actually is |
| [03-data-movement.md](03-data-movement.md) | PLIO vs GMIO vs AXI4-Lite vs `m_axi` — when to use which. *Stub until phase 1.* |
| [04-dev-cycle.md](04-dev-cycle.md) | **the development cycle. Read this one.** The rungs, what each can and cannot see, and the mutant switch |
| [05-extending.md](05-extending.md) | recipes: add a kernel, change the geometry, add a buffer. *Stub until phase 2.* |
| [06-traps.md](06-traps.md) | things that cost someone a week. Symptom first, cause second |

If you read only one, read **04-dev-cycle.md**. The point of this project is not
the design — the design is a loopback — it is the order in which you check things.
