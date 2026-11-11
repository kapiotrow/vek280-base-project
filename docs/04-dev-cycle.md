# The development cycle

**Status:** current 2026-11-11 — rungs 1, 3 and 5 exist (phase 0). Rungs 2 and 4
arrive with phases 1 and 4; the numbering is fixed so this page stays valid.

This is the most important file in the project.

The design here is a loopback — it computes nothing. What the project is actually
for is the **order in which you check things**, because on this toolchain the
difference between a good day and a lost week is almost never cleverness. It is
whether you asked a question at the cheapest rung that could answer it.

## The ladder

| rung | command | cost | answers |
|---|---|---|---|
| 1 | `make test_host` | ms | is my arithmetic right? is my *checker* right? |
| 2 | `make x86sim` | s | is my AIE kernel functionally right? *(phase 1)* |
| 3 | `make test_pl` | s | is my PL kernel's logic right? |
| 4 | `make aiesim` / HLS report | min | what does it **cost** — cycles, II, resources? *(phases 1, 4)* |
| 5 | `make run_emu` | tens of min | does the whole system, with real interfaces, work? |
| 6 | board | — | how fast is it really? what does it draw? |

## What each rung cannot see

This column is the useful one. A rung that passes tells you nothing about the
questions it structurally cannot ask.

**Rung 1 (`test_host`)** — knows nothing about hardware at all. It is pure C++
against a model. Its value is that it is nearly free, so there is no excuse for
debugging arithmetic anywhere else.

**Rung 3 (`test_pl`)** — compiles the kernel bodies with `g++` and runs them back
to back. It never exercises an AXI interface: `#pragma HLS INTERFACE` lines are
ignored, so a wrong bundle name or a missing `offset=slave` passes here and then
hands the host a kernel whose registers are somewhere else. It has no schedule,
so back-pressure on a finite FIFO does not exist. It reports no cost.

**Rung 2 (`x86sim`, from phase 1)** — functional only, no timing and no DMA.

**Rung 4 (`aiesim`, from phase 1)** — cycle-accurate for the array, and **it
fakes the PL boundary**: PLIO data comes from text files. This is the single most
important limitation in the whole ladder. A design can pass `aiesim` cleanly and
still deadlock the instant a real PL kernel is on the other end of that PLIO.
That is why phase 2 exists and why rung 5 is not optional.

**Rung 5 (`run_emu`)** — the first rung with real interfaces, real XRT, real
memory banks, a real schedule. **Its wall-clock time is meaningless**: it is
simulator time. Its *simulated PL cycle counts* are RTL-accurate and are a real
measurement. Do not quote one as the other.

**Rung 6 (board)** — the only rung that measures performance. Things that appear
for the first time here include the ~503 ms-per-launch cost of the KDS
completion path on this platform, which no emulation shows you.

## The ladder is not a staircase

New arithmetic means you go back **down** to rung 1 or 2, every time, including
when the change feels too small to bother. The habit is the deliverable.

From phase 3 there is a `make sweep_shift` that answers a genuine fixed-point
scaling question by running rung 2 across a range of values — a real engineering
result, in ten minutes, with no hardware. That target exists to make the point
that the cheap rungs are not training wheels.

## Symptom → rung

| symptom | go to |
|---|---|
| wrong numbers | rung 1 or 2. **Never** debug arithmetic in hw_emu |
| AIE kernel hangs in simulation | the input buffer is acquired per *firing*, not per patch |
| stream does not move in hw_emu | the AXI-Stream probe (phase 2), then the `synth`-source bisect build |
| host reads zeros / poison | memory bank sptag, and XRT argument indices — see [06-traps.md](06-traps.md) |
| "it worked yesterday" | flag stamps. You reused a stale artifact. `make clean` and say what changed |
| too slow | rung 6 only |

## The mutant switch

```bash
make test_pl                  # passes
make test_pl MUTANT=value     # data_sink corrupts one word -> the check must FAIL
make test_pl MUTANT=short     # data_src writes n-1 words   -> the design DEADLOCKS
```

With a mutant armed, the harness **inverts its verdict**: a pass becomes the
failure, and it says so. Run each one once.

The reason is not pedantry. A verification step that has never been observed to
fail is not known to work, and the two states look identical from the outside: a
comparison that silently compares nothing prints exactly what a passing one
prints. The reference project this is derived from shipped an entire measurement
sweep in which one statistic read `0.0000` for every single run, alongside five
green unit tests.

The two mutants fail in deliberately different ways:

- `value` is a **wrong answer**. Everything completes; only the check notices.
- `short` is a **hang**. Nothing completes, nothing is printed, there is no
  error and no timeout.

Those are diagnosed by completely different means, and the second is the class
this toolchain produces most often. Meeting it once on purpose, in a rung that
costs seconds, is much better than meeting it for the first time forty minutes
into an emulation.

A note on rung 3 and the hang: `hls::stream::read()` on an empty stream does not
warn and does not return a default value — it blocks on a condition variable,
forever, exactly as the hardware would. So `test_pl` checks the stream depth
*before* draining and reports the shortfall instead of wedging. A test that
hangs the build teaches nothing.

## Iteration cost, and how to not pay it

Measured on THIS project, phase 0, `TARGET=hw_emu`, on one machine
(2026-11-11 — `build/hw_emu/`, and `make run_emu`'s own log). Your absolute
numbers will differ; the *ratios* are what matter.

| step | time |
|---|---|
| `make test_host` (rung 1) | < 1 s |
| `make test_pl` (rung 3) | ~2 s, nearly all of it compiling `ap_int.h` |
| `make kernels` (both PL kernels, `v++ -c`) | 21 s |
| `make xsa` (`v++ -l`) | **3 m 47 s** |
| `make rootfs` | ~30 s, once |
| `make package` | 25 s |
| `make run_emu` (rung 5, 1024 words) | **~4 min** |

Two things to read off that table.

The link dominates, and it is the step that grows fastest as the design does —
on the reference project, with an AIE graph and two nontrivial PL kernels, the
same step is ~25 minutes. From phase 1 there is a `make graph` that compiles the
AI Engine graph alone in ~5 minutes and answers placement and schedule questions
without linking anything.

And rung 5 is cheap *right now* only because the design is 1024 words and has no
AIE graph. It is already 100× rung 3 and the gap widens from here. Reaching for
it to answer a question rung 1 or 3 could have answered is the habit this page
exists to prevent.

Consequences, all of them habits rather than tricks:

- **Build the smallest thing that answers the question.** From phase 1, `make
  graph` answers placement and schedule questions in 5 minutes; packaging to ask
  the same question costs 25.
- **`-no-reboot`** reuses the already-booted emulation image, which is most of
  the wall time of a run. `make run_emu` passes it.
- **`make run_emu` refuses to start without `LAUNCH_HW_EMU_EXEC=1`.** It is four
  minutes today and will not stay that way; starting a long run by accident is a
  wasted afternoon, so it has to be deliberate.
- **Keep the data small.** `BASE_N` is 1024 and emulation time scales with it.
  Sizing up is a rung-6 exercise.
- **Never kill a run mid-sequence on real hardware.** On the reference project
  the next process then stalls and only a reboot clears it.
