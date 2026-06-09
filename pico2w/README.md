# Pico 2W Firmware

This folder contains the Raspberry Pi Pico 2W firmware for the touch/UI side of
the receiver. The Pico reads the Goodix GT911 capacitive touch panel, runs the
portable UI state machine, and sends UI wire frames to the iCeSugar-Pro over SPI.

The Pico does not render pixels and does not communicate directly with the
PlutoSky. Display rendering happens on the ECP5, and radio retune/mode commands
are forwarded by the iCeSugar-Pro to the PlutoSky over the JP5 backchannel.

## Demo Role

For the presentation build, the Pico provides the touch controls for the active
FM showcase path:

1. Touch input is sampled from the GT911 controller.
2. `ui_logic.c` updates the shared UI state.
3. The Pico sends framed UI packets to the iCeSugar-Pro.
4. The iCeSugar-Pro uses that state for on-screen controls and forwards radio
   commands to the PlutoSky when needed.

The same UI logic is also exercised by the host-side tests, so behavior can be
checked without flashing the board.

## Source Layout

| Path | Purpose |
|---|---|
| `src/main.c` | Firmware entry point and 60 Hz UI tick loop |
| `src/ui_logic.c` | Portable UI state machine shared with host tests |
| `src/hal_pico.c` | Pico hardware abstraction for SPI and touch polling |
| `src/touch_goodix.c` | Goodix GT911 I2C touch driver |
| `include/` | Firmware headers |
| `src/i2c_touch_probe/` | Standalone GT911/I2C bring-up utility |

## Hardware Links

### Goodix GT911 Touch

| Signal | Pico 2W pin | Notes |
|---|---|---|
| SDA | GP4 | I2C0 data |
| SCL | GP5 | I2C0 clock |
| Address | `0x5D` | 7-bit GT911 address |

The touch driver probes the GT911 product ID and then polls the controller for a
single primary touch point. Coordinate calibration can be adjusted in
`src/touch_goodix.c` with the `GOODIX_*` macros.

### UI SPI To iCeSugar-Pro

| Signal | Pico 2W pin | iCeSugar-Pro link |
|---|---|---|
| SCK | GP18 | P5 / `spi_clk_pico` / ECP5 D12 |
| MOSI | GP19 | P5 / `mosi_pico` / ECP5 C11 |
| CS | GP17 | P5 / `cs1` / ECP5 D13 |
| GND | GND | Common ground |

The Pico is the SPI master. Frames use mode 0, 8-bit, MSB-first transfers at
8 MHz. The payload format is defined in the shared wire protocol code.

## Build

Build the firmware from the repository root with the Pico SDK enabled:

```powershell
$env:PICO_SDK_PATH = "C:\path\to\pico-sdk"
cmake -S . -B build-pico -G Ninja -DBUILD_FIRMWARE=ON
cmake --build build-pico --target pico_firmware
```

If `PICO_SDK_PATH` is already set in the environment, the first line can be
omitted. CMake emits `pico_firmware.uf2` under the build tree.

## Flash

1. Hold BOOTSEL while plugging in the Pico 2W.
2. Wait for the `RPI-RP2` drive to mount.
3. Copy `pico_firmware.uf2` to the drive.
4. The board reboots into the new firmware automatically.

## Touch Probe

`src/i2c_touch_probe/` is a small standalone utility for confirming the GT911
touch controller before running the full UI firmware. Use it when validating a
new panel, cable, or I2C wiring issue.

## Host Tests

The portable UI logic is covered by the top-level host tests:

```sh
cmake -S . -B build -G Ninja
cmake --build build
ctest --test-dir build --output-on-failure
```

Keep platform I/O in `hal_pico.c` and keep UI behavior in `ui_logic.c` so the
same control logic remains testable on the host and usable on hardware.
