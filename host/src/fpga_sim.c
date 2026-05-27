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

    // Compositor side: synth_data is the stand-in for the Zynq DSP feed.
    uint8_t mags[800];
    synth_waterfall_row(mags);
    fb_compose_waterfall_step(&s->fb, s->shadow_front.layout, mags, palette_waterfall);

    uint8_t goes[800];
    if (synth_goes_row_ready(goes)) {
        // Append at bottom of GOES region by scrolling the existing rows up.
        // Cheap host approximation: write at row_y = region.h - 1; emulator
        // doesn't model the scroll-pointer scheme, just like waterfall — see
        // the FPGA-side note in fb_compositor.c.
        region_t r = region_for_kind(R_GOES, s->shadow_front.layout);
        if (r.kind == R_GOES && r.h > 0) {
            for (uint16_t y = (uint16_t)(r.y0 + 1); y < r.y0 + r.h; y++) {
                for (uint16_t x = r.x0; x < r.x0 + r.w; x++) {
                    fb_write(&s->fb, x, (uint16_t)(y - 1), fb_read(&s->fb, x, y));
                }
            }
            fb_compose_goes_row(&s->fb, s->shadow_front.layout,
                               (uint16_t)(r.h - 1), goes, palette_goes);
        }
    }

    // ADS-B map: the FPGA single-buffers this (slow update, no tearing risk),
    // but the host FB double-buffers and swaps every frame, so recompose each
    // frame to keep the active buffer populated. synth_adsb_dirty() drives the
    // ~2 Hz plane motion; positions are otherwise static.
    if (s->shadow_front.layout == LAYOUT_ADSB_FULL) {
        adsb_plane_t planes[ADSB_MAX_PLANES];
        uint8_t np = synth_adsb_planes(planes, ADSB_MAX_PLANES);
        (void)synth_adsb_dirty();
        fb_compose_adsb_frame(&s->fb, s->shadow_front.layout, planes, np, &s->roms);
    }

    // Scan-out: render the full screen via the pixel shader.
    for (uint16_t y = 0; y < SCREEN_H; y++) {
        for (uint16_t x = 0; x < SCREEN_W; x++) {
            uint16_t under = fb_read(&s->fb, x, y);
            pixels_out[(size_t)y * SCREEN_W + x] =
                pixel_shader(x, y, under, &s->shadow_front, &s->roms);
        }
    }

    fb_swap(&s->fb);
}
