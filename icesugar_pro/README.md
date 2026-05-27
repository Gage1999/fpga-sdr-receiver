# icesugar_pro/

SystemVerilog for the iCESugar-Pro (ECP5-25K) — the screen/rendering subsystem.

- `src/` — the SystemVerilog modules. The current FM bitstream is built:
  SPI IQ ingest, `fft256` → `waterfall_buf`, FM demod → `i2s_tx`, and the LCD
  driver (`top.sv`). See [../docs/fpga-sdr-receiver-interface.md](../docs/fpga-sdr-receiver-interface.md)
  for the link/dataflow, and [../docs/fpga-sdr-receiver-architecture.md](../docs/fpga-sdr-receiver-architecture.md)
  for the (not-yet-built) SDRAM-backed renderer the image modes need.
- `model/` — the **C reference model**: `pixel_shader.c`, `fb_compositor.c`,
  `regions.c`, and the font/sprite/palette ROMs. This defines, bit-for-bit, what
  the SystemVerilog in `src/` must compute. It's portable C, built by the host
  harness and the `tests/` golden suite so the spec is exercised before any SV
  exists. The Pico firmware does not use it — it depends only on `shared/`.

## Bring-up order (mirrors architecture doc §10)

1. SDRAM controller standalone
2. SDRAM + scan-out reader → solid color FB → display
3. Line cache + arbiter → scrolling test pattern
4. UI state shadow + Pico SPI slave → live touch cursor overlay
5. Font/sprite ROMs + status bar shader
6. Compositor `waterfall_step` (FM waterfall mode)
7. Pluto SPI ingest
8. Image-mode paths: GOES satellite image and ADS-B map (both slow-update,
   single-buffered; only the waterfall needs the back buffer)

## Verilator parity tests (planned)

When SV modules exist, add `icesugar_pro/sim/` testbenches that:
- consume the same wire bytes the C host harness sees (already in `tests/`)
- assert SV output is byte-equal to the C reference for golden test inputs

## ROM .mem files

Generate with:

```sh
python3 tools/rom_to_mem.py --out icesugar_pro/mem
```

These are committed when the gateware build needs them, not before.

## ADS-B basemap

The ADS-B map mode needs a static basemap image in SDRAM (`ADSB_BASEMAP`).
[`tools/map_to_rom.py`](../tools/map_to_rom.py) fetches it from a slippy-map tile
server centered on a given lat/lon and emits RGB565 (`.bin`/`.mem`) at the
renderer's scale. See [`model/assets/README.md`](model/assets/README.md). Until
that image is loaded, the C reference model draws a stylized UCR-centered
placeholder (range rings + marker).

## SDRAM controller

We need an SDRAM controller regardless of render mode. The professor's
[icesugar-pro-framebuffer](https://github.com/UCR-CS122A/icesugar-pro-framebuffer)
demo (LVGL into a CPU-driven framebuffer) is **not** our architecture — we render
on the FPGA, not from a soft CPU — but its SDRAM controller / PHY for this exact
board is a useful reference for steps 1–2 above. See the architecture doc for why
the rest of that demo's approach doesn't fit.
