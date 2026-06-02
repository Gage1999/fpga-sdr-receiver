// Goodix capacitive touch controller driver.
//
// Bring-up (2026-06-01) pinned down the part: Goodix GT911, 7-bit I²C
// address 0x5D, on i2c0 (SDA=GP4, SCL=GP5). Product-ID register 0x8140
// reads ASCII "911". The INT pin level when RST is released selects the
// address (low/floating -> 0x5D, high -> 0x14). The bring-up scanner lives
// in pico2w/src/i2c_touch_probe/.
//
// The GT911 reports up to 5 points. The UI currently consumes a single-touch
// stream, so this driver follows one primary contact ID and emits raw
// DOWN/MOVE/UP events. Gesture detection (tap/long/swipe) stays above this
// layer so the harness exercises the same gesture code paths.

#ifdef TRIAD_FIRMWARE
#include "touch_goodix.h"

#include <stddef.h>
#include <stdint.h>

#include "hardware/i2c.h"
#include "pico/stdlib.h"
#include "screen_config.h"
#include "touch.h"

#define GOODIX_I2C          i2c0
#define GOODIX_ADDR         0x5Du
#define GOODIX_I2C_SDA      4u
#define GOODIX_I2C_SCL      5u
#define GOODIX_I2C_BAUD     100000u
#define GOODIX_TIMEOUT_US   10000u
#define GOODIX_REPROBE_US   1000000ull

#define GOODIX_REG_PRODUCT_ID  0x8140u
#define GOODIX_REG_STATUS      0x814Eu
#define GOODIX_REG_POINT_DATA  0x8150u

#define GOODIX_STATUS_READY       0x80u
#define GOODIX_STATUS_TOUCH_MASK  0x0Fu
#define GOODIX_MAX_TOUCHES        5u
#define GOODIX_POINT_BYTES        8u

#ifndef GOODIX_SWAP_XY
#define GOODIX_SWAP_XY 0
#endif

#ifndef GOODIX_INVERT_X
#define GOODIX_INVERT_X 0
#endif

#ifndef GOODIX_INVERT_Y
#define GOODIX_INVERT_Y 0
#endif

typedef struct {
    uint8_t id;
    uint16_t x;
    uint16_t y;
} goodix_point_t;

static touch_event_queue_t g_events;
static bool g_initialized;
static bool g_present;
static bool g_primary_down;
static uint8_t g_primary_id;
static uint16_t g_last_x;
static uint16_t g_last_y;
static uint64_t g_next_probe_us;

static uint64_t goodix_now_us(void) {
    return to_us_since_boot(get_absolute_time());
}

static int goodix_read_reg(uint16_t reg, uint8_t *buf, size_t len) {
    uint8_t addr[2] = {
        (uint8_t)(reg >> 8),
        (uint8_t)(reg & 0xFFu),
    };
    int wr = i2c_write_timeout_us(GOODIX_I2C, (uint8_t)GOODIX_ADDR,
                                  addr, sizeof(addr), true, GOODIX_TIMEOUT_US);
    if (wr != (int)sizeof(addr)) return -1;
    return i2c_read_timeout_us(GOODIX_I2C, (uint8_t)GOODIX_ADDR,
                               buf, len, false, GOODIX_TIMEOUT_US);
}

static bool goodix_read_exact(uint16_t reg, uint8_t *buf, size_t len) {
    return goodix_read_reg(reg, buf, len) == (int)len;
}

static bool goodix_write_u8(uint16_t reg, uint8_t value) {
    uint8_t buf[3] = {
        (uint8_t)(reg >> 8),
        (uint8_t)(reg & 0xFFu),
        value,
    };
    int wr = i2c_write_timeout_us(GOODIX_I2C, (uint8_t)GOODIX_ADDR,
                                  buf, sizeof(buf), false, GOODIX_TIMEOUT_US);
    return wr == (int)sizeof(buf);
}

static uint16_t read_le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint16_t clamp_axis(uint16_t v, uint16_t dim) {
    if (v < dim) return v;
    return (uint16_t)(dim - 1u);
}

static void map_point(uint16_t raw_x, uint16_t raw_y, uint16_t *x, uint16_t *y) {
    uint16_t mx = raw_x;
    uint16_t my = raw_y;

#if GOODIX_SWAP_XY
    uint16_t tmp = mx;
    mx = my;
    my = tmp;
#endif

    mx = clamp_axis(mx, (uint16_t)SCREEN_W);
    my = clamp_axis(my, (uint16_t)SCREEN_H);

#if GOODIX_INVERT_X
    mx = (uint16_t)(((uint16_t)SCREEN_W - 1u) - mx);
#endif
#if GOODIX_INVERT_Y
    my = (uint16_t)(((uint16_t)SCREEN_H - 1u) - my);
#endif

    *x = mx;
    *y = my;
}

