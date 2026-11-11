#include "data_sink.h"

/*
 * MUTANT_VALUE -- deliberate breakage, selected by `make ... MUTANT=value`.
 *
 * Flips one bit in the middle word. Everything completes normally and the host's
 * check is the only thing that notices.
 *
 * Run it once. A verification step that has never been seen to fail is not
 * known to work: a check that silently compares nothing looks exactly like a
 * check that passes, and this project's reference design shipped a whole sweep
 * with a statistic reading 0.0000 for precisely that reason.
 */
#ifndef MUTANT_VALUE
#  define MUTANT_VALUE 0
#endif

extern "C" void data_sink(hls::stream<axis_word_t> &in,
                          ap_uint<32> *out,
                          ap_uint<32> n)
{
#pragma HLS INTERFACE axis       port=in
#pragma HLS INTERFACE m_axi      port=out    offset=slave bundle=gmem depth=4096
#pragma HLS INTERFACE s_axilite  port=out    bundle=control
#pragma HLS INTERFACE s_axilite  port=n      bundle=control
#pragma HLS INTERFACE s_axilite  port=return bundle=control

    for (ap_uint<32> i = 0; i < n; ++i) {
#pragma HLS PIPELINE II=1
        axis_word_t w = in.read();
        ap_uint<32> v = w.data;
        if (MUTANT_VALUE && i == n / 2)
            v = v ^ (ap_uint<32>)1;
        out[i] = v;
    }
}
