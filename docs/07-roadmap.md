# Roadmap — what is left to build

**Status:** current 2026-11-11 — phases 0, 1 and 2 are done and verified on
hardware-emulation. Phases 3, 4 and 5 are not started. This file is the handover
note: what to do next, in what order, and what is already known about each.

## Where the project stands

| phase | state | what it added |
|---|---|---|
| 0 | **done, verified** | `data_src` → AXIS → `data_sink`, XRT host, golden model, `check_env`, HLS C-sim, hw_emu |
| 1 | **done, verified** | AIE kernel (vectorized + scalar), GMIO graph, x86sim, aiesim, `make graph` |
| 2 | **done, verified** | PLIO in/out, the AIE in the datapath, the handshake probe, the bisect build, two integration mutants |
| 3 | not started | DSPLib FFT/IFFT + a host-supplied coefficient vector |
| 4 | not started | a PL processing stage with a runtime register, and the cost rungs |
| 5 | not started | real hardware |

Everything verified so far was verified in `hw_emu`. **No part of this project
has ever run on a board.** That is phase 5 and it is the one phase that cannot
be faked.

### What currently passes

```
make check_env                                  OK
make test_host                                  4/4 checks
make test_pl            / MUTANT=value / short  pass / detected / detected
make gen_vectors                                cross-check OK, 1024 words
make x86sim GRAPH=echo  / MUTANT=aie            PASS / detected
make x86sim_both                                BIT-IDENTICAL
make graph                                      1 core of 304, 2 tiles, 1 VLIW bundle/iter
make aiesim GRAPH=echo                          PASS, bit-exact
make aiesim             (GRAPH=base, PLIO)      PASS, bit-exact
make aiesim ECHO_SRC=synth                      "THE CORE RAN"
make sd_card && make run_emu                    PASS -- all 1024 words correct
make run_emu MUTANT=argidx                      aborts: "bad command state"
make run_emu MUTANT=nograph                     hangs (as designed)
make debug_sim && make probe_emu                arms, discovers signals, 22 captured
```

---

## Phase 3 — DSPLib FFT/IFFT and a host-supplied coefficient vector

**The point of the phase is not the FFT.** It is that new arithmetic sends you
*back down* the ladder: you write the golden first, prove it at rung 1, prove
the kernel at rung 2, and only then link. Phase 3 is where that habit gets
installed, because it is the first phase whose maths is not obvious.

### Target topology

```
PLIO in ──▶ fft64 (DSPLib) ──▶ cmul ◀── gmio_coeff (host) ──▶ ifft64 ──▶ PLIO out
```

`IFFT(coeff ⊙ FFT(x))` with `coeff = 1` returns `x` times a known gain, so the
design stays **self-checking**.

### Work items, in order

1. **`DSPLIB_VITIS` include paths.** `check_env` already warns if
   `$DSPLIB_VITIS/dsp` is missing. The reference project's `AIE_FLAGS` show the
   six `-include=` paths needed (`L1/include/aie`, `L1/src/aie`,
   `L1/tests/aie/inc`, `L1/tests/aie/src`, `L2/include/aie`,
   `L2/tests/aie/common/inc`) — copy that list.
2. **Data type changes from `int32` to `cint16`.** This touches the golden, the
   stimulus generator, the PLIO width accounting and `base_axis.h`. Do it as its
   own commit, with rung 1 and rung 2 green, before any FFT exists.
3. **Wrap `fft_ifft_dit_1ch_graph`.** Point size 64. Start from the reference
   project's own `fft_graph.h` (it lives in *that* repo, not this one), but take
   **only** the 1-D row pass — its 2-D version carries the memory-tile
   transpose, which is out of scope (see below).
4. **`cmul_kernel`**, the extension point: per-bin complex multiply by the
   coefficient vector. Vectorized *and* scalar, like `echo_kernel`, so
   `x86sim_both` still means something.
