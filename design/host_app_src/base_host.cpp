/*
 * base_host.cpp -- the PS side of the phase-0 design.
 *
 *   host BO --m_axi--> data_src --AXIS--> PLIO --> echo_kernel (AIE)
 *                                                        |
 *   host BO <--m_axi-- data_sink <--AXIS-- PLIO <---------+
 *
 * PHASE 2: the AI Engine is now in the datapath. The host's job is unchanged --
 * fill a buffer, start two CUs, read the result, compare against the golden --
 * but the golden is no longer the identity, because the array computes
 * something on the way through.
 *
 * THE HOST MUST START THE GRAPH, and this is easy to get wrong because almost
 * nothing else about the AI Engine appears here. The array is fed and drained
 * entirely by the two PL kernels over PLIO -- no GMIO, no buffers, no data ever
 * passes through this process on its way to a core. It is tempting to conclude
 * that a PLIO design needs no AIE-aware host code at all.
 *
 * It does need exactly one thing: somebody has to enable the cores. We package
 * with --package.defer_aie_run, so loading the xclbin does NOT start them, and
 * a graph whose cores are not running never drains its input PLIO. data_src
 * then fills the stream FIFO, stalls, and the whole design hangs with no error.
 *
 * That bug was hit while writing this phase, and it is preserved as
 * MUTANT=nograph because it is the cleanest deadlock in the project: the host
 * prints "waiting for data_src" and never returns, with no error of any kind.
 * The probe answers it in one run -- TVALID HIGH, TREADY LOW, the producer
 * produced and the consumer was never switched on.
 *
 * Every stage prints and flushes before it blocks, so wherever the run stops is
 * exactly what failed. In an emulation that can hang, that property is worth
 * more than tidy output.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <vector>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"
#include "xrt/xrt_graph.h"

#include "golden.h"

// Set from the Makefile's MUTANT knob so the host can invert its verdict: with
// a mutant armed, a PASS is the failure. See docs/04-dev-cycle.md.
#ifndef MUTANT_ARMED
#  define MUTANT_ARMED 0
#endif

/*
 * TWO INTEGRATION MUTANTS LIVE IN THIS FILE, and they are here rather than in
 * the kernels because integration is the one category of defect that no cheap
 * rung can see. Both pass x86sim and aiesim -- which contain no host and no PL,
 * and feed the PLIO from a text file -- and both break the linked system.
 *
 * They fail DIFFERENTLY, and that contrast is the lesson:
 *
 *   MUTANT=argidx    aborts, with a message
 *   MUTANT=nograph   hangs, with nothing
 *
 * ---------------------------------------------------------------------------
 * MUTANT_ARGIDX -- `make ... MUTANT=argidx`
 *
 * Uses xrt::run's positional call operator instead of set_arg() by explicit
 * index. An AXI4-Stream port occupies an argument slot even though it is not a
 * settable register, so for data_src(in, out_stream, n) the value intended for
 * `n` lands on the stream port at index 1.
 *
 * MEASURED HERE (XRT 2025.2, hw_emu, 2026-11-11): this ABORTS at launch with
 *
 *     terminate called after throwing an instance of 'std::runtime_error'
 *       what():  bad command state, can't launch
 *
 * which is the good outcome -- a clear, immediate, attributable failure.
 *
 * DO NOT RELY ON GETTING IT. The same class of mistake on the reference project
 * produced a SILENT ZERO-TRIP LOOP instead: `n` stayed at its reset value, the
 * kernel asserted ap_done a few cycles after ap_start, TVALID never rose, and
 * the design simply hung. That cost about a week, during which the fault was
 * believed to be in the PLIO width, the shim placement, the port allocation and
 * eventually the viability of PLIO itself -- because "no data arrives" is what
 * every one of those also looks like.
 *
 * Whether you get the abort or the hang depends on which argument slot the
 * stray value lands on and how malformed the resulting command packet is. The
 * rule that follows is the same either way: ALWAYS set_arg() by explicit index
 * on a kernel that has a stream port.
 */
#ifndef MUTANT_ARGIDX
#  define MUTANT_ARGIDX 0
#endif

/*
 * MUTANT_NOGRAPH -- `make ... MUTANT=nograph`
 *
 * Skips gr.run(). THIS IS THE ONE THAT HANGS, and it produces nothing at all:
 * no error, no timeout, no output. The host prints "waiting for data_src" and
 * stops there forever.
 *
 * Why: we package with --package.defer_aie_run, so loading the xclbin does not
 * enable the AI Engine cores. A graph whose cores are not running never drains
 * its input PLIO, so data_src fills the stream FIFO and stalls.
 *
 * This was a real bug while phase 2 was being written -- the host had no graph
 * handle at all, because with PLIO no data passes through the host and it is
 * easy to conclude that no AIE-aware host code is needed. It is needed for
 * exactly one thing: somebody has to switch the cores on.
 *
 * It is the right mutant for practising the probe, because the probe answers it
 * outright: TVALID HIGH, TREADY LOW -- the producer produced and the consumer
 * never accepted. Compare with argidx, where TVALID never rises at all.
 */
