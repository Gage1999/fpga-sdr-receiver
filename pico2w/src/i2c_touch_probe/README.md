# i2c_touch_probe — touch-controller bring-up tool

Standalone Pico 2 W firmware that scans **i2c0** and identifies the touch
controller by reading its ID registers. Used during bring-up to pin down the
panel before writing the real driver (`../touch_goodix.c`).

It is **not** part of the `pico_firmware` build — it's a separate, self-contained
diagnostic with its own `main()` and CMake project.

## Result on this board (2026-06-01)

```
1 device(s) responding.
  0x5D: Goodix GTxxx  product ID = "911" (39 31 31 00)
```

→ **Goodix GT911**, 7-bit I²C address **`0x5D`**. The address is selected by the
INT pin level when RST is released: low/floating → `0x5D`, high → `0x14`.

## Wiring

| Touch breakout | Pico 2 W pin |
|---|---|
| SDA | GP4 (physical pin 6) |
| SCL | GP5 (physical pin 7) |
| VCC | 3V3 OUT (pin 36) — *not* VBUS/VSYS |
| GND | any GND |
| RST | 3V3 via ~10k (chip must be out of reset to answer) |

Enumeration works on the RP2350 internal pull-ups for short wires; add external
**4.7 kΩ** to 3V3 on SDA and SCL for reliable, faster traffic.

## Build & flash

```sh
export PICO_SDK_PATH=~/ref/pico-sdk      # if not already set
cmake -S . -B build -G Ninja -DPICO_BOARD=pico2_w
cmake --build build
# flash without the BOOTSEL button (firmware exposes a reset interface):
picotool load -x -f build/i2c_touch_probe.uf2
```

Then read results over USB serial (CDC ignores baud rate):

```sh
cat /dev/cu.usbmodem*        # macOS;  or:  screen /dev/cu.usbmodem* 115200
```

It rescans every 3 s and names any device at a known touch address
(FT5x06/FT6x06 `0x38`, GT911 `0x5D`/`0x14`, CST816 `0x15`, …).
