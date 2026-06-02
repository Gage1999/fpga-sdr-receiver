// I2C touch-controller identifier for Raspberry Pi Pico 2 W (RP2350).
//
// Bring-up tool, not part of the pico_firmware build. Scans i2c0 for
// devices, then for any address matching a known touch-controller family
// it reads the chip's ID registers to pin down the exact part. Output goes
// over USB serial; rescans every 3 s so you can open the monitor at any
// time (and wiggle wires to debug contacts).
//
// Result on this board (2026-06-01): Goodix GT911 at 7-bit I2C address
// 0x5D (product-ID register 0x8140 reads ASCII "911"). Kept here as a
// reusable diagnostic for the next panel / wiring change.
//
// Build/flash: see README.md in this directory.

#include <stdio.h>
#include <ctype.h>
#include "pico/stdlib.h"
#include "hardware/i2c.h"

#define I2C_PORT    i2c0
#define I2C_SDA     4        // GP4  = physical pin 6   (I2C0 SDA)
#define I2C_SCL     5        // GP5  = physical pin 7   (I2C0 SCL)
#define I2C_BAUD    100000   // 100 kHz: safe with weak/internal pull-ups
#define TIMEOUT_US  10000    // per-transfer timeout so a stuck line can't hang us

#define PRC(c) (isprint(c) ? (char)(c) : '.')

#define GOODIX_ADDR_PRIMARY   0x5D
#define GOODIX_ADDR_ALT       0x14
#define GOODIX_REG_PRODUCT_ID 0x8140
#define GOODIX_REG_STATUS     0x814E
#define GOODIX_REG_POINT_DATA 0x814F
#define GOODIX_STATUS_READY   0x80
#define GOODIX_STATUS_COUNT   0x0F
#define GOODIX_POINT_BYTES    8
#define GOODIX_MAX_POINTS     5

// --- I2C helpers (all time-bounded so bad wiring can't lock the bus) ---

// Probe one address with a 1-byte read; true if the device ACKs.
static bool addr_present(uint8_t addr) {
    uint8_t b;
    return i2c_read_timeout_us(I2C_PORT, addr, &b, 1, false, TIMEOUT_US) >= 0;
}

// Read `len` bytes from an 8-bit register. Returns bytes read, or <0 on error.
static int read_reg8(uint8_t addr, uint8_t reg, uint8_t *buf, size_t len) {
    int w = i2c_write_timeout_us(I2C_PORT, addr, &reg, 1, true, TIMEOUT_US);
    if (w < 0) return w;
    return i2c_read_timeout_us(I2C_PORT, addr, buf, len, false, TIMEOUT_US);
}

// Read `len` bytes from a 16-bit big-endian register (Goodix-style addressing).
static int read_reg16(uint8_t addr, uint16_t reg, uint8_t *buf, size_t len) {
    uint8_t r[2] = { (uint8_t)(reg >> 8), (uint8_t)(reg & 0xFF) };
    int w = i2c_write_timeout_us(I2C_PORT, addr, r, 2, true, TIMEOUT_US);
    if (w < 0) return w;
    return i2c_read_timeout_us(I2C_PORT, addr, buf, len, false, TIMEOUT_US);
}

static int write_reg16_u8(uint8_t addr, uint16_t reg, uint8_t value) {
    uint8_t b[3] = { (uint8_t)(reg >> 8), (uint8_t)(reg & 0xFF), value };
    return i2c_write_timeout_us(I2C_PORT, addr, b, sizeof(b), false, TIMEOUT_US);
}

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

// --- per-family identification ---

