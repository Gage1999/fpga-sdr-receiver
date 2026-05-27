#ifndef TRIAD_HAL_HOST_H
#define TRIAD_HAL_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "touch.h"

// Host wiring for the HAL the firmware/ui_logic.c expects.
// The host-side touch queue and SPI link are owned here.

void hal_host_init(void);

void hal_host_push_touch(const touch_event_t *ev);

// Drain SPI bytes that hal_spi_send queued. Returns bytes copied.
size_t hal_host_drain_spi(uint8_t *out, size_t cap);

#endif
