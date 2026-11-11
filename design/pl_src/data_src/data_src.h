/*
 * data_src.h -- DDR -> AXI4-Stream producer.
 *
 * Reads `n` 32-bit words from `in` (an m_axi master into LPDDR) and pushes them
 * out of an AXI4-Stream port. In phase 0 that stream goes straight to data_sink;
 * from phase 2 it goes to the AIE array through a PLIO.
 *
 * MUTANT=short makes it write n-1 words. See the note in the .cpp.
 */

#pragma once

#include "../base_axis.h"

extern "C" void data_src(const ap_uint<32> *in,
                         hls::stream<axis_word_t> &out,
                         ap_uint<32> n);