#ifndef MUTANT_NOGRAPH
#  define MUTANT_NOGRAPH 0
#endif

/*
 * ARGUMENT INDICES -- THE TRAP THIS BLOCK EXISTS TO PREVENT.
 *
 * An AXI4-Stream port occupies a positional argument slot in the kernel's XML
 * even though it is not a settable register. So for
 *
 *     data_src(const ap_uint<32> *in, hls::stream<...> &out, ap_uint<32> n)
 *                      ^ index 0            ^ index 1             ^ index 2
 *
 * `run(bo, n)` assigns n to the STREAM port and leaves the real `n` at its
 * reset value of zero. The kernel then runs a zero-trip loop: ap_done asserts
 * a few cycles after ap_start, TVALID never rises, and the symptom at the other
 * end is "the stream delivers nothing" -- which sends you hunting in the AIE
 * array, the PLIO width, and the shim placement for a week.
 *
 * That is not a hypothetical. It is what happened in the reference project.
 *
 * ALWAYS set_arg() by explicit index. Never use the positional call operator on
 * a kernel that has a stream port.
 */
namespace arg {
    // data_src(in, out_stream, n)
    constexpr int SRC_IN     = 0;
    constexpr int SRC_STREAM = 1;   // never written -- here to be counted
    constexpr int SRC_N      = 2;

    // data_sink(in_stream, out, n)
    constexpr int SINK_STREAM = 0;  // never written -- here to be counted
    constexpr int SINK_OUT    = 1;
    constexpr int SINK_N      = 2;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <xclbin> [-n <words>]\n", argv[0]);
        return EXIT_FAILURE;
    }

    size_t n = BASE_N;
    for (int i = 2; i < argc - 1; ++i)
        if (std::strcmp(argv[i], "-n") == 0) n = (size_t)std::atol(argv[i + 1]);

    const size_t bytes = n * sizeof(uint32_t);

    printf("[host] phase 2: PL -> AIE -> PL, %zu words (%zu bytes)\n", n, bytes);
    printf("[host] AIE computes (in >> %d) + %d\n", BASE_ECHO_SHIFT, BASE_ECHO_BIAS);
    printf("[host] mutant armed: %d\n", MUTANT_ARMED);
    fflush(stdout);

    // ---- device ----------------------------------------------------------
    printf("[host] loading xclbin: %s\n", argv[1]); fflush(stdout);
    xrt::device device(0);
    xrt::uuid   uuid = device.load_xclbin(argv[1]);

    // The CU instance names come from the nk= lines in the v++ link config.
    // Spell them with the {instance} suffix so XRT binds this handle to that one
    // CU rather than to any CU of that kernel.
    auto k_src  = xrt::kernel(device, uuid, "data_src:{data_src_0}");
    auto k_sink = xrt::kernel(device, uuid, "data_sink:{data_sink_0}");

    // ---- the AI Engine graph -------------------------------------------
    // "base_graph" is the C++ VARIABLE NAME of the graph object in
    // design/aie_src/base_graph.cpp, not the class name and not a string
    // declared anywhere. Rename that variable and this lookup throws.
    //
    // run(n) enables the cores for n invocations. The count must match what the
    // PL will actually send: data_src pushes BASE_N words and the kernel
    // consumes ECHO_N per firing, so the graph must be good for BASE_N/ECHO_N
    // firings. Too few and the tail of the stream is never consumed -- which is
    // a hang, not an error.
    const int graph_iters = (int)(n / BASE_ECHO_N);
    xrt::graph gr(device, uuid, "base_graph");
#if MUTANT_NOGRAPH
    printf("[host] MUTANT=nograph: NOT starting the AIE graph.\n");
    printf("[host]   The cores stay disabled, so the input PLIO is never\n");
    printf("[host]   drained. data_src will fill the stream FIFO and stall.\n");
    printf("[host]   Expect this run to HANG, silently, with no error.\n");
    fflush(stdout);
#else
    printf("[host] starting AIE graph for %d iterations\n", graph_iters);
    fflush(stdout);
    gr.run(graph_iters);
