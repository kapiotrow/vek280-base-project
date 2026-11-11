/*
 * echo_graph.cpp -- graph instantiation, plus the simulation harness.
 *
 * The same main() serves both x86sim (rung 2, functional, seconds) and aiesim
 * (rung 4, cycle-approximate, minutes). It reads the stimulus that
 * scripts/gen_vectors.py produced, drives it through the graph, and dumps the
 * result for scripts/check_sim_output.py to compare against the golden from
 * that same script.
 *
 * TWO IDIOMS HERE ARE LOAD-BEARING AND NEITHER IS OBVIOUS. Both were paid for
 * on the reference project; see docs/06-traps.md.
 *
 *   1. ARM THE OUTPUT DRAIN BEFORE SENDING THE INPUT. A full output window
 *      stalls the kernel, and a stalled kernel stops consuming the input DMA
 *      you would then be waiting on. Send-then-drain deadlocks.
 *
 *   2. run(-1), then _exit(). With run(N), the ADF runtime begins tearing the
 *      simulation down once N invocations complete -- and during teardown no
 *      cycles are driven for the shim DMA, so a GMIO wait() that has not
 *      finished never will. run(-1) keeps the graph alive. end() and the
 *      simulator's cycle timeout then deadlock each other, and the graph
 *      destructor hangs talking to a stopped event loop, so the harness leaves
 *      by _exit() and the Makefile wraps the run in `timeout` as a net.
 */

#include "echo_graph.h"

Echo_graph echo_graph;

#if defined(__X86SIM__) || defined(__AIESIM__)

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <unistd.h>

static constexpr int N_INVOCATIONS = ECHO_TOTAL / ECHO_N;
static constexpr int CHUNK_BYTES   = ECHO_N * (int)sizeof(int32_t);
static constexpr int TOTAL_BYTES   = ECHO_TOTAL * (int)sizeof(int32_t);

static bool load_raw(const char *path, void *dst, size_t bytes)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("[echo] ERROR: cannot open %s\n", path); return false; }
    size_t got = fread(dst, 1, bytes, f);
    fclose(f);
    if (got != bytes) {
        printf("[echo] ERROR: %s is %zu bytes, expected %zu\n", path, got, bytes);
        return false;
    }
    printf("[echo] loaded %s (%zu bytes)\n", path, bytes);
    return true;
}

static bool dump_raw(const char *path, const void *src, size_t bytes)
{
    FILE *f = fopen(path, "wb");
    if (!f) { printf("[echo] ERROR: cannot write %s\n", path); return false; }
    size_t put = fwrite(src, 1, bytes, f);
    fclose(f);
    if (put != bytes) { printf("[echo] ERROR: short write to %s\n", path); return false; }
    printf("[echo] wrote %s (%zu bytes)\n", path, bytes);
    return true;
}

/*
 * int main(void) -- NOT main(int argc, char **argv), AND THIS IS NOT A STYLE
 * CHOICE.
 *
 * For --target=hw, aiecompiler compiles this file a second time as a PS
 * testbench wrapper, with
 *
 *     -D main\(...\)=ps_main\(...\)
 *
 * on the command line. The replacement text is the LITERAL `ps_main(...)`, not
 * `ps_main(__VA_ARGS__)`, so a signature of `main(int argc, char **argv)`
 * expands to `ps_main(...)` and the parameter names are simply gone. Any body
 * that then mentions argc or argv fails to compile with
 *
 *     error: use of undeclared identifier 'argc'
 *
 * pointing at a line that is obviously correct, during a step ("Compiling PL
 * Block ps_i3") you did not ask for. x86sim is unaffected, so the graph builds
 * and simulates perfectly right up until the first `make graph`.
 *
 * Taking no arguments avoids the whole thing. Configuration comes from the
 * environment, which is also how the harness stays usable from a Makefile.
 */
int main(void)
{
    const char *datadir = getenv("ECHO_DATA_DIR");
    if (!datadir || !datadir[0]) datadir = "aiesim_data/echo";

    const char *outdir = getenv("ECHO_OUT_DIR");
    if (!outdir || !outdir[0]) outdir = ".";

    printf("[echo] ECHO_N=%d ECHO_TOTAL=%d -> %d invocations\n",
           ECHO_N, ECHO_TOTAL, N_INVOCATIONS);
    printf("[echo] ECHO_SHIFT=%d ECHO_BIAS=%d ECHO_VECTORIZE=%d MUTANT_AIE=%d\n",
           ECHO_SHIFT, ECHO_BIAS, ECHO_VECTORIZE, MUTANT_AIE);
    fflush(stdout);

    // GMIO::malloc, not malloc: a GMIO buffer has to be in memory the shim DMA
    // can reach, with the alignment it expects. A plain heap pointer may work
    // by accident and then stop working when the allocation moves.
    int32_t *in_buf  = (int32_t *)GMIO::malloc(TOTAL_BYTES);
    int32_t *out_buf = (int32_t *)GMIO::malloc(TOTAL_BYTES);

    char path[512];
    snprintf(path, sizeof(path), "%s/in.bin", datadir);
    if (!load_raw(path, in_buf, TOTAL_BYTES)) return 1;

    // Poison the output. An all-zero dump and a never-written dump look
    // identical otherwise, and "the kernel never ran" is a much more common
    // outcome than "the kernel computed zero".
    memset(out_buf, 0xA5, TOTAL_BYTES);

    echo_graph.init();
    echo_graph.run(-1);

    // One send/drain pair per invocation, drain armed first. See the header.
    for (int k = 0; k < N_INVOCATIONS; ++k) {
        echo_graph.gmio_echo_out.aie2gm_nb((char *)out_buf + (size_t)k * CHUNK_BYTES,
                                           CHUNK_BYTES);
        echo_graph.gmio_echo_in.gm2aie_nb((char *)in_buf + (size_t)k * CHUNK_BYTES,
                                          CHUNK_BYTES);
        echo_graph.gmio_echo_in.wait();
        echo_graph.gmio_echo_out.wait();
        printf("[echo] invocation %d/%d drained %d B\n", k + 1, N_INVOCATIONS, CHUNK_BYTES);
        fflush(stdout);
    }

    // Cheap sanity line, so a dead run is obvious in the log instead of showing
    // up later as a mystery diff.
    int poisoned = 0;
    for (int i = 0; i < ECHO_TOTAL; ++i)
        if ((uint32_t)out_buf[i] == 0xA5A5A5A5u) ++poisoned;
    printf("[echo] output: %d/%d elements still poisoned\n", poisoned, ECHO_TOTAL);
    if (poisoned == ECHO_TOTAL)
        printf("[echo] WARNING: nothing was written -- the kernel probably never ran\n");

    snprintf(path, sizeof(path), "%s/echo_out.bin", outdir);
    bool ok = dump_raw(path, out_buf, TOTAL_BYTES);

    fflush(stdout);
    _exit(ok ? 0 : 1);
}

#endif // __X86SIM__ || __AIESIM__