static void id_focaltech(uint8_t addr) {
    uint8_t vend = 0, chip = 0, fw = 0;
    read_reg8(addr, 0xA8, &vend, 1);   // vendor ID, expect 0x11
    read_reg8(addr, 0xA3, &chip, 1);   // chip ID
    read_reg8(addr, 0xA6, &fw, 1);     // firmware version
    const char *name = "FocalTech FT5x06/FT6x06 (unknown variant)";
    if (vend == 0x11) {
        switch (chip) {
            case 0x06: name = "FocalTech FT6206"; break;
            case 0x36: name = "FocalTech FT6236"; break;
            case 0x64: name = "FocalTech FT6236U / FT6336U"; break;
            case 0x55: name = "FocalTech FT5x06"; break;
            case 0x79: name = "FocalTech FT5336"; break;
            case 0x33: name = "FocalTech FT3267"; break;
            default:   name = "FocalTech (vendor OK, unmapped chip ID)"; break;
        }
    }
    printf("FocalTech family  vend=0x%02X chip=0x%02X fw=0x%02X  -> %s\n",
           vend, chip, fw, name);
}

static void id_goodix(uint8_t addr) {
    uint8_t id[4] = {0};
    if (read_reg16(addr, 0x8140, id, 4) >= 0) {     // product ID, ASCII
        uint8_t cfg = 0;
        read_reg16(addr, 0x8047, &cfg, 1);          // config version
        printf("Goodix GTxxx  product ID = \"%c%c%c%c\" (%02X %02X %02X %02X) cfg=0x%02X\n",
               PRC(id[0]), PRC(id[1]), PRC(id[2]), PRC(id[3]),
               id[0], id[1], id[2], id[3], cfg);
    } else {
        printf("address matches Goodix GT911, but 16-bit register read failed\n"
               "      (GT911 needs its RST released; the INT level at reset also\n"
               "       picks 0x5D vs 0x14)\n");
    }
}

static void id_hynitron(uint8_t addr) {
    uint8_t chip = 0, fw = 0;
    read_reg8(addr, 0xA7, &chip, 1);   // chip ID
    read_reg8(addr, 0xA9, &fw, 1);     // firmware version
    const char *name = "Hynitron CST8xx (unmapped chip ID)";
    switch (chip) {
        case 0xB4: name = "Hynitron CST816S"; break;
        case 0xB5: name = "Hynitron CST816T"; break;
        case 0xB6: name = "Hynitron CST816D"; break;
        case 0x20: name = "Hynitron CST716";  break;
    }
    printf("Hynitron family  chipID=0x%02X fw=0x%02X  -> %s\n", chip, fw, name);
}

static void identify(uint8_t addr) {
    printf("  0x%02X: ", addr);
    switch (addr) {
        case 0x38:                 id_focaltech(addr); break;   // FT5x06/FT6x06
        case 0x5D: case 0x14:      id_goodix(addr);    break;   // GT911/GT9xx
        case 0x15:                 id_hynitron(addr);  break;   // CST816 family
        case 0x4D:
            printf("possible Microchip AR1021/AR1100 resistive controller\n");
            break;
        case 0x48: case 0x49: case 0x4A: case 0x4B:
            printf("could be resistive touch (TSC2007/NS2009) or an ADC "
                   "(ADS1115) - inconclusive\n");
            break;
        default:
            printf("device present, not a touch controller I recognize\n");
            break;
    }
}

static void scan_and_identify(void) {
    printf("     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f\n");
    uint8_t found[16];
    int n = 0;
    for (int addr = 0; addr < 0x80; addr++) {
        if (addr % 16 == 0) printf("%02x ", addr);
        bool reserved = (addr & 0x78) == 0 || (addr & 0x78) == 0x78;
        bool ack = !reserved && addr_present(addr);
        printf("%s", ack ? "@  " : (reserved ? ".  " : "-  "));
        if (ack && n < (int)sizeof(found)) found[n++] = addr;
        if (addr % 16 == 15) printf("\n");
    }
    printf("\n%d device(s) responding.\n", n);
    for (int i = 0; i < n; i++) identify(found[i]);
}

static int detect_goodix_addr(void) {
    uint8_t id[4] = {0};
    if (read_reg16(GOODIX_ADDR_PRIMARY, GOODIX_REG_PRODUCT_ID, id, sizeof(id)) >= 0)
        return GOODIX_ADDR_PRIMARY;
    if (read_reg16(GOODIX_ADDR_ALT, GOODIX_REG_PRODUCT_ID, id, sizeof(id)) >= 0)
        return GOODIX_ADDR_ALT;
    return -1;
}

