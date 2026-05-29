#include "fpga_sim.h"

#include <string.h>

#include "fb_compositor.h"
#include "hal_host.h"
#include "palette.h"
#include "pixel_shader.h"
#include "synth_data.h"
#include "touch.h"
#include "wire_protocol.h"

#define DRAIN_BUF 4096
#define WIRE_RING 8192

static uint8_t g_ring[WIRE_RING];
static size_t  g_ring_len;
static touch_event_queue_t g_fpga_touchq;  // FPGA side observes touches too

static void wire_drain(fpga_sim_t *s) {
    uint8_t buf[DRAIN_BUF];
    size_t n;
    while ((n = hal_host_drain_spi(buf, sizeof(buf))) > 0) {
        if (g_ring_len + n > WIRE_RING) {
            // Drop incomplete frames on overrun; next OP_FULL_STATE will resync.
            g_ring_len = 0;
        }
        memcpy(g_ring + g_ring_len, buf, n);
        g_ring_len += n;
    }

    size_t cursor = 0;
    while (cursor < g_ring_len) {
        wire_result_t r = wire_consume(g_ring + cursor, g_ring_len - cursor,
                                       &s->shadow, &g_fpga_touchq);
        if (r.status == WIRE_INCOMPLETE) break;
        if (r.consumed == 0) { cursor++; continue; }  // safety
        cursor += r.consumed;
    }
    if (cursor > 0) {
        memmove(g_ring, g_ring + cursor, g_ring_len - cursor);
        g_ring_len -= cursor;
    }
}

void fpga_sim_init(fpga_sim_t *s) {
    fb_host_init(&s->fb, 0);
    ui_state_default(&s->shadow);
    ui_state_default(&s->shadow_front);
    aux_roms_default(&s->roms);
    s->last_layout = s->shadow_front.layout;
    s->goes_next_row = 0;
    g_ring_len = 0;
    touch_queue_init(&g_fpga_touchq);
}

void fpga_sim_tick(fpga_sim_t *s, uint16_t *pixels_out) {
    wire_drain(s);

    // Drop any touch events the FPGA observed — they were echoed only for
    // hardware-link parity. They don't drive anything inside the FPGA in the
    // current design.
    touch_event_t t;
    while (touch_queue_pop(&g_fpga_touchq, &t)) { (void)t; }

    // V-sync: flip the UI state shadow buffer (arch doc §8).
    s->shadow_front = s->shadow;

    // Mode change: the FB-backed regions (waterfall/GOES/ADS-B) read straight
    // from the framebuffer, so on a layout switch a region newly exposed in the
    // new mode would otherwise show leftover pixels from the old one. Clear both
    // planes to black so the new mode composites onto a clean surface.
    if (s->shadow_front.layout != s->last_layout) {
        fb_host_clear(&s->fb, 0);
        s->last_layout = s->shadow_front.layout;
        region_t goes_r = region_for_kind(R_GOES, s->shadow_front.layout);
        s->goes_next_row = (goes_r.kind == R_GOES)
                          ? synth_goes_row_index(goes_r.h)
                          : 0;
    }

    // Compositor side: synth_data is the stand-in for the Zynq DSP feed.
    uint8_t mags[800];
    synth_waterfall_row(mags);
    fb_compose_waterfall_step(&s->fb, s->shadow_front.layout, mags, palette_waterfall);

    uint8_t goes[800];
    if (synth_goes_row_ready(goes)) {
        // Satellite image lines arrive with image/frame position. Fill that
        // stream top-down and wrap after the frame; entering mid-frame starts at
        // the current source row instead of forcing the next line to row 0.
        region_t r = region_for_kind(R_GOES, s->shadow_front.layout);
        if (r.kind == R_GOES && r.h > 0) {
            fb_compose_goes_row(&s->fb, s->shadow_front.layout,
                                s->goes_next_row, goes, palette_goes);
            s->goes_next_row = (uint16_t)((s->goes_next_row + 1u) % r.h);
        }
    }
    if (s->shadow_front.layout == LAYOUT_GOES_FULL) {
        fb_compose_goes_panel(&s->fb, s->shadow_front.layout, s->goes_next_row, &s->roms);
    }

    // ADS-B map: the FPGA single-buffers this (slow update, no tearing risk),
    // but the host FB double-buffers and swaps every frame, so recompose each
    // frame to keep the active buffer populated. synth_adsb_dirty() drives the
    // ~2 Hz plane motion; positions are otherwise static.
    if (s->shadow_front.layout == LAYOUT_ADSB_FULL) {
        adsb_plane_t planes[ADSB_MAX_PLANES];
        uint8_t np = synth_adsb_planes(planes, ADSB_MAX_PLANES);
        (void)synth_adsb_dirty();
        fb_compose_adsb_frame(&s->fb, s->shadow_front.layout, planes, np,
                              s->shadow_front.adsb_range_mi, &s->roms);
    }

    // Scan-out: render the full screen via the pixel shader. Prepare runs
    // once per V-sync; on hardware this is the SV `shader_state` snapshot.
    shader_state_t shader_st;
    pixel_shader_prepare(&s->shadow_front, &s->roms, &shader_st);
    for (uint16_t y = 0; y < SCREEN_H; y++) {
        for (uint16_t x = 0; x < SCREEN_W; x++) {
            uint16_t under = fb_read(&s->fb, x, y);
            pixels_out[(size_t)y * SCREEN_W + x] =
                pixel_shader(x, y, under, &shader_st, &s->roms);
        }
    }

    fb_swap(&s->fb);
}