#endif

    // ---- buffers ---------------------------------------------------------
    // Take the memory bank from the kernel argument's own group_id. Do NOT pass
    // a literal bank index: the VEK280 is LPDDR4, its memory sptags are LPDDR1
    // and LPDDR2 rather than DDR, and a hardcoded 0 is right by luck or wrong
    // silently. group_id asks the xclbin what the linker actually decided.
    auto in_bo  = xrt::bo(device, bytes, k_src.group_id(arg::SRC_IN));
    auto out_bo = xrt::bo(device, bytes, k_sink.group_id(arg::SINK_OUT));

    // Map once, compute in host memory, then push.
    //
    // Never run a computation directly against a BO mapping. Measured on the
    // reference design: BO writes stream at ~3470 MB/s but reads at only ~696,
    // and five sites that read back through a mapping cost ~33 ms per frame.
    // Fill a plain heap buffer, memcpy it in, sync.
    std::vector<uint32_t> host_in(n), want(n), got(n);
    base_fill_input(host_in.data(), n);
    base_golden(host_in.data(), want.data(), n);

    std::memcpy(in_bo.map<uint32_t *>(), host_in.data(), bytes);
    std::memset(out_bo.map<uint32_t *>(), 0xa5, bytes);   // poison, so a CU that
                                                          // never writes is loud
    in_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    out_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // ---- launch ----------------------------------------------------------
    xrt::run r_src(k_src);
#if MUTANT_ARGIDX
    // THE BUG, on purpose. Positional assignment starts at index 0, and index 1
    // is the AXI4-Stream port, so `n` is written there and the real `n` stays 0.
    printf("[host] MUTANT=argidx: setting data_src args POSITIONALLY.\n");
    printf("[host]   n will land on the stream port (index 1) and the real n\n");
    printf("[host]   stays 0. data_src will produce nothing and the AIE kernel\n");
    printf("[host]   will block forever. Expect this run to HANG.\n");
    fflush(stdout);
    r_src(in_bo, (uint32_t)n);
#else
    r_src.set_arg(arg::SRC_IN, in_bo);
    r_src.set_arg(arg::SRC_N,  (uint32_t)n);
#endif

    xrt::run r_sink(k_sink);
    r_sink.set_arg(arg::SINK_OUT, out_bo);
    r_sink.set_arg(arg::SINK_N,   (uint32_t)n);

    // START THE CONSUMER FIRST. The AXI4-Stream between the two CUs is a FIFO
    // of finite depth; if the producer runs with nothing draining it, it fills
    // the FIFO and stalls mid-transfer. Nothing has gone wrong at that point,
    // but the design makes no progress, and "stalled" and "deadlocked" look the
    // same from here.
    printf("[host] starting data_sink\n"); fflush(stdout);
    r_sink.start();
    printf("[host] starting data_src\n");  fflush(stdout);

    auto t0 = std::chrono::steady_clock::now();
    r_src.start();

    printf("[host] waiting for data_src\n");  fflush(stdout);
    r_src.wait();
    printf("[host] waiting for data_sink\n"); fflush(stdout);
    r_sink.wait();
    auto t1 = std::chrono::steady_clock::now();

    // The graph ran a finite number of iterations, so waiting for it is well
    // defined. (On a FREE-RUNNING graph -- run(-1) -- this blocks forever; that
    // is cosmetic when you are driving it by hand and fatal to a script.)
#if !MUTANT_NOGRAPH
    printf("[host] waiting for the AIE graph\n"); fflush(stdout);
    gr.wait();
#endif

    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    // In hw_emu this number is MEANINGLESS -- it is simulator wall time, not
    // hardware time. It is printed anyway, labelled, because the habit of
    // instrumenting before changing is worth more than this one figure. The
    // emulation's simulated PL cycle counts ARE accurate; wall time is not.
    printf("[host] both CUs done in %.3f ms of WALL time"
           " (meaningless under hw_emu -- see docs/04-dev-cycle.md)\n", ms);

    // ---- verify ----------------------------------------------------------
    out_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    std::memcpy(got.data(), out_bo.map<uint32_t *>(), bytes);

    const size_t errors = base_compare(got.data(), want.data(), n, "host");

    if (MUTANT_ARMED) {
        if (errors == 0) {
            printf("[host] FAILED -- a mutant is armed but every word matched.\n");
            printf("       The check is not checking. Fix that before trusting a PASS.\n");
            fflush(stdout);
            return EXIT_FAILURE;
        }
        printf("[host] mutant detected: %zu/%zu words wrong -- the check works.\n",
               errors, n);
        fflush(stdout);
        return EXIT_SUCCESS;
    }

    if (errors == 0) printf("[host] PASS -- all %zu words correct\n", n);
    else             printf("[host] FAIL -- %zu/%zu words wrong\n", errors, n);
    fflush(stdout);

    gr.end();
    return errors == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
