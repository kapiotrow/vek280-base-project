#include "golden.h"

#include <cstdio>
#include <cstring>

/*
 * WHY THE STIMULUS IS NOT A COUNTER.
 *
 * `in[i] = i` is the obvious choice and it is a bad one: it is monotone, so a
 * one-element shift still looks almost right; it is small, so the high bits of
 * every word are zero and a truncation to 16 bits passes; and it is its own
 * index, so a kernel that ignores the stream entirely and synthesises i can
 * pass the check.
 *
 * The reference project measured this: a degenerate test pattern (a centred
 * impulse) detected 0 of 5 deliberately injected bugs, while an asymmetric one
 * detected 4 of 5. Pattern choice is not cosmetic.
 *
 * This LCG is deterministic from a fixed seed (so the golden and the stimulus
 * can never drift), uses the full 32-bit range, is non-monotone, and has
 * distinct elements over the lengths this project uses -- which is what makes
 * dropped, duplicated and reordered words all visible.
 */
void base_fill_input(uint32_t *dst, size_t n)
{
    uint32_t s = 0x12345678u;
    for (size_t i = 0; i < n; ++i) {
        // Numerical Recipes LCG, then an xorshift to break up the low bits.
        s = 1664525u * s + 1013904223u;
        uint32_t v = s;
        v ^= v >> 13;
        dst[i] = v;
    }
}

void base_golden(const uint32_t *in, uint32_t *out, size_t n)
{
    // PHASE 2: the AI Engine is now in the datapath, so the reference answer is
    // no longer the input. The chain is
    //
    //   DDR -> data_src -> PLIO -> echo_kernel -> PLIO -> data_sink -> DDR
    //
    // and echo_kernel computes (in >> ECHO_SHIFT) + ECHO_BIAS.
    //
    // THE SHIFT IS ARITHMETIC, ON A SIGNED int32. That is the one detail here
    // that can silently disagree with the hardware: the kernel's `>>` and
    // aie::downshift are both arithmetic shifts on int32, so the model has to
    // sign-extend before shifting. Doing it on the unsigned value instead would
    // be correct for half the inputs and wrong for the other half -- which is
    // worse than being wrong for all of them, because it looks like a hardware
    // bug rather than a modelling one.
    //
    // This is also the mirror of golden() in scripts/gen_vectors.py. The two
    // exist because the host needs the model in C++ and the simulation harness
    // needs it in Python. They are cross-checked on the STIMULUS by
    // `make gen_vectors`; keeping the OUTPUT halves in step is still manual, so
    // change them in the same commit.
    for (size_t i = 0; i < n; ++i) {
        const int32_t v = (int32_t)in[i] >> BASE_ECHO_SHIFT;
        out[i] = (uint32_t)(v + BASE_ECHO_BIAS);
    }
}

size_t base_compare(const uint32_t *got, const uint32_t *want, size_t n,
                    const char *tag, size_t max_report)
{
    size_t errors = 0;
    for (size_t i = 0; i < n; ++i) {
        if (got[i] != want[i]) {
            if (errors < max_report)
                printf("[%s] MISMATCH [%zu]: got 0x%08x want 0x%08x\n",
                       tag, i, got[i], want[i]);
            ++errors;
        }
    }
    // max_report == 0 means "count, say nothing" -- used by the self-test,
    // which calls this a thousand times and only wants the number.
    if (max_report > 0 && errors > max_report)
        printf("[%s] ... and %zu more\n", tag, errors - max_report);
    return errors;
}
