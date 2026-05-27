#ifndef TRIAD_AUX_ROMS_H
#define TRIAD_AUX_ROMS_H

#include <stdint.h>

#include "font.h"
#include "palette.h"
#include "sprites.h"

// Bundle of ROM-resident tables the pixel shader reads from.
// On host: pointers into static const arrays in shared/src/*.c.
// On hardware: pointers stand in for EBR ROM ports — the SV port the
// equivalent indices straight into block-RAM read addresses.
typedef struct {
    const uint8_t  *font_8x16;     // FONT_8X16_COUNT * FONT_8X16_H bytes
    const uint16_t *font_16x32;    // FONT_16X32_COUNT * FONT_16X32_H halfwords
    const uint16_t *sprites;       // SPRITE_COUNT * SPRITE_PIXELS halfwords
    const uint16_t *pal_waterfall; // PALETTE_SIZE halfwords
    const uint16_t *pal_goes;       // PALETTE_SIZE halfwords
} aux_roms_t;

void aux_roms_default(aux_roms_t *out);

#endif
