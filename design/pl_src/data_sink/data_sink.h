/*
 * data_sink.h -- AXI4-Stream -> DDR consumer.
 *
 * Reads `n` words off an AXI4-Stream port and writes them to `out` (an m_axi
 * master into LPDDR), where the host reads them back.
 *
 * MUTANT=value makes it corrupt one word. See the note in the .cpp.
 */

#pragma once

#include "../base_axis.h"

extern "C" void data_sink(hls::stream<axis_word_t> &in,
                          ap_uint<32> *out,
                          ap_uint<32> n);
