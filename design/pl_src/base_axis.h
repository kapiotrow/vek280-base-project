/*
 * base_axis.h
 * The ONE definition of the AXI4-Stream word used everywhere in this project.
 *
 * Both PL kernels and (from phase 2) the AIE PLIO agree on this width. It lives
 * in one header because a stream-width disagreement does not fail to compile --
 * v++ links it happily and the design deadlocks at run time, which is the most
 * expensive class of bug in this toolchain.
 *
 * 32 bits is deliberate. A 128-bit PLIO on this platform delivers one beat per
 * readincr() on the AIE side and starves the kernel; 32 bits is the width the
 * reference design settled on after that cost a week. See docs/06-traps.md.
 */

#pragma once

#include <ap_int.h>
#include <ap_axi_sdata.h>
#include <hls_stream.h>

typedef ap_axiu<32, 0, 0, 0> axis_word_t;