static void poll_goodix_touch(uint8_t addr) {
    static uint8_t last_status = 0;
    static uint32_t idle_print_div = 0;

    uint8_t status = 0;
    int r = read_reg16(addr, GOODIX_REG_STATUS, &status, 1);
    if (r != 1) {
        printf("GT911 0x%02X: status read failed (%d)\n", addr, r);
        sleep_ms(250);
        return;
    }

    bool ready = (status & GOODIX_STATUS_READY) != 0;
    uint8_t count = status & GOODIX_STATUS_COUNT;

    if (!ready) {
        if (status != last_status || (++idle_print_div % 20u) == 0u) {
            printf("GT911 0x%02X: idle status=0x%02X\n", addr, status);
        }
        last_status = status;
        return;
    }

    printf("GT911 0x%02X: READY status=0x%02X count=%u", addr, status, count);

    if (count > GOODIX_MAX_POINTS) {
        printf("  invalid count, clearing\n");
        (void)write_reg16_u8(addr, GOODIX_REG_STATUS, 0);
        return;
    }

    if (count == 0) {
        printf("  no contacts\n");
        (void)write_reg16_u8(addr, GOODIX_REG_STATUS, 0);
        return;
    }

    uint8_t pts[GOODIX_MAX_POINTS * GOODIX_POINT_BYTES] = {0};
    r = read_reg16(addr, GOODIX_REG_POINT_DATA, pts, (size_t)count * GOODIX_POINT_BYTES);
    if (r != (int)((size_t)count * GOODIX_POINT_BYTES)) {
        printf("  point read failed (%d)\n", r);
        (void)write_reg16_u8(addr, GOODIX_REG_STATUS, 0);
        return;
    }

    printf("\n");
    for (uint8_t i = 0; i < count; i++) {
        const uint8_t *p = pts + ((size_t)i * GOODIX_POINT_BYTES);
        uint8_t id = p[0];
        uint16_t x = le16(p + 1);
        uint16_t y = le16(p + 3);
        uint16_t size = le16(p + 5);
        printf("  point[%u]: id=%u x=%u y=%u size=%u raw=%02X %02X %02X %02X %02X %02X %02X %02X\n",
               i, id, x, y, size, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    }

    if (write_reg16_u8(addr, GOODIX_REG_STATUS, 0) != 3) {
        printf("  warning: failed to clear status register\n");
    }
    last_status = status;
}

int main(void) {
    stdio_init_all();

    i2c_init(I2C_PORT, I2C_BAUD);
    gpio_set_function(I2C_SDA, GPIO_FUNC_I2C);
    gpio_set_function(I2C_SCL, GPIO_FUNC_I2C);
    gpio_pull_up(I2C_SDA);   // weak internal pull-ups (~50-80k); see notes re: 4.7k
    gpio_pull_up(I2C_SCL);

    // Wait up to ~5 s for a serial monitor, but don't block forever.
    for (int i = 0; i < 100 && !stdio_usb_connected(); i++) sleep_ms(50);

    int iter = 0;
    int goodix_addr = -1;
    while (true) {
        if (iter == 0 || (iter % 30) == 0) {
            printf("\n===== I2C scan #%d  (i2c0  SDA=GP%d  SCL=GP%d  @ %d Hz) =====\n",
                   (iter / 30) + 1, I2C_SDA, I2C_SCL, I2C_BAUD);
            scan_and_identify();
            goodix_addr = detect_goodix_addr();
            if (goodix_addr >= 0) {
                printf("Entering GT911 touch poll at 0x%02X. Touch the panel; raw points print below.\n",
                       goodix_addr);
                (void)write_reg16_u8((uint8_t)goodix_addr, GOODIX_REG_STATUS, 0);
            } else {
                printf("No Goodix product ID found at 0x5D or 0x14 yet.\n");
            }
        }

        if (goodix_addr >= 0) {
            poll_goodix_touch((uint8_t)goodix_addr);
        }

        iter++;
        sleep_ms(100);
    }
}
