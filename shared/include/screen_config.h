#ifndef TRIAD_SCREEN_CONFIG_H
#define TRIAD_SCREEN_CONFIG_H

#include <stdint.h>

#define SCREEN_W 800
#define SCREEN_H 480

typedef uint16_t pixel_t;

#define RGB565(r, g, b) (uint16_t)((((r) & 0xF8u) << 8) | (((g) & 0xFCu) << 3) | (((b) & 0xF8u) >> 3))

#define RGB565_R(p) (uint8_t)(((p) >> 8) & 0xF8u)
#define RGB565_G(p) (uint8_t)(((p) >> 3) & 0xFCu)
#define RGB565_B(p) (uint8_t)(((p) << 3) & 0xF8u)

#endif
