#include "hal_host.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "hal_pico.h"
#include "spi_link.h"
#include "touch.h"

static touch_event_queue_t g_touchq;
static spi_link_t *g_link = NULL;

void hal_host_init(void) {
    touch_queue_init(&g_touchq);
    if (g_link) spi_link_free(g_link);
    g_link = spi_link_new_inproc();
}

void hal_host_push_touch(const touch_event_t *ev) {
    (void)touch_queue_push(&g_touchq, ev);
}

size_t hal_host_drain_spi(uint8_t *out, size_t cap) {
    if (!g_link) return 0;
    return spi_link_recv(g_link, out, cap);
}

// HAL implementations the firmware's ui_logic.c links against.

uint64_t hal_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

void hal_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

bool hal_touch_poll(touch_event_t *out) {
    return touch_queue_pop(&g_touchq, out);
}

void hal_spi_send(const uint8_t *buf, size_t len) {
    if (!g_link) return;
    spi_link_send(g_link, buf, len);
}

void hal_sleep_ms(uint32_t ms) {
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}
