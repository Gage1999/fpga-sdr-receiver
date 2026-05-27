#ifndef TRIAD_FONT_H
#define TRIAD_FONT_H

#include <stdint.h>

#define FONT_8X16_W 8
#define FONT_8X16_H 16
#define FONT_8X16_FIRST 0x20u
#define FONT_8X16_COUNT 96u

#define FONT_16X32_W 16
#define FONT_16X32_H 32
#define FONT_16X32_FIRST 0x20u
#define FONT_16X32_COUNT 96u

extern const uint8_t  font_8x16[FONT_8X16_COUNT * FONT_8X16_H];
extern const uint16_t font_16x32[FONT_16X32_COUNT * FONT_16X32_H];

static inline uint8_t font_8x16_row(char c, uint8_t row) {
    uint8_t idx = (uint8_t)c;
    if (idx < FONT_8X16_FIRST || idx >= FONT_8X16_FIRST + FONT_8X16_COUNT) idx = '?';
    return font_8x16[(idx - FONT_8X16_FIRST) * FONT_8X16_H + row];
}

static inline uint16_t font_16x32_row(char c, uint8_t row) {
    uint8_t idx = (uint8_t)c;
    if (idx < FONT_16X32_FIRST || idx >= FONT_16X32_FIRST + FONT_16X32_COUNT) idx = '?';
    return font_16x32[(idx - FONT_16X32_FIRST) * FONT_16X32_H + row];
}

#endif