5. **`gmio_coeff`.** The host writes the coefficients. This is the third
   data-movement idiom in one design and the first time the host sends the array
   anything other than a start command. Mind the GMIO rules in
   [`03-data-movement.md`](03-data-movement.md) — arm the drain before the send,
   one transfer per invocation, one outstanding async per port.
6. **`make sweep_shift`.** Runs rung 2 across a range of FFT output-shift values
   and prints the resulting error. **This is the most valuable deliverable of
   the phase**: a real fixed-point engineering question, answered in ten minutes
   with no hardware. It is what demonstrates that the cheap rungs are not
   training wheels.

### What is known in advance

- **The FFT's output shift is a real knob with a real cost.** The reference
  project needed a 200-frame calibration run per geometry to set its shift
  budget, and twice an offline model set it and hardware overturned the result.
  For a base project the lesson to teach is the *method* (sweep it, measure the
  error, record the number), not a specific value.
- **DSPLib's `cint16` FFT loss is additive, not a gain factor** — each pass
  subtracts roughly a constant from a summed DC bin, independent of amplitude.
  So any "expected = N" arithmetic in a golden will be wrong. Budget time for
  this; it is the single most likely way phase 3's golden disagrees with the
  hardware for a reason that is not a bug.
- **The fixed-point transform is not Hermitian for real input.** Do not build a
  golden that assumes it is.
- `ECHO_SHIFT`/`ECHO_BIAS` become FFT/coefficient parameters. Keep the
  one-variable-reaches-both-toolchains discipline (`--Xpreproc` for the kernel,
  `-D` for the host, from one Makefile knob).

### Mutant to add

`MUTANT=shift` — an off-by-one in the FFT output shift. It produces output that
is **plausible and wrong**, which is the characteristic failure of fixed-point
work and the one a spot-check of a hexdump will not catch.

---

## Phase 4 — a PL processing stage, and the cost rungs

### Work items

1. **`axis_gain`**: an AXIS→AXIS PL kernel between the AIE output and
   `data_sink`, multiplying by a gain held in an AXI4-Lite register. Small, but
   it completes the tour — PL processing, and runtime control of it.
2. **The reference model for rung 3 stops being the identity.** `test_pl`'s
   expectation is currently `want = in` with a comment explaining that the PL
   chain is a pure loopback. Phase 4 is where that changes; the comment already
   says so.
3. **Rung 4's HLS half.** The II, latency and resource figures come out of the
   `v++ -c` build directory (`$(BUILD_DIR)/reports/`). Write a reader for it in
   the style of `scripts/aie_report.py`, and make it say — as that one does —
   whether each figure is an estimate or a measurement.
4. **Measured PL cycles from hw_emu.** Emulation wall time is meaningless but
   its *simulated PL cycles* are RTL-accurate, and this is where to show that.
   The probe VCD already captures `ap_start`/`ap_done`; counting cycles between
   them is a small addition to `analyze_plio_vcd.py`.
5. **`--kds` in the host**, to demonstrate the ~503 ms-per-launch KDS completion
   cost against a user-managed `xrt::ip` CU. **This only shows up on real
   hardware** — write it in phase 4, measure it in phase 5.

### The measurement rules to write down here

Carried from the reference project, every one of them paid for:

- Instruments before changes. Never move two magnitudes at once.
- **Never size a change from one member of an interleaved async/wait group —
  sum the group.** The single most repeated measurement error on the reference
  project; it built a whole optimisation on an artifact.
- Measure the total and print the residual.
- Two independent instruments beat one instrument twice.
- Keep a known-good comparator on the old path.
- Write predictions down before the run.
- A caveat that is not priced is a hope.

---

## Phase 5 — real hardware

Written as a checklist now so it is ready when a board is.

