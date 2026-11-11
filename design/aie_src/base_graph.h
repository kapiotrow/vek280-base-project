/*
 * base_graph.h -- the AI Engine graph that goes into the xclbin.
 *
 *     data_src (PL) --AXIS--> StreamIn  (PLIO 32-bit)
 *                                 |
 *                            echo_kernel
 *                                 |
 *     data_sink (PL) <--AXIS-- StreamOut (PLIO 32-bit)
 *
 * NOTE WHAT DID NOT CHANGE: echo_kernel is the SAME kernel as in phase 1, with
 * the same signature, the same two implementations and the same golden. Only the
 * edges moved -- GMIO became PLIO. The kernel's ports are still buffers, and the
 * compiler inserts the stream-to-buffer conversion for us.
 *
 * That separation is the point. "Does my kernel compute the right thing" and
 * "does my PL plumbing work" are different questions, they fail in different
 * ways, and they are answered at different rungs. Phase 1 settled the first one
 * for this kernel; phase 2 only has to answer the second.
 *
 * ---------------------------------------------------------------------------
 * WHY 32 BITS
 *
 * `plio_32_bits`, matching axis_word_t in design/pl_src/base_axis.h. One int32
 * per beat.
 *
 * A 128-bit PLIO on this platform delivers ONE BEAT PER readincr() on the AIE
 * side and starves the kernel. The reference project this is derived from spent
 * about a week on that symptom, during which the fault was believed to be in
 * the shim placement, the port allocation, the widths, and eventually the whole
 * concept of PLIO -- because the observable is simply "no data arrives", which
 * is what almost every other defect also looks like.
 *
 * ---------------------------------------------------------------------------
 * THE PLIO NAME IS A CONTRACT ACROSS TWO FILES
 *
 * The string "StreamIn" here must match the linker config:
 *     stream_connect=data_src_0.out:ai_engine_0.StreamIn
 * A typo is not a compile error in either file. It is a link that silently does
 * not exist, and therefore a hang.
 *
 * ---------------------------------------------------------------------------
 * THE SECOND ARGUMENT IS A FILE, AND THAT FILE IS WHY PHASE 2 EXISTS
 *
 * input_plio::create(name, width, "stream_in.txt") names a text file that
 * aiesim reads INSTEAD of a PL kernel. There is no PL in an AIE simulation at
 * all. So `make aiesim` exercises this graph with a perfectly behaved,
 * infinitely patient producer, and tells you nothing whatsoever about whether
 * the real data_src will ever hand it a beat.
 *
 * A graph can pass aiesim cleanly and deadlock the instant it is linked. That
 * is the single most important limitation in the development cycle, and
 * `MUTANT=argidx` demonstrates it: aiesim passes, hw_emu hangs forever.
 */

#pragma once

#include <adf.h>
#include "echo_kernel.h"

using namespace adf;

class Base_graph : public graph
{
public:
    input_plio  stream_in;
    output_plio stream_out;
    kernel      echo;

    Base_graph()
    {
        stream_in  = input_plio::create("StreamIn",  plio_32_bits, "stream_in.txt");
        stream_out = output_plio::create("StreamOut", plio_32_bits, "stream_out.txt");

        echo = kernel::create(echo_kernel);
        source(echo) = "echo_kernel.cpp";
        runtime<ratio>(echo) = 0.9;

        // PLIO stream -> kernel BUFFER port. The kernel's signature is
        // unchanged from phase 1; giving the port dimensions is what tells the
        // compiler to insert the stream-to-buffer DMA.
        connect<>(stream_in.out[0], echo.in[0]);
        connect<>(echo.out[0], stream_out.in[0]);

        dimensions(echo.in[0])  = {ECHO_N};
        dimensions(echo.out[0]) = {ECHO_N};
    }
};
