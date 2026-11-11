/*
 * test_golden.cpp -- rung 1 of the development cycle: `make test_host`.
 *
 * Milliseconds, system g++, no Vitis, no XRT, no hardware.
 *
 * In phase 0 the model is a memcpy, so there is almost nothing to test about
 * the model -- and that is exactly why this file is worth reading. What it
 * tests is THE CHECKER: that base_compare() actually fires. A verification step
 * that has never been observed to fail is not known to work, and a comparison
 * that silently compares nothing is indistinguishable from a passing one.
 *
 * From phase 3 this file grows assertions about the real golden, and these four
 * stay as the floor.
 */

#include "../golden.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

static int failures = 0;

static void check(bool ok, const char *what)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++failures;
}

int main()
{
    const size_t N = 1024;
    std::vector<uint32_t> a(N), b(N), g(N);

    printf("test_golden: rung 1 (native, no hardware)\n");

    // 1. The stimulus is deterministic. If it were not, the golden and the data
    //    the board actually saw could disagree and nothing would say so.
    base_fill_input(a.data(), N);
    base_fill_input(b.data(), N);
    bool same = true;
    for (size_t i = 0; i < N; ++i) same = same && (a[i] == b[i]);
    check(same, "stimulus is reproducible from its seed");

    // 2. The stimulus has distinct elements, so dropped/duplicated/reordered
    //    words are detectable at all.
    bool distinct = true;
    for (size_t i = 0; i < N && distinct; ++i)
        for (size_t j = i + 1; j < N && distinct; ++j)
            if (a[i] == a[j]) distinct = false;
    check(distinct, "stimulus elements are distinct");

    // 3. The checker passes on correct data.
    base_golden(a.data(), g.data(), N);
    check(base_compare(g.data(), g.data(), N, "self") == 0,
          "base_compare returns 0 on identical buffers");

    // 4. THE IMPORTANT ONE: the checker fires on a single corrupted bit, at
    //    every position. This is the test that proves the test can fail.
    size_t missed = 0;
    for (size_t i = 0; i < N; ++i) {
        std::vector<uint32_t> bad = g;
        bad[i] ^= 1u;
        if (base_compare(bad.data(), g.data(), N, "mutant", 0) != 1) ++missed;
    }
    check(missed == 0, "base_compare detects a 1-bit error at every position");

    printf("test_golden: %s\n", failures ? "FAILED" : "all checks passed");
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
