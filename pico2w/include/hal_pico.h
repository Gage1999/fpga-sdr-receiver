#ifndef TRIAD_HAL_PICO_H
#define TRIAD_HAL_PICO_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "touch.h"

uint64_t hal_now_us(void);

void hal_log(const char *fmt, ...);

bool hal_touch_poll(touch_event_t *out);

void hal_spi_init(void);

// Buffered SPI write. The HAL queues the bytes and flushes them at its own pace.
void hal_spi_send(const uint8_t *buf, size_t len);

void hal_sleep_ms(uint32_t ms);

#endif
