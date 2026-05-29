// ROM equivalence harness: sweeps every address of font_16x32_rom and
// sprite_rom (loaded from the build/*.mem files) and byte-compares against the
// C source-of-truth arrays (font_16x32[], sprite_rom[]). A pass proves the
// rom_to_mem.py -> $readmemh -> SV-ROM path is lossless, so the hardware ROMs
// hold exactly what the C reference shader reads.

#include <cstdio>
#include <cstdint>

#include "Vrom_check_top.h"
#include "verilated.h"

extern "C" {
#include "aux_roms.h"
#include "font.h"
#include "sprites.h"
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    aux_roms_t roms;
    aux_roms_default(&roms);

    Vrom_check_top *dut = new Vrom_check_top;

    size_t font_n = (size_t)FONT_16X32_COUNT * FONT_16X32_H;   // 3072
    size_t spr_n  = (size_t)SPRITE_COUNT * SPRITE_PIXELS;      // 16384

    size_t font_ok = 0, spr_ok = 0;
    bool   have_mm = false;
    char   first[128] = {0};

    for (size_t a = 0; a < font_n; a++) {
        dut->font_addr = (uint16_t)a;
        dut->eval();
        uint16_t got = dut->font_data;
        uint16_t exp = roms.font_16x32[a];
        if (got == exp) font_ok++;
        else if (!have_mm) {
            have_mm = true;
            std::snprintf(first, sizeof(first),
                          "font_16x32[%zu]: rom=0x%04x C=0x%04x", a, got, exp);
        }
    }

    for (size_t a = 0; a < spr_n; a++) {
        dut->sprite_addr = (uint16_t)a;
        dut->eval();
        uint16_t got = dut->sprite_data;
        uint16_t exp = roms.sprites[a];
        if (got == exp) spr_ok++;
        else if (!have_mm) {
            have_mm = true;
            std::snprintf(first, sizeof(first),
                          "sprite_rom[%zu]: rom=0x%04x C=0x%04x", a, got, exp);
        }
    }

    std::printf("[font_16x32_rom ] matched %zu / %zu\n", font_ok, font_n);
    std::printf("[sprite_rom     ] matched %zu / %zu\n", spr_ok, spr_n);
    if (have_mm) std::printf("  first mismatch: %s\n", first);

    delete dut;

    bool pass = (font_ok == font_n) && (spr_ok == spr_n);
    std::printf("ROM equivalence: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
