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
    // PHASE 0: the datapath is DDR -> data_src -> AXI4-Stream -> data_sink ->
    // DDR. Nothing computes, so the reference answer is the input.
    //
    // Phase 3 replaces this with the FFT/coefficient/IFFT model. The signature
    // does not change, and neither does anything that calls it.
    std::memcpy(out, in, n * sizeof(uint32_t));
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
