# fpga-sdr-receiver

A multi-device software-defined radio that decodes and **displays** signals on a
4.3" LCD, with rendering done on an FPGA rather than a CPU framebuffer.

Signal chain: **PlutoSky 7020** (AD9363 RF + Zynq) -> **iCESugar-Pro** (ECP5 FPGA,
renders the screen) -> 800x480 RGB LCD, with a **Raspberry Pi Pico 2W** handling
the touch UI and auxiliary I/O.

The center of the screen has three switchable modes, fed from the RF front end:

| Mode | What it shows | Update rate | Buffering |
|---|---|---|---|
| **FM** | Spectrum + scrolling waterfall | fast (per-frame) | double-buffered |
| **GOES** | Weather-satellite image | slow (~lines/sec) | single |
| **ADS-B** | Riverside-area map with aircraft as dots | slow (~Hz) | single |

Only one mode is active at a time - the AD9363 can't hold two RX LO frequencies
at once - but switching is meant to feel seamless. (See the note below on GOES vs
NOAA APT.)

---

## Presentation Status

The showcase build is the FM receiver path: PlutoSky TLV-IQ streaming into the
iCESugar-Pro, FPGA spectrum/waterfall rendering on the LCD, FM audio over I2S,
and Pico-driven touch UI state. GOES and ADS-B assets/protocol hooks remain in
the repo as documented extension paths, but the default gateware build is kept
focused on the working FM demo.

---

## Devices

| Directory | Device | Role | Status |
|---|---|---|---|
| [`plutosky/`](plutosky/) | PlutoSky 7020 (XC7Z020, AD9363) | RF front end + JP5 AXI SPI source | AXI SPI verified, RF active |
| [`icesugar_pro/`](icesugar_pro/) | iCESugar-Pro (ECP5-25K) | display / rendering gateware | FM display/audio showcase path active |
| [`pico2w/`](pico2w/) | Raspberry Pi Pico 2W (RP2350) | touch UI firmware | UI logic + GT911/SPI framing implemented |

---

## Repository layout

```
plutosky/         PlutoSky 7020 RF front end (Vivado project, board scripts, ARM runtime)
  src/  tests/  docs/
icesugar_pro/     ECP5 display gateware
  src/            SystemVerilog modules (in development)
  model/          C reference model the SV must match byte-for-byte:
                  pixel shader, framebuffer compositor, region map, ROMs
  README.md       final build targets, diagnostics, ROM generation, SDRAM notes
pico2w/           Pico 2W UI + touch firmware
  src/  include/  CMakeLists.txt

shared/           PORTABLE C Pico<->FPGA contract: UI state + wire protocol +
                  screen config + touch (no malloc/stdio/platform headers)
host/             SDL host harness - runs the model + pico2w/ui_logic on a laptop
tests/            host-side unit + golden-image tests (CI-suitable, no SDL)
tools/            ROM generators (font/sprite/palette C -> .mem for the ECP5)
docs/             public architecture, interface, and host-model docs
proposal/         project proposal
```

### The portability contract

Every line in `shared/`, `icesugar_pro/model/`, and `pico2w/src/ui_logic.c` is
pure portable C (only `<stdint.h>`, `<stddef.h>`, `<string.h>`, `<stdbool.h>` - no
malloc, no stdio, no platform headers). The host harness wraps it through a thin
HAL; the Pico firmware wraps it through a different HAL with the same signatures.
The same test inputs/goldens validate that the gateware produces byte-equal
output to the C reference in
`icesugar_pro/model/src/pixel_shader.c` and `icesugar_pro/model/src/fb_compositor.c`.
The Pico itself does no rendering - it only depends on `shared/`.

See [docs/fpga-sdr-receiver-harness.md](docs/fpga-sdr-receiver-harness.md) and
[docs/fpga-sdr-receiver-architecture.md](docs/fpga-sdr-receiver-architecture.md).

---

## Getting started - PlutoSky (RF front end)

Download the pre-built release, then follow
[`plutosky/docs/ssh_setup.md`](plutosky/docs/ssh_setup.md) to configure SSH key
access and deploy the board scripts.

