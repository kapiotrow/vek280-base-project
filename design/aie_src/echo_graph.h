/*
 * echo_graph.h -- the smallest useful AI Engine graph.
 *
 *     gmio_echo_in --> echo_kernel --> gmio_echo_out
 *        (DDR)                             (DDR)
 *
 * No PL, no PLIO, no xclbin. The APU (or, in simulation, the harness in
 * echo_graph.cpp) pushes data from DDR into the array and pulls the result back
 * out, and that is the whole design.
 *
 * WHY GMIO FIRST, AND NOT PLIO
 *
 * GMIO is the shortest path into the array: it needs nothing in the PL, no
 * stream_connect, no linker config, no shim placement. So it is the right way
 * to answer "does my kernel compute the right thing" -- which is a question
 * about the kernel, and should not be entangled with a question about the PL.
 *
 * It is also the mechanism that lets phase 1 stay entirely in simulation. Both
 * rungs here -- x86sim and aiesim -- run with no Vivado at all.
 *
 * PLIO arrives in phase 2, and phase 2 exists because of a specific limitation:
 * aiesim FAKES the PL boundary, feeding PLIO from text files. A graph can pass
 * aiesim cleanly and still deadlock the moment a real PL kernel is on the other
 * end. See docs/04-dev-cycle.md.
 */

#pragma once

#include <adf.h>
#include "echo_kernel.h"

using namespace adf;

class Echo_graph : public graph
{
public:
    input_gmio  gmio_echo_in;
    output_gmio gmio_echo_out;
    kernel      echo;

    Echo_graph()
    {
        // burst length 64 bytes, bandwidth 1000 MB/s. Both are hints the
        // compiler uses to size the shim DMA; neither changes what the kernel
        // computes, and neither is a measurement.
        gmio_echo_in  = input_gmio::create("gmio_echo_in", 64, 1000);
        gmio_echo_out = output_gmio::create("gmio_echo_out", 64, 1000);

        echo = kernel::create(echo_kernel);
        source(echo) = "echo_kernel.cpp";

        // runtime<ratio> is a PLACEMENT HINT: how much of a core's time this
        // kernel wants. It is NOT a utilization figure and NOT a performance
        // knob. Reading 0.9 as "the design uses 90% of the array" is wrong, and
        // it is a common enough mistake to be worth a comment.
        runtime<ratio>(echo) = 0.9;

        connect<>(gmio_echo_in.out[0], echo.in[0]);
        connect<>(echo.out[0], gmio_echo_out.in[0]);

        // The window size, in elements, per invocation. This is the constant
        // that MUST agree between the kernel, this graph and the harness that
        // drives it -- which is why all three take it from one Makefile
        // variable rather than defining it three times.
        dimensions(echo.in[0])  = {ECHO_N};
        dimensions(echo.out[0]) = {ECHO_N};
    }
};
