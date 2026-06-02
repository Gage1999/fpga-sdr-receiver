# icesugar_pro/

SystemVerilog for the iCESugar-Pro (ECP5-25K) display, SDRAM, waterfall, and
audio subsystem.

- `src/` contains the SystemVerilog modules. The normal `top.sv` build ingests
  TLV-framed SPI IQ, runs the FFT/waterfall path through the SDRAM-backed
  compositor, demodulates FM audio, and drives the LCD plus I2S DAC.
- `model/` contains the C reference model: `pixel_shader.c`,
  `fb_compositor.c`, `regions.c`, and the font/sprite/palette ROMs. This
  defines what the SystemVerilog in `src/` should compute and provides golden
  behavior for host-side tests.

## Current Build Targets

- `make prog`: integrated TLV-IQ build. Pair with `plutosky make radio-run` or
  `plutosky make synth-fm-run`.
- `make prog_fm_audio_test`: minimal FM audio diagnostic without the LCD/SDRAM
  display stack.
- `make prog_sdram_test`: basic SDRAM controller write/read diagnostic.

The current waterfall compositor uses a grayscale palette. Color waterfall
mapping is still a pending integration task.

## Verilator parity tests (planned)

When SV modules exist, add `icesugar_pro/sim/` testbenches that:
- consume the same wire bytes the C host harness sees (already in `tests/`)
- assert SV output is byte-equal to the C reference for golden test inputs

## ROM .mem files

The display shader uses generated font and sprite ROM memories. The IceSugar
`Makefile` generates them automatically before simulation or synthesis.

Regenerate the ROMs manually with:

```sh
python3 tools/rom_to_mem.py --out icesugar_pro/build
```

The generated `.mem` files are build outputs and do not need to be committed.

## ADS-B basemap

The ADS-B map mode needs a static basemap image in SDRAM (`ADSB_BASEMAP`).
[`tools/map_to_rom.py`](../tools/map_to_rom.py) fetches it from a slippy-map tile
server centered on a given lat/lon and emits RGB565 (`.bin`/`.mem`) at the
renderer's scale. See [`model/assets/README.md`](model/assets/README.md). Until
that image is loaded, the C reference model draws a stylized UCR-centered
placeholder (range rings + marker).

## SDRAM controller

The integrated top now uses the local SDRAM controller with the arbiter,
compositor, scan-out, and line-cache stack. The professor's
[icesugar-pro-framebuffer](https://github.com/UCR-CS122A/icesugar-pro-framebuffer)
demo remains a useful board reference, but this project renders in FPGA logic
rather than through a soft CPU framebuffer.