1. `make rootfs` already strips the ext4 features that `v++ --package`
   mishandles. Add **`board_provision`**: a static address on `end0` and an
   authorized key for root, written into the rootfs with `debugfs` (no root, no
   loop device). The reference project has a `board_provision.sh` that is the
   model for it. Make `BOARD_KEY=none` an **explicit** opt-out — an image silently
   built without a key boots unreachable, and that is indistinguishable from a
   cable fault at the moment it costs most.
2. `make sd_card TARGET=hw`, flash, boot, serial console.
3. **What changes when you leave emulation:**
   - wall-clock time becomes meaningful;
   - `XCL_EMULATION_MODE` must be **unset** — the Makefile already generates
     `run_script.sh` per target for this;
   - the ~503 ms KDS launch cost appears;
   - **quote FPS only from a serial-console run.** Launching over ssh changes
     the measurement.
4. **Never kill a board run mid-sequence.** On the reference project the next
   process then stalls and only a reboot clears it.
5. Only then size the design up. `BASE_N` is 1024 and `ECHO_N` 256 precisely so
   that everything through phase 4 stays cheap in emulation.

---

## Deliberately out of scope

Each of these is where the reference project's real complexity lives, and each
would make the base project worse at its job. Listed so nobody thinks they were
forgotten.

| not doing | why, and where to look instead |
|---|---|
| 2-D FFT with a memory-tile transpose | the transpose is the hard part: memory tiles, and a configuration flag that is a **board deadlock rather than a compile error** if set on one side only. The reference project's `fft_graph.h` is the worked example |
| multiple graph instances / cascades | placement and routing become the subject; one core teaches the toolchain fine |
| floating point on the AIE | the interesting arithmetic questions on this part are fixed-point ones |
| performance optimisation | a base project should be clear, not fast. The reference repo has the optimisation history |
| a thesis/claims documentation system | the reference repo's three-tier docs + generated tables are excellent and are much more machinery than a starting point needs |

---

## Known rough edges in what exists

Honest list. None of these blocks a colleague from using the project.

1. **The probe cannot see the application phase of a hung run.** `xsim` flushes
   the VCD fully only on `close_vcd`, which a deadlocked run never reaches, so
   the capture is a boot-only prefix (measured: 91.79 µs of simulated time
   against a 420 s budget). `analyze_plio_vcd.py` detects this and declines to
   give a verdict, and the bisect build (`ECHO_SRC=synth`) answers the same
   question without a waveform — so the tool is honest and there is a working
   alternative, but **the probe's headline use case is unproven end to end.**
   Either find a way to flush periodically, or re-run with a budget measured in
   hours and record what it takes.
2. **`aiesim` always runs for its full `SIM_WALL_TIMEOUT`.** The harness uses
   `run(-1)` and never calls `end()` for the GMIO graph, so the run is ended
   from outside. The PLIO graph (`base_graph.cpp`) uses `run(N)`/`end()` and
   does not have this problem — the GMIO harness could probably be restructured
   the same way now that the reason for `run(-1)` is understood.
3. **The golden exists twice**, in C++ (`golden.cpp`) and Python
   (`gen_vectors.py`). The *stimulus* halves are cross-checked automatically by
   `make gen_vectors`; the *output* halves are not. Phase 3 makes them more
   complicated, so this is the right time to cross-check them too.
4. **`GRAPH=echo` and `GRAPH=base` duplicate the graph wiring.** Deliberate and
   worth it — `echo` is the only configuration that runs the array with no PL at
   all — but if a third graph ever appears, factor the common part out.
5. **No CI.** Everything cheap (`test_host`, `test_pl`, `x86sim`, `gen_vectors`)
   runs in well under two minutes and would make a good pre-commit check.

---

## The acceptance test this project has not passed yet

**A colleague clones it on a clean machine and gets to a board PASS using only
the README.**

Until that has actually happened, it is not finished as a base project. The
nearest approximation available today is: clone, `cp setup_env.sh.example
setup_env.sh`, edit five paths, and reach `make run_emu` PASS without asking
anybody anything.
