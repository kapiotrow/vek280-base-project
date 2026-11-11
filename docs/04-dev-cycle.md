# The development cycle

**Status:** current 2026-11-11 — rungs 1, 2, 3, 4 and 5 all exist (phase 1).
The HLS half of rung 4 arrives with phase 4; the numbering is fixed so this page
stays valid.

This is the most important file in the project.

The design here is a loopback — it computes nothing. What the project is actually
for is the **order in which you check things**, because on this toolchain the
difference between a good day and a lost week is almost never cleverness. It is
whether you asked a question at the cheapest rung that could answer it.

## The ladder

| rung | command | cost | answers |
|---|---|---|---|
| 1 | `make test_host` | < 1 s | is my arithmetic right? is my *checker* right? |
| 2 | `make x86sim` | ~40 s | is my AIE kernel functionally right? |
| 2 | `make x86sim_both` | ~80 s | is my vectorization bit-identical to the scalar version? |
| — | `make graph` | ~3 min | where did it get placed, and what was it **scheduled** at? |
| 3 | `make test_pl` | ~2 s | is my PL kernel's logic right? |
| 4 | `make aiesim` | ~2 min | what does it cost **with the DMAs in the picture**? |
| 4 | HLS report | min | II, latency, PL resources *(phase 4)* |
| 5 | `make run_emu` | ~4 min | does the whole system, with real interfaces, work? |
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

**Rung 2 (`x86sim`)** — the AIE kernel's C++ compiled for the host and run
natively. Functional only: no timing, no DMA, no placement, no array. It is the
cheapest rung that can see an AIE kernel at all, so AIE arithmetic belongs here
and not in `aiesim`.

**`make graph`** is not a rung — nothing runs — but it is where the compiler
tells you three things nothing cheaper can: how many cores and tiles you used,
where each kernel was placed, and **what the inner loop was scheduled at**. For
this project's kernel that is one VLIW bundle per 8 int32 elements, i.e. one
cycle per iteration. That is a *static* count with no DMA contention: a ceiling
on how good the code can be, not a measurement. `scripts/aie_report.py` prints
it and says so.

**Rung 4 (`aiesim`)** — cycle-approximate simulation of the real array: the
compiled kernel on a simulated core, with simulated DMAs and real contention.
This is where a cost figure that includes data movement comes from.

And **it fakes the PL boundary**: a PLIO is fed from text files, so there is no
PL in the simulation at all. This is the single most important limitation in the
whole ladder. A design can pass `aiesim` cleanly and still deadlock the instant a
real PL kernel is on the other end of that PLIO. That is why phase 2 exists and
why rung 5 is not optional. Phase 1 is GMIO-only, so it does not bite yet.

Two mechanical things about `aiesim` that are not obvious and will cost you a
morning otherwise:

- **It does not stop when the work is done.** The harness runs the graph with
  `run(-1)` and never calls `end()`, because with `run(N)` the runtime starts
  tearing down after N invocations and a GMIO `wait()` that has not completed
  then never will. So the run is ended from outside, by `SIM_WALL_TIMEOUT`, and
  it always takes exactly that long. The number is a budget, not a duration.
- **Its exit status is not the verdict.** Because of the above, the recipe
  ignores the simulator's exit code and the verdict comes from
  `check_sim_output.py` reading the dumped file. Which means the dump has to be
  deleted before the run — see the mutant section.

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
| wrong numbers only when vectorized | `make x86sim_both`; see `MUTANT=aie` |
| AIE kernel hangs in simulation | the input buffer is acquired per *firing*, not per patch; and check the drain-before-send order |
| `make graph` fails on a line that is obviously fine | if it mentions `argc`/`argv`, see [06-traps.md](06-traps.md) — the hw target rewrites `main` |
| an AIE rung passes but you changed something | flag stamps, and whether the dump was deleted first |
| stream does not move in hw_emu | the AXI-Stream probe (phase 2), then the `synth`-source bisect build |
| host reads zeros / poison | memory bank sptag, and XRT argument indices — see [06-traps.md](06-traps.md) |
| "it worked yesterday" | flag stamps. You reused a stale artifact. `make clean` and say what changed |
| too slow | rung 6 only |

## The mutant switch

```bash
make test_pl                  # passes
make test_pl MUTANT=value     # data_sink corrupts one word -> the check must FAIL
make test_pl MUTANT=short     # data_src writes n-1 words   -> the design DEADLOCKS
make x86sim  MUTANT=aie       # the AIE vector branch shifts one bit too far
```

With a mutant armed, the harness **inverts its verdict**: a pass becomes the
failure, and it says so. Run each one once.

