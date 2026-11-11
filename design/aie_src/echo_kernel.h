/*
 * echo_kernel.h -- the project's first AI Engine kernel.
 *
 * One AIE core, one buffer in, one buffer out:
 *
 *     out[i] = (in[i] >> ECHO_SHIFT) + ECHO_BIAS
 *
 * It is deliberately almost trivial. What it exists to demonstrate is not the
 * arithmetic but the three things every AIE kernel after it will need:
 *
 *   1. the input_buffer / output_buffer interface and its window semantics,
 *   2. a VECTORIZED implementation and a SCALAR one that are bit-identical,
 *      with the equality CHECKED rather than assumed (ECHO_VECTORIZE),
 *   3. compile-time geometry that must agree between the kernel, the graph and
 *      whatever drives it -- passed from one Makefile variable to both.
 *
 * EXTENSION POINT: replace the body. The signature, the graph and the harness
 * do not need to change.
 */

#pragma once

#include <adf.h>

// Elements per invocation. The kernel is called once per ECHO_N elements, and
// the harness sends ECHO_TOTAL of them, so the graph fires ECHO_TOTAL/ECHO_N
// times. Both are set from the Makefile.
//
// Multiple firings are not incidental: a single-invocation test cannot catch a
// kernel that works only on its first call, which is a real failure mode once
// double buffering is involved -- the second (pong) buffer is a different
// address and is filled by a different DMA descriptor.
#ifndef ECHO_N
#  define ECHO_N 256
#endif

#ifndef ECHO_TOTAL
#  define ECHO_TOTAL 1024
#endif

// The operation's two constants. Defaults make the kernel do something
// non-trivial: a pure passthrough would make the vector/scalar equality check
// vacuous and the golden model pointless.
#ifndef ECHO_SHIFT
#  define ECHO_SHIFT 1
#endif

#ifndef ECHO_BIAS
#  define ECHO_BIAS 1000
#endif

// ECHO_SRC_SYNTH -- THE BISECT SWITCH. 0 (default) = read the input normally.
// 1 = SYNTHESIZE the output and never touch the input at all.
//
// This exists for one specific situation, and it is the situation phase 2
// produces: the design hangs, nothing arrives at the other end, and there are
// two causes that are indistinguishable from outside --
//
//     (a) the input never delivers, so the kernel blocks forever, or
//     (b) the core never runs, so nothing is there to consume the input.
//
// Both look like "no output". Building with ECHO_SRC=synth removes the kernel's
// dependence on its input entirely:
//
//     output appears  -> the core runs; the fault is upstream of it  (a)
//     still nothing   -> the core is not running; the input is a red herring (b)
//
// On the reference project this one distinction was the difference between
// debugging the PLIO and debugging a kernel that was starving on a different
// port. Build it, look, build it back.
#ifndef ECHO_SRC_SYNTH
#  define ECHO_SRC_SYNTH 0
#endif

// 1 (default) = the vectorized implementation. 0 = the scalar reference.
//
// These two must produce BIT-IDENTICAL output, and `make x86sim` runs both and
// compares them. A vectorized kernel that is merely "close" to its scalar
// reference is a kernel whose rounding you do not understand yet.
#ifndef ECHO_VECTORIZE
#  define ECHO_VECTORIZE 1
#endif

void echo_kernel(adf::input_buffer<int32> &in,
                 adf::output_buffer<int32> &out);
