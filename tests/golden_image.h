#ifndef TRIAD_GOLDEN_IMAGE_H
#define TRIAD_GOLDEN_IMAGE_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Goldens use a trivial PPM-style format (header + raw RGB888) so we don't
// take any image-library dependency. Files end with `.ppm` and live in
// tests/golden/.
//
// Compare-on-load: if the golden doesn't exist, the helper writes it and
// reports a "WROTE NEW GOLDEN" message - but only when --update-goldens is
// passed; otherwise this is treated as a failure (golden was missing).

extern int g_update_goldens;
extern const char *g_golden_dir;

static inline void rgb565_to_rgb888(const uint16_t *src, uint8_t *dst, size_t pixels) {
    for (size_t i = 0; i < pixels; i++) {
        uint16_t p = src[i];
        dst[i * 3 + 0] = (uint8_t)((p >> 8) & 0xF8);
        dst[i * 3 + 1] = (uint8_t)((p >> 3) & 0xFC);
        dst[i * 3 + 2] = (uint8_t)((p << 3) & 0xF8);
    }
}

static inline int write_ppm(const char *path, const uint16_t *pixels, int w, int h) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    uint8_t *rgb = (uint8_t *)malloc((size_t)w * h * 3);
    if (!rgb) { fclose(f); return -1; }
    rgb565_to_rgb888(pixels, rgb, (size_t)w * h);
    fwrite(rgb, 1, (size_t)w * h * 3, f);
    free(rgb);
    fclose(f);
    return 0;
}

// Compare against golden. If file is missing & update mode is on, write it.
// Returns 0 on match (or successful write); nonzero on mismatch / missing.
static inline int check_golden(const char *name, const uint16_t *pixels, int w, int h) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s.ppm", g_golden_dir, name);

    FILE *f = fopen(path, "rb");
    if (!f) {
        if (g_update_goldens) {
            if (write_ppm(path, pixels, w, h) != 0) {
                fprintf(stderr, "  could not write golden %s\n", path);
                return 1;
            }
            fprintf(stderr, "  WROTE NEW GOLDEN: %s\n", path);
            return 0;
        }
        fprintf(stderr, "  MISSING golden: %s (re-run with --update-goldens)\n", path);
        return 1;
    }

    int gw = 0, gh = 0, max = 0;
    if (fscanf(f, "P6 %d %d %d ", &gw, &gh, &max) != 3 || gw != w || gh != h) {
        fclose(f);
        fprintf(stderr, "  golden %s: header mismatch (got %dx%d)\n", path, gw, gh);
        return 1;
    }
    uint8_t *rgb_got = (uint8_t *)malloc((size_t)w * h * 3);
    uint8_t *rgb_want = (uint8_t *)malloc((size_t)w * h * 3);
    if (!rgb_got || !rgb_want) { free(rgb_got); free(rgb_want); fclose(f); return 1; }
    rgb565_to_rgb888(pixels, rgb_got, (size_t)w * h);
    if (fread(rgb_want, 1, (size_t)w * h * 3, f) != (size_t)w * h * 3) {
        fclose(f); free(rgb_got); free(rgb_want);
        fprintf(stderr, "  golden %s: short read\n", path);
        return 1;
    }
    fclose(f);

    int mismatches = 0;
    for (size_t i = 0; i < (size_t)w * h * 3; i++) {
        if (rgb_got[i] != rgb_want[i]) mismatches++;
    }
    free(rgb_got);
    free(rgb_want);

    if (mismatches > 0) {
        if (g_update_goldens) {
            if (write_ppm(path, pixels, w, h) == 0) {
                fprintf(stderr, "  UPDATED golden: %s (%d bytes differed)\n", path, mismatches);
                return 0;
            }
        }
        // Also dump the actual to a sibling .actual.ppm for easy inspection.
        char actual_path[600];
        snprintf(actual_path, sizeof(actual_path), "%s/%s.actual.ppm", g_golden_dir, name);
        (void)write_ppm(actual_path, pixels, w, h);
        fprintf(stderr, "  GOLDEN MISMATCH %s: %d bytes differ; actual saved to %s\n",
                path, mismatches, actual_path);
        return 1;
    }
    return 0;
}

#endif
