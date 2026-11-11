/*
 * base_host.cpp -- the PS side of the phase-0 design.
 *
 *   host BO --m_axi--> data_src --AXI4-Stream--> data_sink --m_axi--> host BO
 *
 * There is no AIE graph yet. That is deliberate: an image with no AIE graph
 * builds and boots markedly faster, so the first time you fight packaging and
 * XRT you are fighting ONLY packaging and XRT. The array arrives in phase 1,
 * and it arrives in simulation, where it is cheap.
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

#include "golden.h"

// Set from the Makefile's MUTANT knob so the host can invert its verdict: with
// a mutant armed, a PASS is the failure. See docs/04-dev-cycle.md.
#ifndef MUTANT_ARMED
#  define MUTANT_ARMED 0
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

    printf("[host] phase 0: PL loopback, %zu words (%zu bytes)\n", n, bytes);
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
    r_src.set_arg(arg::SRC_IN, in_bo);
    r_src.set_arg(arg::SRC_N,  (uint32_t)n);

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

    return errors == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
