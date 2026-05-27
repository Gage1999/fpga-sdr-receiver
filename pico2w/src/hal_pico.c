#include "hal_pico.h"

// STUB — to be filled in during Pico bring-up. Compiles only under the
// firmware/ CMakeLists when PICO_SDK_PATH is set. Real implementations
// will use pico/stdlib, hardware/spi, hardware/i2c, etc.

#ifdef TRIAD_FIRMWARE
#include "pico/stdlib.h"
#include "hardware/spi.h"

uint64_t hal_now_us(void) {
    return to_us_since_boot(get_absolute_time());
}

void hal_log(const char *fmt, ...) {
    (void)fmt;
    // TODO: forward to UART. printf via stdio_init_all would work too.
}

bool hal_touch_poll(touch_event_t *out) {
    // TODO: implemented in touch_goodix.c via I²C.
    (void)out;
    return false;
}

void hal_spi_send(const uint8_t *buf, size_t len) {
    spi_write_blocking(spi0, buf, len);
}

void hal_sleep_ms(uint32_t ms) {
    sleep_ms(ms);
}
#endif
