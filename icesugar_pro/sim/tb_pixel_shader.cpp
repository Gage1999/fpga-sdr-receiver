// Verilator parity harness for icesugar_pro/sim/pixel_shader.sv.
//
// Drives the C reference model and the SV `pixel_shader` with identical
// per-pixel inputs and reports byte-equality stats. Until every shade_* is
// translated, mismatches outside the implemented regions are expected.
//
// Test cases mirror tests/test_pixel_shader.c — same ui_state setups, same
// FB fills — so progress here tracks the host-side golden tests.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>

#include "Vpixel_shader.h"
#include "verilated.h"

extern "C" {
#include "aux_roms.h"
#include "pixel_shader.h"
#include "screen_config.h"
#include "ui_state.h"
}

namespace {

struct Result {
    size_t   total;
    size_t   matched;
    bool     have_mismatch;
    uint16_t first_x;
    uint16_t first_y;
    uint16_t first_c;
    uint16_t first_sv;
};

void drive_state(Vpixel_shader *dut, const shader_state_t *st) {
    dut->layout        = st->layout;
    dut->demod         = st->demod;
    dut->flags         = st->flags;
    dut->active_button = st->active_button;
    dut->touch_x       = st->touch_x;
    dut->touch_y       = st->touch_y;

    // Wide packed buses — Verilator's VlWide is uint32_t[]; memcpy works on
    // little-endian hosts (macOS/arm64 here) because bit 0 of the SV port
    // corresponds to byte 0's LSB.
    std::memcpy(&dut->freq_text,      st->freq_text,      sizeof(st->freq_text));
    std::memcpy(&dut->demod_label,    st->demod_label,    sizeof(st->demod_label));
    std::memcpy(&dut->rds_line,       st->rds_line,       sizeof(st->rds_line));
    std::memcpy(&dut->mode_btn_label, st->mode_btn_label, sizeof(st->mode_btn_label));

    dut->mode_btn_text_x = static_cast<uint16_t>(st->mode_btn_text_x);
    dut->mode_btn_text_y = static_cast<uint16_t>(st->mode_btn_text_y);
    dut->plus_text_x     = static_cast<uint16_t>(st->plus_text_x);
    dut->plus_text_y     = static_cast<uint16_t>(st->plus_text_y);
    dut->minus_text_x    = static_cast<uint16_t>(st->minus_text_x);
    dut->minus_text_y    = static_cast<uint16_t>(st->minus_text_y);

    dut->volume_fill_px  = st->volume_fill_px;
    dut->mute_sprite_id  = st->mute_sprite_id;
}

Result run_case(const char *name, const ui_state_t *ui, uint16_t fb_fill) {
    aux_roms_t roms;
    aux_roms_default(&roms);

    shader_state_t st;
    pixel_shader_prepare(ui, &roms, &st);

    Vpixel_shader *dut = new Vpixel_shader;
    drive_state(dut, &st);
    dut->fb_under = fb_fill;

    Result r = {
        static_cast<size_t>(SCREEN_W) * static_cast<size_t>(SCREEN_H),
        0, false, 0, 0, 0, 0,
    };

    for (uint16_t y = 0; y < SCREEN_H; y++) {
        for (uint16_t x = 0; x < SCREEN_W; x++) {
            dut->x = x;
            dut->y = y;
            // First eval propagates region/spectrum logic so spectrum_bin_addr
            // settles. We then back the BRAM port with the matching C table
            // entry — this mirrors how the real BRAM port responds on the
            // following cycle. A second eval finalizes the pixel value.
            dut->eval();
            dut->spectrum_bin_data = st.spectrum_bins[dut->spectrum_bin_addr];
            dut->font16_data       = roms.font_16x32[dut->font16_addr];
            dut->sprite_data       = roms.sprites[dut->sprite_addr];
            dut->eval();

            uint16_t sv_px = dut->pixel;
            uint16_t c_px  = pixel_shader(x, y, fb_fill, &st, &roms);

            if (sv_px == c_px) {
                r.matched++;
            } else if (!r.have_mismatch) {
                r.have_mismatch = true;
                r.first_x = x;
                r.first_y = y;
                r.first_c = c_px;
                r.first_sv = sv_px;
            }
        }
    }

    delete dut;

    double pct = 100.0 * static_cast<double>(r.matched) / static_cast<double>(r.total);
    std::printf("[%-22s] matched %7zu / %zu  (%6.2f%%)\n",
                name, r.matched, r.total, pct);
    if (r.have_mismatch) {
        std::printf("  first mismatch at (%4u, %4u):  C=0x%04x  SV=0x%04x\n",
                    r.first_x, r.first_y, r.first_c, r.first_sv);
    }
    return r;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    size_t total_pix = 0;
    size_t total_match = 0;

    {
        ui_state_t ui; ui_state_default(&ui);
        Result r = run_case("default_state", &ui, RGB565(8, 12, 18));
        total_pix   += r.total;
        total_match += r.matched;
    }
    {
        // Mirrors test_pixel_shader.c's spectrum_with_bars: triangle wave
        // across the 256 bins so the spectrum region renders varied bar
        // heights — exercises the bin BRAM port across most of its range.
        ui_state_t ui; ui_state_default(&ui);
        for (int i = 0; i < UI_SPECTRUM_BINS; i++) {
            uint16_t v = (uint16_t)(((i < 128 ? i : 255 - i) * 65535) / 128);
            ui.spectrum_bins[i] = v;
        }
        Result r = run_case("spectrum_triangle", &ui, 0);
        total_pix   += r.total;
        total_match += r.matched;
    }
    {
        ui_state_t ui; ui_state_default(&ui);
        ui.flags |= UI_FLAG_TOUCH_ACTIVE;
        ui.touch_x = 400;
        ui.touch_y = 250;
        Result r = run_case("touch_overlay", &ui, RGB565(20, 20, 30));
        total_pix   += r.total;
        total_match += r.matched;
    }
    {
        ui_state_t ui; ui_state_default(&ui);
        ui.flags |= UI_FLAG_MUTE;
        ui.active_button = UI_BTN_MUTE;
        Result r = run_case("mute_active", &ui, 0);
        total_pix   += r.total;
        total_match += r.matched;
    }
    {
        // GOES image layout: full-screen FB pass-through plus a floating MODE
        // button. Surfaces the still-stubbed shade_image_mode_button path.
        ui_state_t ui; ui_state_default(&ui);
        ui.demod  = DEMOD_GOES;
        ui.layout = LAYOUT_GOES_FULL;
        Result r = run_case("goes_layout", &ui, RGB565(8, 12, 18));
        total_pix   += r.total;
        total_match += r.matched;
    }
    {
        // ADS-B image layout: floating MODE + ZOOM_IN + ZOOM_OUT buttons. Same
        // story — full match outside the buttons; SV will be wrong inside them
        // until shade_image_mode_button lands.
        ui_state_t ui; ui_state_default(&ui);
        ui.demod        = DEMOD_ADSB;
        ui.layout       = LAYOUT_ADSB_FULL;
        ui.adsb_range_mi = 75;
        Result r = run_case("adsb_layout", &ui, RGB565(8, 12, 18));
        total_pix   += r.total;
        total_match += r.matched;
    }

    double pct = 100.0 * static_cast<double>(total_match) / static_cast<double>(total_pix);
    std::printf("\noverall: %zu / %zu (%6.2f%%)\n", total_match, total_pix, pct);

    // Harness exits 0 even on mismatches — we want CI/dev iteration to print
    // the percentage and keep going. Wire a strict-mode flag later.
    return 0;
}