**Release contents:**

| File | Device | Description |
|---|---|---|
| `plutosky-sd-card.zip` | PlutoSky | BOOT.BIN + uEnv.txt + Linux kernel + ramdisk |

Once flashed and booted:

```powershell
# Configure ~/.ssh/config first; see plutosky/docs/ssh_setup.md
ssh pluto-usb
```

From the repo root on the development machine:

```powershell
# Verify the JP5 AXI SPI register block
cd plutosky
make spi-reg-run

# Run the final FM receiver path
make radio-run FREQ_MHZ=95.1
```

To rebuild from source, see [`plutosky/docs/build_guide.md`](plutosky/docs/build_guide.md).

---

## Getting started - frontend (host harness)

Develop and test the rendering + UI on a laptop before the gateware exists.

Dependencies: CMake >= 3.20, a C11 compiler, SDL2 (for `host_harness` only).

```sh
brew install sdl2 cmake          # macOS
cmake -B build
cmake --build build -j
ctest --test-dir build --output-on-failure
./build/host_harness             # live demo
## Hardware

| Property | Value |
|---|---|
| RF board | PlutoSky 7020 (fishball7020) |
| RF SoC | XC7Z020-2CLG400I (Zynq-7000, CLG400 package) |
| RF IC | AD9363 (AD9361-compatible, LVDS 6-lane) |
| Base firmware | maia-sdr (tezuka build) |
| USB device IP | 192.168.2.1 |
| JP5 data link | AXI Quad SPI at 0x7C440000, about 12.5 MHz SCK |
| Display FPGA | Lattice ECP5-25K (iCESugar-Pro) + 32 MB SDRAM |
| LCD | 4.3" 800x480 RGB-parallel, 60 Hz, RGB565 |
| Touch | Goodix **GT911** capacitive over I^2C on the Pico (7-bit addr `0x5D`, i2c0 GP4/GP5) |
| Pico<->FPGA | SPI, Pico master, mode 0, MSB-first; Pico GP18/GP19/GP17 to iCESugar P5 D12/C11/D13; `0xA5` UI wire frames |

---

## Docs

| | |
|---|---|
| [`docs/fpga-sdr-receiver-architecture.md`](docs/fpga-sdr-receiver-architecture.md) | ECP5 data path, SDRAM arbiter, EBR map, display timing |
| [`docs/fpga-sdr-receiver-interface.md`](docs/fpga-sdr-receiver-interface.md) | PlutoSky, iCeSugar, and Pico physical/protocol links |
| [`docs/fpga-sdr-receiver-harness.md`](docs/fpga-sdr-receiver-harness.md) | Host model, test harness, CTest, and Verilator parity flow |
| [`icesugar_pro/README.md`](icesugar_pro/README.md) | Final gateware build, diagnostics, ROM generation, SDRAM notes |
| [`plutosky/docs/architecture.md`](plutosky/docs/architecture.md) | RF hardware, boot chain, FPGA design, AXI SPI map |
| [`plutosky/docs/build_guide.md`](plutosky/docs/build_guide.md) | Rebuild bitstream and BOOT.BIN from source |
| [`plutosky/docs/ssh_setup.md`](plutosky/docs/ssh_setup.md) | SSH key setup on a fresh board |

---

## Notes

**GOES mode.** The display includes a satellite-image mode for GOES LRIT/HRIT
work. FM is the showcase path; GOES support remains an extension path in the
PlutoSky runtime and display protocol.

**Professor's framebuffer demo.** UCR provides an
[icesugar-pro-framebuffer](https://github.com/UCR-CS122A/icesugar-pro-framebuffer)
demo that drives an LVGL framebuffer from a soft CPU. That is **not** our
architecture - we render directly in fabric (compositor + live pixel shader), not
from a CPU framebuffer - so we're not adopting its rendering approach. Its **SDRAM
controller / PHY** for this exact board is, however, a useful reference for our own
SDRAM implementation notes (see [`icesugar_pro/README.md`](icesugar_pro/README.md)).
