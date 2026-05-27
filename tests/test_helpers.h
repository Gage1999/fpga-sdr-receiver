#ifndef TRIAD_TEST_HELPERS_H
#define TRIAD_TEST_HELPERS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Minimal test framework. CTest reports pass/fail via exit code; per-test
// diagnostic goes to stderr.

static int g_fail_count = 0;
static const char *g_current_case = "(unset)";

#define T_CASE(name)                                                  \
    static int test_case_##name(void);                                \
    static int run_##name(void) {                                     \
        g_current_case = #name;                                       \
        int prev = g_fail_count;                                      \
        int rc = test_case_##name();                                  \
        if (g_fail_count == prev && rc == 0) {                        \
            fprintf(stderr, "  PASS  %s\n", #name);                   \
            return 0;                                                 \
        }                                                             \
        fprintf(stderr, "  FAIL  %s\n", #name);                       \
        return 1;                                                     \
    }                                                                 \
    static int test_case_##name(void)

#define T_EXPECT(cond)                                                \
    do {                                                              \
        if (!(cond)) {                                                \
            fprintf(stderr, "    %s:%d  EXPECT(%s) failed in %s\n",   \
                    __FILE__, __LINE__, #cond, g_current_case);       \
            g_fail_count++;                                           \
        }                                                             \
    } while (0)

#define T_EXPECT_EQ(a, b)                                             \
    do {                                                              \
        long long _aa = (long long)(a);                               \
        long long _bb = (long long)(b);                               \
        if (_aa != _bb) {                                             \
            fprintf(stderr,                                           \
              "    %s:%d  EXPECT_EQ(%s=%lld, %s=%lld) failed in %s\n",\
              __FILE__, __LINE__, #a, _aa, #b, _bb, g_current_case);  \
            g_fail_count++;                                           \
        }                                                             \
    } while (0)

#define T_RUN(name) (void)run_##name()

#define T_FINISH()                                                    \
    do {                                                              \
        if (g_fail_count > 0) {                                       \
            fprintf(stderr, "%d failure(s)\n", g_fail_count);         \
            return 1;                                                 \
        }                                                             \
        fprintf(stderr, "all green\n");                               \
        return 0;                                                     \
    } while (0)

#endif
