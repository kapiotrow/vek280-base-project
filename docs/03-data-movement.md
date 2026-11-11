# Data movement

**Status:** current 2026-11-11 — phase 1. `m_axi`, AXI4-Lite, AXI4-Stream and
GMIO are all in the design and all exercised. PLIO arrives in phase 2 and this
page is extended then.

Four mechanisms, four jobs. Picking the wrong one is not usually a correctness
bug — it is a design that works and is three times more complicated than it
needed to be.

| mechanism | moves data | driven by | in this project |
|---|---|---|---|
| `m_axi` | PL kernel ↔ DDR | the kernel itself, from a base address the host wrote | `data_src.in`, `data_sink.out` |
| AXI4-Lite | host → a kernel's registers | the host, one register at a time | `ap_start`, `n`, buffer addresses |
| AXI4-Stream | kernel → kernel, kernel ↔ AIE | the producer, with back-pressure | `data_src.out` → `data_sink.in` |
| **GMIO** | **AIE ↔ DDR** | **the APU, or a simulation harness** | `gmio_echo_in`, `gmio_echo_out` |
| PLIO | PL ↔ AIE | the PL producer | *phase 2* |

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

## PLIO, and why it is a separate phase

PLIO is the PL↔AIE stream, and phase 2 exists because of one specific fact:
**`aiesim` fakes it.** In simulation a PLIO is fed from a text file, so there is
no PL in the simulation at all. A graph can pass `aiesim` cleanly and deadlock
the instant a real PL kernel is on the other end.

This project's PLIO will be **32 bits wide**, deliberately. A 128-bit PLIO on
this platform delivers one beat per `readincr()` on the AIE side and starves the
kernel — the reference project lost a week to that, during which the fault was
believed to be in every other part of the datapath in turn.

## Cost, so far

Nothing in this project has been measured on hardware yet, and so nothing here
quotes a number. One figure carried over from the reference design, because it
governs how you write host code from the start:

**BO writes run at ~3470 MB/s, BO reads at ~696.** So push, never pull: fill a
plain heap buffer, `memcpy` it into the mapping, `sync()`. Five sites that
computed against a mapping cost that project ~33 ms per frame.
