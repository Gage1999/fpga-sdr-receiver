# PlutoSky 7020: Custom SDR Firmware

Multi-device SDR pipeline targeting NOAA satellite APT image display.
Signal chain: PlutoSky 7020 (AD9363 RF) → iCESugar Pro (ECP5 FPGA) → 800x480 LCD,
with a Pi Pico 2W handling auxiliary I/O.

---

## Devices

| Directory | Device | Status |
|---|---|---|
| [`plutosky/`](plutosky/) | PlutoSky 7020 (XC7Z020, AD9363) | GPIO verified, RF active |
| [`icesugar_pro/`](icesugar_pro/) | iCESugar Pro (ECP5) | In development |
| [`pico2w/`](pico2w/) | Raspberry Pi Pico 2W (RP2350) | In development |

---

## Getting started

Download the pre-built release, then follow [`plutosky/docs/ssh_setup.md`](plutosky/docs/ssh_setup.md)
to configure SSH key access and deploy the board scripts.

**Release contents:**

| File | Device | Description |
|---|---|---|
| `plutosky-sd-card.zip` | PlutoSky | BOOT.BIN + uEnv.txt + Linux kernel + ramdisk |

Once flashed and booted:

```bash
# Configure ~/.ssh/config first; see plutosky/docs/ssh_setup.md
ssh pluto-usb

# Drive all four JP5 GPIO pins HIGH
gpioset gpiochip0 71=1 72=1 73=1 74=1
```

To rebuild from source, see [`plutosky/docs/build_guide.md`](plutosky/docs/build_guide.md).

---

## Repository layout

```
plutosky/
  src/
    fishball7020_rf/        Vivado project (bitstream source)
    board/                  Board scripts deployed to /mnt/jffs2/
    boot_parts/             BOOT.BIN assembly inputs
    maia-sdr/               maia-sdr submodule (pinned commit)
  tests/
    apt_receive.py          NOAA APT satellite image receiver
    fm_test.py              FM demodulation and audio playback test
  docs/
    architecture.md         Hardware, boot chain, FPGA design
    build_guide.md          Step-by-step bitstream and BOOT.BIN rebuild
    ssh_setup.md            SSH key setup on a fresh board

icesugar_pro/
  src/                      ECP5 firmware source (in development)
  tests/
  docs/

pico2w/
  src/                      RP2350 firmware source (in development)
  tests/
  docs/
```

---

## Hardware

| Property | Value |
|---|---|
| Board | PlutoSky 7020 (fishball7020) |
| SoC | XC7Z020-2CLG400I (Zynq-7000, CLG400 package) |
| RF IC | AD9363 (AD9361-compatible, LVDS 6-lane) |
| Base firmware | maia-sdr (tezuka build) |
| USB device IP | 192.168.2.1 |
| JP5 GPIO | gpiochip0 lines 71-74 (EMIO[17:20], Bank 13, 3.3V) |

---

## PlutoSky docs

| | |
|---|---|
| [`plutosky/docs/architecture.md`](plutosky/docs/architecture.md) | Hardware, boot chain, FPGA design, AXI/EMIO maps |
| [`plutosky/docs/build_guide.md`](plutosky/docs/build_guide.md) | Step-by-step rebuild of bitstream and BOOT.BIN from source |
| [`plutosky/docs/ssh_setup.md`](plutosky/docs/ssh_setup.md) | SSH key setup on a fresh board |
