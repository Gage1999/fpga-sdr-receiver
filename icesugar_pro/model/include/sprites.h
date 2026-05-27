#ifndef TRIAD_SPRITES_H
#define TRIAD_SPRITES_H

#include <stdint.h>

#define SPRITE_W 32
#define SPRITE_H 32
#define SPRITE_PIXELS (SPRITE_W * SPRITE_H)

typedef enum : uint8_t {
    SPR_BTN_FREQ_UP = 0,
    SPR_BTN_FREQ_DN = 1,
    SPR_BTN_VOL_UP  = 2,
    SPR_BTN_VOL_DN  = 3,
    SPR_BTN_MODE_FM = 4,
    SPR_BTN_MODE_AM = 5,
    SPR_BTN_MODE_GOES= 6,
    SPR_BTN_LAYOUT  = 7,
    SPR_BTN_REC     = 8,
    SPR_BTN_REC_ON  = 9,
    SPR_BTN_MUTE    = 10,
    SPR_BTN_MUTE_ON = 11,
    SPR_ICON_SAT    = 12,
    SPR_ICON_GEAR   = 13,
    SPR_ICON_RFLOCK = 14,
    SPR_ICON_BLANK  = 15,
    SPRITE_COUNT    = 16,
} sprite_id_t;

extern const uint16_t sprite_rom[SPRITE_COUNT * SPRITE_PIXELS];

static inline uint16_t sprite_pixel(uint8_t id, uint8_t x, uint8_t y) {
    if (id >= SPRITE_COUNT) return 0;
    return sprite_rom[(uint32_t)id * SPRITE_PIXELS + (uint32_t)y * SPRITE_W + x];
}

#endif