The reason is not pedantry. A verification step that has never been observed to
fail is not known to work, and the two states look identical from the outside: a
comparison that silently compares nothing prints exactly what a passing one
prints. The reference project this is derived from shipped an entire measurement
sweep in which one statistic read `0.0000` for every single run, alongside five
green unit tests.

The three mutants fail in deliberately different ways:

- `value` is a **wrong answer**. Everything completes; only the check notices.
- `short` is a **hang**. Nothing completes, nothing is printed, there is no
  error and no timeout.
- `aie` is wrong **only when vectorized** — the scalar branch is untouched, so
  `make x86sim_both` reports the two branches as differing. That is the normal
  outcome of a hand-vectorization (a shift in the wrong place, a rounding mode
  that differs, an accumulator read at the wrong precision) and it is the
  hardest of the three to find later.

Those are diagnosed by completely different means, and the hang is the class
this toolchain produces most often. Meeting it once on purpose, in a rung that
costs seconds, is much better than meeting it for the first time forty minutes
into an emulation.

### The vectorized/scalar equality

`make x86sim_both` compiles the AIE kernel twice — `ECHO_VECTORIZE=1` and `=0` —
runs both through rung 2 and diffs the dumps byte for byte.

**"Bit-identical" is a claim, not a hope.** A hand-vectorization that agrees with
its scalar reference to within an LSB has a rounding difference you have not
found yet, and it will surface as a slightly-wrong result in a context where
nothing is obviously broken. Keeping an obviously-correct scalar branch alive and
checking against it costs a few lines and settles the question permanently.

(For this kernel they *are* identical, and the reason is specific: `aie::downshift`
is a plain arithmetic shift on int32, not a rounding one. Had it rounded, the two
branches would differ by one LSB on half the inputs and the check would correctly
fail.)

One subtlety the Makefile had to learn: **"a mutant is armed" is not the same as
"a mutant is reached"**. `MUTANT=aie` breaks the vector branch only, so in the
`ECHO_VECTORIZE=0` half of `x86sim_both` it is compiled out and the build is
correct — and demanding a failure there made the rung fail for the right reason
with the wrong verdict. A mutant only inverts a verdict on a build that actually
contains it (`SIM_MUTANT_EFFECTIVE` in the Makefile). Worth remembering as more
mutants appear.

### A checker must not be able to pass without its input

`make aiesim` deletes `echo_out.bin` before running. That is correctness, not
hygiene.

Because the simulator's exit status is not a usable verdict, the recipe ignores
it and the check reads the dumped file instead. So a simulation that never
*starts* would leave the previous run's dump in place and the rung would report
PASS. **That happened during this project's own development**: a mis-expanded
Make variable produced `--simulation-cycle-timeout=` with no value, aiesimulator
refused to launch, and the rung said PASS. The `rm -f` is the fix. You can see it
work:

```bash
make aiesim AIESIM_CYCLE_TIMEOUT=     # simulator refuses to start
                                      # -> "ERROR: cannot read echo_out.bin", exit 2
```

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
| `make gen_vectors` | < 1 s |
| `make x86sim` (rung 2) | ~40 s, mostly the x86sim aiecompiler pass |
| `make graph` (AIE graph, `--target=hw`) | ~3 min |
| `make aiesim` (rung 4) | = `SIM_WALL_TIMEOUT`, default 120 s |
| `make kernels` (both PL kernels, `v++ -c`) | 21 s |
| `make xsa` (`v++ -l`) | **3 m 47 s** |
| `make rootfs` | ~30 s, once |
| `make package` | 25 s |
| `make run_emu` (rung 5, 1024 words) | **~4 min** |

Two things to read off that table.

The link dominates, and it is the step that grows fastest as the design does —
on the reference project, with a real AIE graph and two nontrivial PL kernels,
the same step is ~25 minutes. `make graph` compiles the AI Engine graph alone in
~3 minutes and answers every placement and schedule question without linking
anything, which is why it exists as its own target.

And rung 5 is cheap *right now* only because the design is 1024 words and the
AIE graph is not in the xclbin yet. It is already ~100× rung 3 and the gap
widens from here. Reaching for it to answer a question rung 1, 2 or 3 could have
answered is the habit this page exists to prevent.

Note what rung 2 costs: ~40 s, and almost none of it is simulation — it is
`aiecompiler --target=x86sim` rebuilding. So the marginal cost of re-running a
rung-2 check after a one-line kernel edit is dominated by a compile you cannot
avoid, which is still two orders of magnitude below `aiesim` and three below the
board.

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
