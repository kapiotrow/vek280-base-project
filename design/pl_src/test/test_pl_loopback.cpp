/*
 * test_pl_loopback.cpp -- rung 3 of the development cycle: `make test_pl`.
 *
 * Seconds. Compiles the two PL kernel bodies with the system g++ against the
 * Vitis HLS headers and runs them back to back on real data. No vitis_hls
 * process, no project, no synthesis, no emulation.
 *
 *   base_fill_input -> data_src -> hls::stream -> data_sink -> base_compare
 *
 * WHAT THIS RUNG CAN SEE
 *   The loop bounds, the data path through the stream, TLAST placement, the
 *   arithmetic -- everything about what the kernels COMPUTE. It also sees a
 *   stream-depth mismatch, which is how MUTANT=short is caught below.
 *
 * WHAT IT CANNOT SEE, and this is the part worth internalising
 *
 *   - THE AXI INTERFACES. The #pragma HLS INTERFACE lines are not exercised
 *     here at all; g++ ignores them. A wrong bundle name or a missing
 *     offset=slave compiles clean, passes this test, and then hands the host a
 *     kernel whose registers are somewhere else.
 *
 *   - CONCURRENCY, in the way that matters. This harness runs data_src to
 *     completion and only then data_sink, against a csim stream of unbounded
 *     depth. On hardware the two CUs run at the same time through a FIFO of
 *     finite depth, so back-pressure exists here and ordering effects do not.
 *     A design that passes this can still stall on the real FIFO.
 *
 *   - COST. II, latency and resource use come from the HLS synthesis report,
 *     which this rung does not run. That is rung 4, in phase 4.
 *
 * ONE THING IT DOES SEE, CONTRARY TO EXPECTATION, AND IT IS WORTH KNOWING:
 * hls::stream::read() on an empty stream does not warn and does not return a
 * default -- it blocks on a condition variable, forever. So a csim harness that
 * reads one word too many HANGS, with no message, exactly like the hardware
 * would. That is why the depth check below exists instead of a bare call to
 * data_sink: a test that wedges the build teaches nothing, and the hang would
 * have to be diagnosed by attaching a debugger to a test rather than by
 * reading its output.
 */

#include "../data_src/data_src.cpp"
#include "../data_sink/data_sink.cpp"
#include "../../host_app_src/golden.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

int main()
{
    const size_t N = 256;

    std::vector<uint32_t> in(N), want(N), got(N, 0xdeadbeefu);
    base_fill_input(in.data(), N);

    // THE EXPECTATION HERE IS THE INPUT, NOT base_golden().
    //
    // base_golden() models the WHOLE chain, which since phase 2 includes the AI
    // Engine kernel. These two PL kernels are a pure loopback: data_src reads
    // DDR and streams it, data_sink receives it and writes it back. Nothing
    // between them computes anything.
    //
    // So this rung's reference is the identity. Using base_golden() here would
    // make the test fail for a reason that is not a defect -- which is worse
    // than not having the test, because it trains you to ignore it.
    //
    // A rung's reference model has to match the SUBSET OF THE DESIGN that rung
    // actually exercises. That is the general rule; it will matter again when
    // phase 4 adds a PL processing stage, at which point this expectation stops
    // being the identity and starts being that stage's operation.
    want = in;

    // The kernels take ap_uint<32>*, so convert explicitly rather than cast a
    // uint32_t buffer and rely on the layout happening to agree.
    std::vector<ap_uint<32>> kin(N), kout(N);
    for (size_t i = 0; i < N; ++i) kin[i] = in[i];

    hls::stream<axis_word_t> link("link");

    const bool mutant_armed = (MUTANT_SHORT != 0) || (MUTANT_VALUE != 0);

    printf("test_pl: rung 3 (HLS C simulation, native)\n");
    printf("  MUTANT_SHORT=%d MUTANT_VALUE=%d\n", MUTANT_SHORT, MUTANT_VALUE);

    data_src(kin.data(), link, N);

    const size_t produced = link.size();
    printf("  data_src produced %zu of %zu words\n", produced, N);

    // Depth check BEFORE draining. data_sink is written to read exactly N words
    // and a blocking read on an empty stream never returns, so asking it to
    // drain a short stream would hang this process with no output at all.
    if (produced < N) {
        printf("  SHORT STREAM: data_sink is about to ask for %zu words and will\n", N);
        printf("                block forever on word %zu. On hardware this is a\n", produced);
        printf("                DEADLOCK: no error, no timeout, nothing finishes.\n");
        printf("                Diagnosing it on real hardware needs the AXI-Stream\n");
        printf("                probe that phase 2 introduces.\n");
        if (!mutant_armed) {
            printf("test_pl: FAILED -- short stream with no mutant armed.\n");
            return EXIT_FAILURE;
        }
        printf("test_pl: mutant detected (short stream) -- the check works.\n");
        return EXIT_SUCCESS;
    }

    data_sink(link, kout.data(), N);
    for (size_t i = 0; i < N; ++i) got[i] = (uint32_t)kout[i];

    const size_t errors = base_compare(got.data(), want.data(), N, "test_pl");

    // With a mutant armed, a FAILURE is the expected outcome and this harness
    // reports success on seeing one. That inversion is what makes the rung
    // self-validating: `make test_pl MUTANT=value` MUST fail the comparison,
    // and if it does not, the comparison is not comparing anything.
    if (mutant_armed) {
        if (errors == 0) {
            printf("test_pl: FAILED -- a mutant is armed but every word matched.\n");
            printf("          The check is not checking. Fix that before trusting a PASS.\n");
            return EXIT_FAILURE;
        }
        printf("test_pl: mutant detected (%zu bad words) -- the check works.\n", errors);
        return EXIT_SUCCESS;
    }

    printf("test_pl: %s\n", errors ? "FAILED" : "all 256 words correct");
    return errors ? EXIT_FAILURE : EXIT_SUCCESS;
}
