#include "aux_roms.h"

#include "font.h"
#include "palette.h"
#include "sprites.h"

void aux_roms_default(aux_roms_t *out) {
    out->font_8x16     = font_8x16;
    out->font_16x32    = font_16x32;
    out->sprites       = sprite_rom;
    out->pal_waterfall = palette_waterfall;
    out->pal_goes       = palette_goes;
}
