#include "data_src.h"

/*
 * MUTANT_SHORT -- deliberate breakage, selected by `make ... MUTANT=short`.
 *
 * Writes n-1 words instead of n. data_sink then waits forever for a word that
 * never arrives and the emulation HANGS rather than printing a mismatch.
 *
 * That is the point: a hang is a different failure class from a wrong answer,
 * it is the class this toolchain produces most often, and it is worth meeting
 * once on purpose. Diagnosing it needs the AXI-Stream probe, which phase 2
 * introduces -- in phase 0 all you can see is that nothing ever finishes.
 */
#ifndef MUTANT_SHORT
#  define MUTANT_SHORT 0
#endif

extern "C" void data_src(const ap_uint<32> *in,
                         hls::stream<axis_word_t> &out,
                         ap_uint<32> n)
{
    // One m_axi master for the DDR read, one AXI4-Stream for the output, and an
    // AXI4-Lite slave carrying the scalars plus ap_start/ap_done.
    //
    // NOTE the bundle name: `control`. The host finds the scalar registers at
    // fixed offsets in this bundle, and xrt::ip (phase 4) addresses them by
    // those offsets directly. Rename the bundle and the host's register map
    // silently points at nothing.
#pragma HLS INTERFACE m_axi      port=in     offset=slave bundle=gmem depth=4096
#pragma HLS INTERFACE s_axilite  port=in     bundle=control
#pragma HLS INTERFACE axis       port=out
#pragma HLS INTERFACE s_axilite  port=n      bundle=control
#pragma HLS INTERFACE s_axilite  port=return bundle=control

    const ap_uint<32> limit = (MUTANT_SHORT && n > 0) ? (ap_uint<32>)(n - 1) : n;

    for (ap_uint<32> i = 0; i < limit; ++i) {
#pragma HLS PIPELINE II=1
        axis_word_t w;
        w.data = in[i];
        w.keep = (ap_uint<4>)-1;
        w.strb = (ap_uint<4>)-1;
        w.last = (i == limit - 1) ? 1 : 0;
        out.write(w);
    }
}
