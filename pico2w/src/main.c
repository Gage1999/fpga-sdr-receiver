// Pico firmware entry — STUB. Only built when BUILD_FIRMWARE=ON and
// PICO_SDK_PATH points at the Pico SDK.
//
// Real bring-up will: stdio_init_all, init SPI master on spi0, init I²C
// for the Goodix, then loop ui_logic_tick at 60 Hz.

#ifdef TRIAD_FIRMWARE
#include "pico/stdlib.h"
#include "hardware/spi.h"

#include "hal_pico.h"
#include "ui_logic.h"

int main(void) {
    stdio_init_all();
    spi_init(spi0, 8 * 1000 * 1000);  // 8 MHz; tune during bring-up

    ui_logic_t L;
    ui_logic_init(&L);

    const uint32_t tick_ms = 16;  // ~60 Hz
    absolute_time_t next = make_timeout_time_ms(tick_ms);
    while (true) {
        (void)ui_logic_tick(&L);
        sleep_until(next);
        next = delayed_by_ms(next, tick_ms);
    }
}
#endif
