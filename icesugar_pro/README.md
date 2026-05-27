# icesugar_pro/

SystemVerilog for the iCESugar-Pro (ECP5-25K) — the screen/rendering subsystem.
`src/` is empty for now; see
[../docs/fpga-sdr-receiver-architecture.md](../docs/fpga-sdr-receiver-architecture.md)
for the planned module breakdown and the SDRAM controller design.

The C in the top-level `shared/` is the **executable spec** for this gateware:
`shared/src/pixel_shader.c` and `shared/src/fb_compositor.c` define, bit-for-bit,
what the SystemVerilog must compute. The shared test inputs/goldens in `tests/`
validate both the C reference and (eventually) the SV.

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

## SDRAM controller

We need an SDRAM controller regardless of render mode. The professor's
[icesugar-pro-framebuffer](https://github.com/UCR-CS122A/icesugar-pro-framebuffer)
demo (LVGL into a CPU-driven framebuffer) is **not** our architecture — we render
on the FPGA, not from a soft CPU — but its SDRAM controller / PHY for this exact
board is a useful reference for steps 1–2 above. See the architecture doc for why
the rest of that demo's approach doesn't fit.