static goodix_point_t parse_point(const uint8_t *p) {
    goodix_point_t pt;
    pt.id = p[0];
    map_point(read_le16(p + 1), read_le16(p + 3), &pt.x, &pt.y);
    return pt;
}

static void queue_event(uint16_t x, uint16_t y, touch_kind_t kind) {
    touch_event_t ev = {
        .x = x,
        .y = y,
        .kind = kind,
        .reserved = 0,
    };
    (void)touch_queue_push(&g_events, &ev);
}

static bool find_primary(const uint8_t *points, uint8_t count, goodix_point_t *out) {
    for (uint8_t i = 0; i < count; i++) {
        goodix_point_t pt = parse_point(points + ((size_t)i * GOODIX_POINT_BYTES));
        if (pt.id == g_primary_id) {
            *out = pt;
            return true;
        }
    }
    return false;
}

static void handle_points(const uint8_t *points, uint8_t count) {
    if (count == 0u) {
        if (g_primary_down) {
            queue_event(g_last_x, g_last_y, TOUCH_UP);
            g_primary_down = false;
        }
        return;
    }

    if (!g_primary_down) {
        goodix_point_t pt = parse_point(points);
        g_primary_id = pt.id;
        g_last_x = pt.x;
        g_last_y = pt.y;
        g_primary_down = true;
        queue_event(pt.x, pt.y, TOUCH_DOWN);
        return;
    }

    goodix_point_t pt;
    if (!find_primary(points, count, &pt)) {
        queue_event(g_last_x, g_last_y, TOUCH_UP);
        g_primary_down = false;
        return;
    }

    if (pt.x != g_last_x || pt.y != g_last_y) {
        g_last_x = pt.x;
        g_last_y = pt.y;
        queue_event(pt.x, pt.y, TOUCH_MOVE);
    }
}

static bool product_id_matches_gt911(void) {
    uint8_t id[4] = {0};
    if (!goodix_read_exact(GOODIX_REG_PRODUCT_ID, id, sizeof(id))) return false;
    return id[0] == (uint8_t)'9' &&
           id[1] == (uint8_t)'1' &&
           id[2] == (uint8_t)'1';
}

static bool probe_if_needed(void) {
    if (g_present) return true;

    uint64_t now = goodix_now_us();
    if (now < g_next_probe_us) return false;

    g_next_probe_us = now + GOODIX_REPROBE_US;
    g_present = product_id_matches_gt911();
    if (g_present) {
        (void)goodix_write_u8(GOODIX_REG_STATUS, 0u);
    }
    return g_present;
}

static void poll_hardware_once(void) {
    uint8_t status = 0;
    if (!probe_if_needed()) return;
    if (!goodix_read_exact(GOODIX_REG_STATUS, &status, 1)) {
        g_present = false;
        g_next_probe_us = goodix_now_us() + GOODIX_REPROBE_US;
        return;
    }
    if ((status & GOODIX_STATUS_READY) == 0u) return;

    const uint8_t count = (uint8_t)(status & GOODIX_STATUS_TOUCH_MASK);
    uint8_t points[GOODIX_MAX_TOUCHES * GOODIX_POINT_BYTES];
    bool ok = count <= GOODIX_MAX_TOUCHES;
    if (ok && count > 0u) {
        ok = goodix_read_exact(GOODIX_REG_POINT_DATA, points,
                               (size_t)count * GOODIX_POINT_BYTES);
    }

    (void)goodix_write_u8(GOODIX_REG_STATUS, 0u);
    if (ok) handle_points(points, count);
}

void touch_goodix_init(void) {
    i2c_init(GOODIX_I2C, GOODIX_I2C_BAUD);
    gpio_set_function(GOODIX_I2C_SDA, GPIO_FUNC_I2C);
    gpio_set_function(GOODIX_I2C_SCL, GPIO_FUNC_I2C);
    gpio_pull_up(GOODIX_I2C_SDA);
    gpio_pull_up(GOODIX_I2C_SCL);

    sleep_ms(50);

    touch_queue_init(&g_events);
    g_primary_down = false;
    g_primary_id = 0;
    g_last_x = 0;
    g_last_y = 0;
    g_initialized = true;
    g_present = product_id_matches_gt911();
    g_next_probe_us = goodix_now_us() + GOODIX_REPROBE_US;
    if (g_present) {
        (void)goodix_write_u8(GOODIX_REG_STATUS, 0u);
    }
}

bool touch_goodix_poll(touch_event_t *out) {
    if (out == NULL) return false;
    if (!g_initialized) touch_goodix_init();

    if (touch_queue_pop(&g_events, out)) return true;
    poll_hardware_once();
    return touch_queue_pop(&g_events, out);
}
#endif
