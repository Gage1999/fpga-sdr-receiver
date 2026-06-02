// End-to-end parity harness for pixel_shader_top.sv — the synthesizable wrapper
// (shader core + font_16x32_rom + sprite_rom + spectrum_bin_ram).
//
// Unlike tb_pixel_shader.cpp (which backs the shader's ROM ports with C arrays),
// this drives the *whole block*: the ROMs read from the build/*.mem files and
// the spectrum bins are written in through the clocked write port, exactly as
// the Pico/ingest path will on hardware. A 100% match here proves the shader
// transition is complete end-to-end: real memories + real shader == C spec.
//
// Same 6 cases / FB fills as tb_pixel_shader.cpp.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>

#include "Vpixel_shader_top.h"
#include "verilated.h"

extern "C" {
#include "aux_roms.h"
#include "pixel_shader.h"
#include "screen_config.h"
#include "ui_state.h"
}

namespace {

struct Result { size_t total, matched; bool mm; uint16_t fx, fy, fc, fsv; };

void drive_state(Vpixel_shader_top *dut, const shader_state_t *st) {
    dut->layout        = st->layout;
    dut->demod         = st->demod;
    dut->flags         = st->flags;
    dut->active_button = st->active_button;
    dut->touch_x       = st->touch_x;
    dut->touch_y       = st->touch_y;

    std::memcpy(&dut->freq_text,      st->freq_text,      sizeof(st->freq_text));
    std::memcpy(&dut->band_text,      st->band_text,      sizeof(st->band_text));
    std::memcpy(&dut->demod_label,    st->demod_label,    sizeof(st->demod_label));
    std::memcpy(&dut->rds_line,       st->rds_line,       sizeof(st->rds_line));
    std::memcpy(&dut->mode_btn_label, st->mode_btn_label, sizeof(st->mode_btn_label));

    dut->mode_btn_text_x = (uint16_t)st->mode_btn_text_x;
    dut->mode_btn_text_y = (uint16_t)st->mode_btn_text_y;
    dut->plus_text_x     = (uint16_t)st->plus_text_x;
    dut->plus_text_y     = (uint16_t)st->plus_text_y;
    dut->minus_text_x    = (uint16_t)st->minus_text_x;
    dut->minus_text_y    = (uint16_t)st->minus_text_y;

    dut->volume_fill_px  = st->volume_fill_px;
    dut->mute_sprite_id  = st->mute_sprite_id;
    dut->spectrum_start_bin = st->spectrum_start_bin;
    dut->spectrum_visible_bins = st->spectrum_visible_bins;
}

// Clock the 256 magnitude bins into spectrum_bin_ram via the write port.
void load_spectrum(Vpixel_shader_top *dut, const shader_state_t *st) {
    dut->spec_wr_en = 1;
    for (int i = 0; i < UI_SPECTRUM_BINS; i++) {
        dut->spec_wr_addr = (uint8_t)i;
        dut->spec_wr_data = st->spectrum_bins[i];
        dut->spec_wr_clk = 0; dut->eval();
        dut->spec_wr_clk = 1; dut->eval();
    }
    dut->spec_wr_en = 0;
    dut->spec_wr_clk = 0; dut->eval();
}

Result run_case(const char *name, const ui_state_t *ui, uint16_t fb_fill) {
    aux_roms_t roms; aux_roms_default(&roms);
    shader_state_t st;
    pixel_shader_prepare(ui, &roms, &st);

    Vpixel_shader_top *dut = new Vpixel_shader_top;
    drive_state(dut, &st);
    dut->fb_under = fb_fill;
    load_spectrum(dut, &st);

    Result r = { (size_t)SCREEN_W * SCREEN_H, 0, false, 0, 0, 0, 0 };

    for (uint16_t y = 0; y < SCREEN_H; y++) {
        for (uint16_t x = 0; x < SCREEN_W; x++) {
            dut->x = x;
            dut->y = y;
            dut->eval();   // ROMs are combinational inside the DUT: settles in one eval
            uint16_t sv = dut->pixel;
            uint16_t c  = pixel_shader(x, y, fb_fill, &st, &roms);
            if (sv == c) r.matched++;
            else if (!r.mm) { r.mm = true; r.fx = x; r.fy = y; r.fc = c; r.fsv = sv; }
        }
    }
    delete dut;

    double pct = 100.0 * (double)r.matched / (double)r.total;
    std::printf("[%-22s] matched %7zu / %zu  (%6.2f%%)\n", name, r.matched, r.total, pct);
    if (r.mm) std::printf("  first mismatch at (%4u,%4u): C=0x%04x SV=0x%04x\n",
                          r.fx, r.fy, r.fc, r.fsv);
    return r;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    size_t tot = 0, match = 0;

    { ui_state_t ui; ui_state_default(&ui);
      Result r = run_case("default_state", &ui, RGB565(8, 12, 18));
      tot += r.total; match += r.matched; }

    { ui_state_t ui; ui_state_default(&ui);
      for (int i = 0; i < UI_SPECTRUM_BINS; i++)
          ui.spectrum_bins[i] = (uint16_t)(((i < 128 ? i : 255 - i) * 65535) / 128);
      Result r = run_case("spectrum_triangle", &ui, 0);
      tot += r.total; match += r.matched; }

    { ui_state_t ui; ui_state_default(&ui);
      ui.flags |= UI_FLAG_TOUCH_ACTIVE; ui.touch_x = 400; ui.touch_y = 250;
      Result r = run_case("touch_overlay", &ui, RGB565(20, 20, 30));
      tot += r.total; match += r.matched; }

    { ui_state_t ui; ui_state_default(&ui);
      ui.flags |= UI_FLAG_MUTE; ui.active_button = UI_BTN_MUTE;
      Result r = run_case("mute_active", &ui, 0);
      tot += r.total; match += r.matched; }

    { ui_state_t ui; ui_state_default(&ui);
      ui.demod = DEMOD_GOES; ui.layout = LAYOUT_GOES_FULL;
      Result r = run_case("goes_layout", &ui, RGB565(8, 12, 18));
      tot += r.total; match += r.matched; }

    { ui_state_t ui; ui_state_default(&ui);
      ui.demod = DEMOD_ADSB; ui.layout = LAYOUT_ADSB_FULL; ui.adsb_range_mi = 75;
      Result r = run_case("adsb_layout", &ui, RGB565(8, 12, 18));
      tot += r.total; match += r.matched; }

    double pct = 100.0 * (double)match / (double)tot;
    std::printf("\noverall: %zu / %zu (%6.2f%%)\n", match, tot, pct);
    return (match == tot) ? 0 : 1;
}
