# iCeSugar Pro Gateware

SystemVerilog for the iCeSugar Pro ECP5-25K display and audio side of the SDR
receiver.

The final showcase build is `src/top.sv`. It receives TLV-framed IQ samples from
PlutoSky over SPI, renders spectrum/waterfall UI to the 800x480 RGB LCD, demods
FM audio, drives the I2S DAC, and relays Pico UI radio commands back to PlutoSky
over the JP5 MISO backchannel.

## Final Demo Flow

Program the iCeSugar Pro:

```sh
make prog
```

Run the matching PlutoSky runtime:

```sh
cd ../plutosky
make radio-run FREQ_MHZ=95.1
```

Use a strong local FM station for `FREQ_MHZ`.

## What Is In The Default Bitstream

`make prog` builds `src/top.sv` with these active feature blocks:

| Area | Modules |
|---|---|
| PlutoSky TLV input | `spi_frame_rx`, `tlv_demux`, `tlv_iq_sink`, `async_fifo` |
| Pico UI input | `spi_ui_cmd_rx`, `ui_wire_rx`, `ui_status_prepare`, `control_regs` |
| PlutoSky backchannel | `spi_backchannel` |
| Spectrum/waterfall | `fft256`, `butterfly`, `twiddle_rom`, `spectrum_bin_ram`, `spectrum_zoom_decimator` |
| SDRAM display path | `sdram_ctrl`, `sdram_arb`, `scan_out`, `line_cache`, `compositor` |
| Pixel UI | `pixel_shader_top`, `pixel_shader`, `font_16x32_rom`, `sprite_rom`, `scan_timing` |
| FM audio | `fm_demod`, `audio_volume`, `audio_fifo`, `i2s_tx` |

The default bitstream intentionally focuses on the working FM display/audio demo.
GOES and ADS-B UI/model assets remain as future extension paths, but their
result-packet renderers are not part of the current `top.sv` data path.

## Source Layout

| Path | Purpose |
|---|---|
| `src/` | Synthesizable SystemVerilog used by the final build and diagnostics |
| `tests/` | Hardware diagnostic top modules, not part of final `SV_SRCS` |
| `tb/` | Icarus Verilog testbenches for module-level checks |
| `sim/` | Verilator shader/ROM parity checks against the C model |
| `model/` | Portable C rendering model and ROM source data |
| `top.lpf` | iCeSugar Pro pin constraints |

RDS modules (`rds_demod`, `rds_sync`, `rds_group`) are retained for future FM
metadata work and standalone simulations. They are not instantiated by the final
top-level build.

`spi_iq_slave.sv` is retained for the standalone FM audio hardware diagnostic.
The final build uses TLV IQ through `spi_frame_rx` and `tlv_iq_sink`.

## Build Targets

| Target | Purpose |
|---|---|
| `make all` | Build the final `top.sv` bitstream |
| `make prog` | Program the final bitstream |
| `make prog_lcd_test` | LCD color-bar wiring diagnostic |
| `make prog_tlv_link_test` | PlutoSky TLV receive/link diagnostic |
| `make prog_fm_audio_test` | Minimal FM audio path using raw SPI IQ |
| `make prog_fm_audio_tone_test` | I2S/DAC tone diagnostic |
| `make prog_fm_audio_iq_test` | FPGA-generated FM IQ through demod/audio |
| `make prog_sdram_test` | SDRAM write/read diagnostic |

The diagnostic bitstreams live under `tests/` and are intentionally separate
from the final build.

## Simulation Targets

Icarus Verilog checks:

| Target | Purpose |
|---|---|
| `make sim` | Top-level smoke test |
| `make sim_fm` | FM demodulator |
| `make sim_audio_fifo` | Audio FIFO |
| `make sim_i2s_tx` | I2S transmitter |
| `make sim_fft` | FFT pipeline |
| `make sim_tlv_all` | SPI frame/TLV receive path |
| `make sim_integration` | SDRAM/display-path integration checks |
| `make sim_rds` | Standalone RDS chain checks |

Shader and ROM parity checks use Verilator:

```sh
cmake -S .. -B ../build -G Ninja -DBUILD_HOST_HARNESS=OFF
cmake --build ../build --target render_model shared
make -C sim run
```

## ROM Memories

The build generates font and sprite memories before synthesis or simulation:

```text
build/font_16x32.mem
build/sprite_rom.mem
```

They are generated from the C model sources with:

```sh
python3 ../tools/rom_to_mem.py --out build
```

The generated `.mem` files are build outputs and should not be committed.

## Model Assets

`model/` contains the portable C reference renderer used by host tests and
Verilator parity checks. The ADS-B basemap assets in `model/assets/` document a
future map-rendering path and are not required for the final FM bitstream.

## Notes

- The final display path uses the local SDRAM controller, arbiter, line cache,
  compositor, and scan-out stack.
- The project renders directly in FPGA fabric.
- The PlutoSky pair for the final build is `plutosky/src/main.c` built as
  `sdr_main`; `plutosky/src/icesugar_stream.c` is only a diagnostic streamer.
