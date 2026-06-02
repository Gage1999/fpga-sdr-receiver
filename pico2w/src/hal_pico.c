#include "hal_pico.h"

// Pico SDK implementation of the HAL used by ui_logic.c.

#ifdef TRIAD_FIRMWARE
#include <stdarg.h>
#include <stdio.h>

#include "pico/stdlib.h"
#include "hardware/spi.h"

#include "touch_goodix.h"

#define UI_SPI          spi0
#define UI_SPI_BAUD     (8u * 1000u * 1000u)
#define UI_SPI_SCK_PIN  18u
#define UI_SPI_MOSI_PIN 19u
#define UI_SPI_CS_PIN   17u

uint64_t hal_now_us(void) {
    return to_us_since_boot(get_absolute_time());
}

void hal_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

bool hal_touch_poll(touch_event_t *out) {
    return touch_goodix_poll(out);
}

void hal_spi_init(void) {
    spi_init(UI_SPI, UI_SPI_BAUD);
    spi_set_format(UI_SPI, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);

    gpio_set_function(UI_SPI_SCK_PIN, GPIO_FUNC_SPI);
    gpio_set_function(UI_SPI_MOSI_PIN, GPIO_FUNC_SPI);

    gpio_init(UI_SPI_CS_PIN);
    gpio_set_dir(UI_SPI_CS_PIN, GPIO_OUT);
    gpio_put(UI_SPI_CS_PIN, 1);
}

void hal_spi_send(const uint8_t *buf, size_t len) {
    if (buf == NULL || len == 0u) return;

    gpio_put(UI_SPI_CS_PIN, 0);
    (void)spi_write_blocking(UI_SPI, buf, len);
    while (spi_is_busy(UI_SPI)) {
        tight_loop_contents();
    }
    gpio_put(UI_SPI_CS_PIN, 1);
}

void hal_sleep_ms(uint32_t ms) {
    sleep_ms(ms);
}
#endif
