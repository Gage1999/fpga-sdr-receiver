#include "input_map.h"

#include "screen_config.h"
#include "ui_controls.h"
#include "ui_state.h"

bool input_map_translate(const SDL_Event *e,
                         int mouse_x, int mouse_y,
                         uint8_t layout,
                         touch_event_t *ev) {
    switch (e->type) {
    case SDL_MOUSEBUTTONDOWN:
        if (e->button.button == SDL_BUTTON_LEFT) {
            ev->x = (uint16_t)e->button.x;
            ev->y = (uint16_t)e->button.y;
            ev->kind = TOUCH_DOWN;
            return true;
        }
        break;
    case SDL_MOUSEMOTION:
        if (e->motion.state & SDL_BUTTON_LMASK) {
            ev->x = (uint16_t)e->motion.x;
            ev->y = (uint16_t)e->motion.y;
            ev->kind = TOUCH_MOVE;
            return true;
        }
        break;
    case SDL_MOUSEBUTTONUP:
        if (e->button.button == SDL_BUTTON_LEFT) {
            ev->x = (uint16_t)e->button.x;
            ev->y = (uint16_t)e->button.y;
            ev->kind = TOUCH_UP;
            return true;
        }
        break;
    case SDL_KEYDOWN: {
        SDL_Keycode k = e->key.keysym.sym;
        ev->reserved = 0;
        switch (k) {
        case SDLK_LEFT:
            ev->x = SCREEN_W / 2; ev->y = 100; ev->kind = TOUCH_SWIPE_L; return true;
        case SDLK_RIGHT:
            ev->x = SCREEN_W / 2; ev->y = 100; ev->kind = TOUCH_SWIPE_R; return true;
        case SDLK_UP:
            if (layout != (uint8_t)LAYOUT_SPECTRUM_ONLY) return false;
            ev->x = ui_button_cx(UI_BTN_FREQ_UP); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        case SDLK_DOWN:
            if (layout != (uint8_t)LAYOUT_SPECTRUM_ONLY) return false;
            ev->x = ui_button_cx(UI_BTN_FREQ_DN); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        case SDLK_m:
            if (layout != (uint8_t)LAYOUT_SPECTRUM_ONLY) return false;
            ev->x = ui_button_cx(UI_BTN_MUTE); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        case SDLK_EQUALS:
        case SDLK_PLUS:
            if (layout != (uint8_t)LAYOUT_ADSB_FULL) return false;
            ev->x = ui_button_cx(UI_BTN_ZOOM_IN); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        case SDLK_MINUS:
            if (layout != (uint8_t)LAYOUT_ADSB_FULL) return false;
            ev->x = ui_button_cx(UI_BTN_ZOOM_OUT); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        case SDLK_l:
            ev->x = (uint16_t)mouse_x; ev->y = (uint16_t)mouse_y; ev->kind = TOUCH_LONG; return true;
        case SDLK_SPACE:
            ev->x = (uint16_t)mouse_x; ev->y = (uint16_t)mouse_y; ev->kind = TOUCH_TAP; return true;
        case SDLK_1:
        case SDLK_2:
        case SDLK_3:
        case SDLK_4:
            // Tap the mode button (cycles FM / AM / GOES / ADS-B; page follows);
            // caller decides how many taps to send.
            ev->x = ui_button_cx(UI_BTN_MODE); ev->y = ui_button_cy(); ev->kind = TOUCH_TAP; return true;
        default: break;
        }
        break;
    }
    default: break;
    }
    return false;
}
