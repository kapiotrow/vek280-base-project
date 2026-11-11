# Data movement

**Status:** current 2026-11-11 — phase 2. All five mechanisms are in the design
and exercised.

Four mechanisms, four jobs. Picking the wrong one is not usually a correctness
bug — it is a design that works and is three times more complicated than it
needed to be.

| mechanism | moves data | driven by | in this project |
|---|---|---|---|
| `m_axi` | PL kernel ↔ DDR | the kernel itself, from a base address the host wrote | `data_src.in`, `data_sink.out` |
| AXI4-Lite | host → a kernel's registers | the host, one register at a time | `ap_start`, `n`, buffer addresses |
| AXI4-Stream | kernel → kernel, kernel ↔ AIE | the producer, with back-pressure | `data_src.out` → `data_sink.in` |
| **GMIO** | **AIE ↔ DDR** | the APU, or a simulation harness | `gmio_echo_in`/`_out` (`GRAPH=echo`) |
| **PLIO** | **PL ↔ AIE** | the PL producer, with back-pressure | `StreamIn`, `StreamOut` (`GRAPH=base`) |

## GMIO — the short way into the array

GMIO is the AI Engine's own DMA to and from DDR. It needs nothing in the PL: no
kernel, no `stream_connect`, no shim placement, no linker config. The APU hands
it a buffer and it moves.

That makes it the right mechanism for the first AIE kernel you ever write,
because it keeps the question "does my kernel compute the right thing" separate
from the question "is my PL plumbing correct". Phase 1 is entirely GMIO, which
is also what lets it run with no Vivado at all.

```cpp
gmio_echo_in  = input_gmio::create("gmio_echo_in",  64, 1000);
gmio_echo_out = output_gmio::create("gmio_echo_out", 64, 1000);
```

The two numbers are burst length in bytes and bandwidth in MB/s. **Both are
hints** the compiler uses to size the shim DMA. Neither changes what the kernel
computes and neither is a measurement.

### Three rules, each of which is a deadlock if broken

**Arm the output drain before sending the input.** A full output window stalls
the kernel; a stalled kernel stops consuming the input DMA you are then waiting
on. Send-then-drain deadlocks. `echo_graph.cpp` does drain-then-send, in a loop,
one pair per invocation.

**One transfer per invocation, and the drains must be ordered.** `aie2gm_nb()`
moves one invocation's worth of data per call, not the whole buffer. On the
reference project, issuing a single `async()` for an entire multi-invocation
port produced output that was *plausible and wrong*.

**One outstanding async per port.** XRT permits exactly one. A second
non-blocking call on the same port before the first has been waited on is not an
error you will see; it is a transfer you will not get.

### Allocate with `GMIO::malloc`

Not `malloc`. A GMIO buffer must live in memory the shim DMA can reach, with the
alignment it expects. A plain heap pointer may work by accident and then stop
working when the allocation moves.

## PLIO — the PL↔AIE stream

```cpp
stream_in  = input_plio::create("StreamIn",  plio_32_bits, "stream_in.txt");
stream_out = output_plio::create("StreamOut", plio_32_bits, "stream_out.txt");
```

**32 bits, deliberately.** It matches `axis_word_t` in
`design/pl_src/base_axis.h` — one `int32` per beat. A 128-bit PLIO on this
platform delivers **one beat per `readincr()`** on the AIE side and starves the
kernel. The reference project lost about a week to that, during which the fault
was believed to be in the shim placement, the port allocation, the widths, and
eventually the viability of PLIO itself — because the observable is "no data
arrives", which is also what every other defect looks like.

### The kernel did not change

Phase 2 swapped GMIO for PLIO and `echo_kernel` is byte-for-byte the same, with
the same buffer ports. Giving the port `dimensions()` is what tells the compiler
to insert the stream-to-buffer DMA:

```cpp
connect<>(stream_in.out[0], echo.in[0]);
dimensions(echo.in[0]) = {ECHO_N};
```

That separation is worth preserving in your own designs. "Does my kernel compute
the right thing" and "does my plumbing work" are different questions, they fail
in completely different ways, and they are answered at different rungs.

### The PLIO name is a contract across two files

| file | text |
|---|---|
| `design/aie_src/base_graph.h` | `input_plio::create("StreamIn", ...)` |
| `design/system_configs/base.cfg.in` | `stream_connect=data_src_0.out:ai_engine_0.StreamIn` |

A typo is **not an error in either file**. It is a connection that silently does
not exist, and therefore a deadlock with no diagnostic. If a PLIO design hangs
and nothing else changed, check these strings first.

### And the thing that makes PLIO its own phase

The second argument to `create()` is a **file**, and that file is what `aiesim`
reads *instead of a PL kernel*. There is no PL in an AI Engine simulation at all.
So `make aiesim` exercises the graph against a perfectly behaved, infinitely
patient producer — which is exactly what a real `data_src` under a buggy host is
not.

**A graph can pass `aiesim` cleanly and deadlock the instant it is linked.**
`MUTANT=argidx` is that gap on demand, and
[`04-dev-cycle.md`](04-dev-cycle.md) has the demonstration.

### Diagnosing a PLIO that does not move

`make debug_sim && make probe_emu LAUNCH_HW_EMU_EXEC=1` captures TVALID/TREADY
and the kernel's stall reasons to a VCD and prints a verdict. The three outcomes
and what each means are in [`04-dev-cycle.md`](04-dev-cycle.md); the mechanics,
including three separate silent ways waveform capture defeats itself, are in
[`06-traps.md`](06-traps.md).

## Cost, so far

Nothing in this project has been measured on hardware yet, and so nothing here
quotes a number. One figure carried over from the reference design, because it
governs how you write host code from the start:

**BO writes run at ~3470 MB/s, BO reads at ~696.** So push, never pull: fill a
plain heap buffer, `memcpy` it into the mapping, `sync()`. Five sites that
computed against a mapping cost that project ~33 ms per frame.
