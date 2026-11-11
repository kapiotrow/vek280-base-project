/*
 * base_graph.cpp -- graph instantiation, and a minimal aiesim entry point.
 *
 * Much shorter than echo_graph.cpp, and the reason is instructive: with PLIO
 * there is nothing for the harness to drive. aiesim reads the input file named
 * in the graph and writes the output file, by itself. No GMIO::malloc, no
 * drain-before-send ordering, no per-invocation waits.
 *
 * That convenience IS the limitation. The harness is not driving a PL kernel;
 * it is not driving anything. See the header.
 *
 * run(N) and end() are used here, unlike echo_graph.cpp's run(-1)/_exit().
 * The reason that was necessary there was GMIO: with run(N) the runtime begins
 * tearing down after N invocations, and during teardown no cycles are driven
 * for the shim DMA, so an outstanding GMIO wait() never returns. This graph has
 * no GMIO and nothing to wait on, so the ordinary pattern is correct.
 */

#include "base_graph.h"

Base_graph base_graph;

#if defined(__AIESIM__) || defined(__X86SIM__)

#include <cstdio>

static constexpr int N_INVOCATIONS = ECHO_TOTAL / ECHO_N;

// int main(void), NOT main(int argc, char **argv). For --target=hw the graph
// file is recompiled as a PS testbench with `-D main(...)=ps_main(...)`, where
// the replacement is the LITERAL `...`, so parameter names are discarded and
// any reference to argc/argv fails to compile. See echo_graph.cpp.
int main(void)
{
    printf("[base] PLIO graph: ECHO_N=%d x %d invocations\n", ECHO_N, N_INVOCATIONS);
    printf("[base] ECHO_SHIFT=%d ECHO_BIAS=%d ECHO_VECTORIZE=%d ECHO_SRC=%d\n",
           ECHO_SHIFT, ECHO_BIAS, ECHO_VECTORIZE, ECHO_SRC_SYNTH);
    printf("[base] input comes from stream_in.txt -- THERE IS NO PL HERE\n");
    fflush(stdout);

    base_graph.init();
    base_graph.run(N_INVOCATIONS);
    base_graph.end();

    printf("[base] done -- output is in stream_out.txt\n");
    fflush(stdout);
    return 0;
}

#endif
