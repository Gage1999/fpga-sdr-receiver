# i2c_touch_probe - touch-controller bring-up tool

Standalone Pico 2 W firmware that scans `i2c0`, identifies the touch controller
by reading its ID registers, then polls the GT911 touch-status and point
registers. Use this before debugging Pico -> FPGA -> Pluto commands; it proves
whether the Pico is actually seeing finger contacts.

This diagnostic is not part of the normal `pico_firmware` build. It has its own
`main()` and CMake project.

## Known Board Result

```text
1 device(s) responding.
  0x5D: Goodix GTxxx  product ID = "911" (39 31 31 00)
```

That is a Goodix GT911 at 7-bit I2C address `0x5D`. The address is selected by
the INT pin level when RST is released: low/floating selects `0x5D`, high
selects `0x14`.

## Wiring

| Touch breakout | Pico 2 W pin |
|---|---|
| SDA | GP4, physical pin 6 |
| SCL | GP5, physical pin 7 |
| VCC | 3V3 OUT, pin 36, not VBUS/VSYS |
| GND | any GND |
| RST | 3V3 through about 10k, or otherwise released high |

Enumeration works on RP2350 internal pull-ups for short wires. Add external
4.7k pull-ups to 3V3 on SDA and SCL for more reliable traffic.

## Build And Flash

```sh
export PICO_SDK_PATH=~/ref/pico-sdk
cmake -S . -B build -G Ninja -DPICO_BOARD=pico2_w
cmake --build build
picotool load -x -f build/i2c_touch_probe.uf2
```

Then read results over USB serial. CDC ignores baud rate.

```sh
cat /dev/cu.usbmodem*
```

On Windows, use the Pico's USB serial COM port in a serial monitor at any baud
rate, commonly 115200.

## Expected Output

The firmware rescans every 3 seconds and names any device at a known touch
address. After a Goodix device is found, it polls every 100 ms.

Idle output:

```text
Entering GT911 touch poll at 0x5D. Touch the panel; raw points print below.
GT911 0x5D: idle status=0x00
```

Touch output:

```text
GT911 0x5D: READY status=0x81 count=1
  point[0]: id=0 x=123 y=456 size=12 raw=00 7B 00 C8 01 0C 00 00
```

The raw point bytes are read starting at GT911 register `0x814F`:
`track_id, x_lo, x_hi, y_lo, y_hi, size_lo, size_hi, reserved`.

## Interpreting Failures

If no device responds at `0x5D` or `0x14`, check power, ground, SDA/SCL wiring,
pull-ups, and that RST is released.

If the scanner sees `0x5D` but touches never produce `READY`, check the
flex/cable orientation, INT/RST wiring, and whether the panel glass/controller is
actually connected.

If `READY` appears but coordinates are wrong or swapped, adjust
`GOODIX_SWAP_XY`, `GOODIX_INVERT_X`, and `GOODIX_INVERT_Y` in
`pico2w/src/touch_goodix.c` after confirming raw values here.
