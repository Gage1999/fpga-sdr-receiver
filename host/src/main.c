// Host harness — SDL window driving the in-process Pico+FPGA simulators.
//
// One window, 800x480 (or scaled), refreshed at ~60 Hz from the FPGA
// simulator's scan-out path. Mouse becomes touch. Keyboard shortcuts
// stand in for gestures during laptop development.

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fpga_sim.h"
#include "hal_host.h"
#include "input_map.h"
#include "pico_sim.h"
#include "screen_config.h"
#include "synth_data.h"
#include "touch.h"
#include "ui_state.h"

static SDL_Window   *g_window;
static SDL_Renderer *g_renderer;
static SDL_Texture  *g_texture;
static int           g_mouse_x, g_mouse_y;
static int           g_fullscreen;

static int sdl_init_window(int initial_scale) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return -1;
    }
    int w = SCREEN_W * initial_scale;
    int h = SCREEN_H * initial_scale;
    g_window = SDL_CreateWindow("fpga-sdr-receiver — host harness",
                                SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                w, h, SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE);
    if (!g_window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return -1; }

    g_renderer = SDL_CreateRenderer(g_window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!g_renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return -1; }
    SDL_RenderSetLogicalSize(g_renderer, SCREEN_W, SCREEN_H);

    g_texture = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_RGB565,
                                  SDL_TEXTUREACCESS_STREAMING, SCREEN_W, SCREEN_H);
    if (!g_texture) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return -1; }
    return 0;
}

// Map SDL window-space mouse coords to logical-screen coords.
static void window_to_logical(int wx, int wy, int *lx, int *ly) {
    int rw, rh;
    SDL_GetRendererOutputSize(g_renderer, &rw, &rh);
    float sx = (float)rw / (float)SCREEN_W;
    float sy = (float)rh / (float)SCREEN_H;
    float s  = sx < sy ? sx : sy;
    int dst_w = (int)((float)SCREEN_W * s);
    int dst_h = (int)((float)SCREEN_H * s);
    int ox = (rw - dst_w) / 2;
    int oy = (rh - dst_h) / 2;
    int dpi_w, dpi_h;
    SDL_GetWindowSize(g_window, &dpi_w, &dpi_h);
    int sx_to_render_x = (rw > 0 && dpi_w > 0) ? rw / dpi_w : 1;
    int sy_to_render_y = (rh > 0 && dpi_h > 0) ? rh / dpi_h : 1;
    int rx = wx * sx_to_render_x;
    int ry = wy * sy_to_render_y;
    int px = (int)((float)(rx - ox) / s);
    int py = (int)((float)(ry - oy) / s);
    if (px < 0) px = 0;
    if (px >= SCREEN_W) px = SCREEN_W - 1;
    if (py < 0) py = 0;
    if (py >= SCREEN_H) py = SCREEN_H - 1;
    *lx = px;
    *ly = py;
}

int main(int argc, char **argv) {
    int scale = 1;
    if (argc > 1) {
        int s = atoi(argv[1]);
        if (s >= 1 && s <= 4) scale = s;
    }

    if (sdl_init_window(scale) != 0) return 1;

    hal_host_init();
    synth_init(0xC0FFEE01u);

    pico_sim_t pico;
    pico_sim_init(&pico);

    fpga_sim_t fpga;
    fpga_sim_init(&fpga);

    uint16_t *pixels = (uint16_t *)malloc((size_t)SCREEN_W * SCREEN_H * sizeof(uint16_t));
    if (!pixels) { fprintf(stderr, "out of memory\n"); return 1; }

    int running = 1;
    Uint32 last_log = SDL_GetTicks();
    Uint32 frame_count = 0;

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) { running = 0; break; }
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) { running = 0; break; }
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_F11) {
                g_fullscreen = !g_fullscreen;
                SDL_SetWindowFullscreen(g_window, g_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
                continue;
            }
            if (e.type == SDL_MOUSEMOTION) {
                int lx, ly;
                window_to_logical(e.motion.x, e.motion.y, &lx, &ly);
                g_mouse_x = lx; g_mouse_y = ly;
                // Patch the motion event to logical coords before passing in.
                SDL_Event patched = e;
                patched.motion.x = lx; patched.motion.y = ly;
                touch_event_t tev;
                if (input_map_translate(&patched, lx, ly, &tev)) {
                    hal_host_push_touch(&tev);
                }
                continue;
            }
            if (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) {
                int lx, ly;
                window_to_logical(e.button.x, e.button.y, &lx, &ly);
                g_mouse_x = lx; g_mouse_y = ly;
                SDL_Event patched = e;
                patched.button.x = lx; patched.button.y = ly;
                touch_event_t tev;
                if (input_map_translate(&patched, lx, ly, &tev)) {
                    hal_host_push_touch(&tev);
                }
                continue;
            }

            touch_event_t tev;
            if (input_map_translate(&e, g_mouse_x, g_mouse_y, &tev)) {
                hal_host_push_touch(&tev);
            }
        }

        // Pico → FPGA: spectrum bins synthesized once per frame, pushed
        // through the Pico-side state.
        synth_spectrum_bins(pico.L.curr.spectrum_bins);
        if (pico.L.curr.demod == DEMOD_FM) {
            synth_rds_text(pico.L.curr.rds_text, (uint8_t)sizeof(pico.L.curr.rds_text));
        }
        pico_sim_tick(&pico);
        fpga_sim_tick(&fpga, pixels);

        SDL_UpdateTexture(g_texture, NULL, pixels, SCREEN_W * (int)sizeof(uint16_t));
        SDL_RenderClear(g_renderer);
        SDL_RenderCopy(g_renderer, g_texture, NULL, NULL);
        SDL_RenderPresent(g_renderer);

        frame_count++;
        Uint32 now = SDL_GetTicks();
        if (now - last_log > 2000) {
            float fps = (float)frame_count * 1000.0f / (float)(now - last_log);
            fprintf(stderr, "[harness] %.1f fps\n", (double)fps);
            last_log = now;
            frame_count = 0;
        }
    }

    free(pixels);
    SDL_DestroyTexture(g_texture);
    SDL_DestroyRenderer(g_renderer);
    SDL_DestroyWindow(g_window);
    SDL_Quit();
    return 0;
}
