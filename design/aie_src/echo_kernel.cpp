#include "echo_kernel.h"

#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>

/*
 * MUTANT_AIE -- deliberate breakage, selected by `make ... MUTANT=aie`.
 *
 * Shifts by one bit too many, in the VECTORIZED branch only. The scalar branch
 * is untouched, so this mutant does two things at once:
 *
 *   - the golden comparison fails, and
 *   - the vector/scalar equality check fails,
 *
 * which is the difference between "my kernel is wrong" and "my kernel is wrong
 * only when vectorized". The second is the one that is hard to find later, and
 * it is the normal outcome of a hand-vectorization: a shift in the wrong place,
 * a rounding mode that differs, an accumulator read at the wrong precision.
 */
#ifndef MUTANT_AIE
#  define MUTANT_AIE 0
#endif

// Lanes per vector operation.
//
// An AIE-ML vector register holds 512 bits, so v16int32 is the widest int32
// vector available. 8 is used here because ECHO_N must be a multiple of the
// lane count and 8 divides every geometry this project uses; widening it is a
// legitimate experiment and `make aiesim` will tell you what it bought.
static constexpr unsigned VEC = 8;

void echo_kernel(adf::input_buffer<int32> &in,
                 adf::output_buffer<int32> &out)
{
    const int32 *__restrict ip = in.data();
    int32 *__restrict op = out.data();

#if ECHO_VECTORIZE

    // The shift amount. With the mutant armed this is deliberately wrong, and
    // ONLY here -- the scalar branch below keeps the correct one.
    constexpr int SH = ECHO_SHIFT + (MUTANT_AIE ? 1 : 0);

    for (unsigned i = 0; i < ECHO_N; i += VEC)
    chess_prepare_for_pipelining
    chess_loop_range(ECHO_N / VEC, ECHO_N / VEC)
    {
        aie::vector<int32, VEC> v = aie::load_v<VEC>(ip + i);

        // aie::downshift is the vector equivalent of an arithmetic >> on int32.
        // It is NOT a rounding shift -- which is exactly why this branch can be
        // bit-identical to `>>` below. Had it rounded, the two branches would
        // differ by one LSB on half the inputs and the equality check would
        // (correctly) fail.
        aie::vector<int32, VEC> s = aie::downshift(v, SH);

        aie::vector<int32, VEC> r =
            aie::add(s, aie::broadcast<int32, VEC>((int32)ECHO_BIAS));

        aie::store_v(op + i, r);
    }

#else

    // The scalar reference. Slower and that is fine: its job is to be obviously
    // correct, so the vectorized branch has something to be checked against.
    for (unsigned i = 0; i < ECHO_N; ++i)
    chess_prepare_for_pipelining
    chess_loop_range(ECHO_N, ECHO_N)
    {
        op[i] = (ip[i] >> ECHO_SHIFT) + (int32)ECHO_BIAS;
    }

#endif
}
