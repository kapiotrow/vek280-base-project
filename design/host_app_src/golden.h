/*
 * golden.h -- the reference model, and the stimulus it is defined against.
 *
 * THIS FILE AND golden.cpp DELIBERATELY INCLUDE NO XRT AND NO ADF HEADER.
 *
 * That is a rule, not an accident. It means the model compiles with the system
 * g++ and runs in milliseconds (`make test_host`), so arithmetic is debugged at
 * rung 1 of the development cycle instead of inside a ~hour-long hw_emu run.
 * Keep every line of real computation on this side of that boundary; the moment
 * the model needs an xrt type, you have lost the cheapest rung you own.
 *
 * EXTENSION POINT 3 of 3: when the design starts computing something (phase 3),
 * base_golden() is where you say what the answer should be.
 */

#pragma once

#include <cstddef>
#include <cstdint>

// Default element count. Small on purpose: every rung through phase 4 ends in
// hw_emu, and hw_emu time scales with the data. Sizing up is a hardware
// exercise, not an emulation one.
#ifndef BASE_N
#  define BASE_N 1024
#endif

// Fill `dst` with the project's canonical stimulus: BASE_N deterministic,
// distinct, non-monotone 32-bit words from a fixed seed.
void base_fill_input(uint32_t *dst, size_t n);

// The AI Engine kernel's constants, as the HOST sees them.
//
// Deliberately named BASE_ECHO_* rather than ECHO_*: these reach the host
// through GCC_FLAGS while ECHO_* reach the AIE kernel through --Xpreproc, and
// both come from ONE Makefile variable each. The distinct prefix is so that a
// reader can tell at a glance which toolchain a given spelling belongs to --
// and so that a host file accidentally picking up the kernel's header does not
// quietly satisfy itself with the wrong default.
#ifndef BASE_ECHO_SHIFT
#  define BASE_ECHO_SHIFT 1
#endif
#ifndef BASE_ECHO_BIAS
#  define BASE_ECHO_BIAS 1000
#endif
// Elements the AIE kernel consumes per firing. The host needs it to know how
// many graph iterations to enable: too few and the tail of the stream is never
// consumed, which is a hang rather than an error.
#ifndef BASE_ECHO_N
#  define BASE_ECHO_N 256
#endif

// The reference answer: what the whole PS -> PL -> AIE -> PL -> PS chain should
// produce. Since phase 2 that is the AIE kernel's operation, not a copy.
void base_golden(const uint32_t *in, uint32_t *out, size_t n);

// Compare `got` against `want`, print up to `max_report` mismatches, and return
// the number of differing elements. `tag` just labels the output.
size_t base_compare(const uint32_t *got, const uint32_t *want, size_t n,
                    const char *tag, size_t max_report = 8);
