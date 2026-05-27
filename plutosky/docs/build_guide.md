# Build Guide

How to rebuild the PlutoSky bitstream/BOOT.BIN, build the iCeSugar Pro FPGA
design, and run the current board-level tests.

All commands are written for Windows Terminal with PowerShell.

---

## 1. Project Pieces

This project currently uses two FPGA builds:

| Directory | Target | Purpose |
|-----------|--------|---------|
| `plutosky/` | Zynq BOOT.BIN | AD9363 RF capture plus AXI SPI on JP5 |
| `icesugar_pro/` | ECP5 bitstream | LCD waterfall, FM demod, I2S audio, Pico command SPI |

The PlutoSky sends IQ samples to the iCeSugar Pro over JP5 SPI. The iCeSugar
then renders the waterfall and drives the I2S DAC.

---

## 2. Tools

Required:

| Tool | Purpose |
|------|---------|
| Vivado 2022.1 | PlutoSky synthesis, implementation, bootgen |
| Vitis 2022.1 ARM compiler | Build PlutoSky userspace test apps |
| OSS CAD Suite | Build and program the iCeSugar Pro bitstream |
| Python 3.10+ | Maia SDR IP generation and helper scripts |
| Git for Windows | Git Bash for ADI HDL IP packaging script |

Set these paths for your machine:

```powershell
$env:VIVADO = "C:\Xilinx\Vivado\2022.1"
$env:OSS_CAD = "C:\path\to\oss-cad-suite"
$env:ADI_IGNORE_VERSION_CHECK = "1"
$env:ADI_NO_BITSTREAM_COMPRESSION = "1"
```

Load OSS CAD Suite before building iCeSugar:

```powershell
. "$env:OSS_CAD\environment.ps1"
```

The PlutoSky Makefile currently expects the Vitis ARM compiler here:

```text
C:/Xilinx/Vitis/2022.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc
```

If your Vitis install is elsewhere, update `plutosky/Makefile`.

---

## 3. Clone And Initialize Submodules

```powershell
git submodule update --init
cd plutosky\src\maia-sdr
git submodule update --init maia-hdl/adi-hdl
cd ..\..\..
```

Only `maia-hdl/adi-hdl` is needed for the current build.

---

## 4. Build ADI HDL Library IPs

Run this once after cloning, or after updating `adi-hdl`.

```powershell
& "C:\Program Files\Git\bin\bash.exe" plutosky\src\fishball7020_rf\build_libs.sh
```

This packages the ADI HDL library IPs needed by the Vivado project.

---

## 5. Build The Maia SDR IP

Skip this step if this file already exists:

```text
plutosky\src\maia-sdr\maia-hdl\ip\maia-sdr\maia_iio\component.xml
```

Build it with:

```powershell
cd plutosky\src\maia-sdr\maia-hdl

pip install -e .
pip install amaranth

$env:PATH = "$env:OSS_CAD\bin;$env:OSS_CAD\lib;$env:PATH"

cd ip\maia-sdr\maia_iio
python -m maia_hdl.maia_sdr --config maia_iio maia_sdr.v

cd ..
$env:IP_CORE_VERSION = "0.6.2"
$env:MAIA_SDR_CONFIG = "maia_iio"
& "$env:VIVADO\bin\vivado" -mode batch -source package_ip.tcl

cd ..\..\..\..
```

---

## 6. Build The PlutoSky Bitstream

From the repo root:

```powershell
& "$env:VIVADO\bin\vivado" -mode batch -source plutosky\src\fishball7020_rf\rebuild.tcl
```

Output:

```text
plutosky\src\fishball7020_rf\fishball7020_rf.runs\impl_1\system_top.bit
```

Expect the build to take roughly 15-25 minutes.

The current PlutoSky bitstream includes an AXI Quad SPI controller at:

```text
0x7C440000
```

It drives JP5 SPI at about 12.5 MHz with the current `C_SCK_RATIO=8` setting.

---

## 7. Build PlutoSky BOOT.BIN

BOOT.BIN contains:

1. FSBL
2. PlutoSky FPGA bitstream
3. U-Boot

Build it with:

```powershell
cd plutosky\src\boot_parts
& "$env:VIVADO\bin\bootgen" -arch zynq -image fishball7020_rf.bif -o BOOT.bin -w on
cd ..\..\..
```

Verify the image:

```powershell
& "$env:VIVADO\bin\bootgen" -arch zynq -read plutosky\src\boot_parts\BOOT.bin
```

Expected partitions:

```text
fsbl.elf
system_top.bit
u-boot.bin
```

Vivado may print an overlap warning for `fsbl.elf` and `system_top.bit`. That is
a known Vivado 2022.1 warning for this image layout.

---

## 8. Deploy PlutoSky BOOT.BIN

The board defaults to USB Ethernet at `192.168.2.1`.

Copy the new BOOT.BIN:

```powershell
scp -O plutosky\src\boot_parts\BOOT.bin root@192.168.2.1:/boot/BOOT.bin.new
```

Check the hash:

```powershell
$local = (Get-FileHash -Algorithm MD5 "plutosky\src\boot_parts\BOOT.bin").Hash.ToLower()
$remote = (ssh root@192.168.2.1 "md5sum /boot/BOOT.bin.new").Split(" ")[0]
Write-Host "Local : $local"
Write-Host "Remote: $remote"
```

Swap it in:

```powershell
ssh root@192.168.2.1 "cp /boot/BOOT.bin /boot/BOOT.bin.bak && mv /boot/BOOT.bin.new /boot/BOOT.bin && sync"
```

Power-cycle the PlutoSky after replacing BOOT.BIN.

---

## 9. Build And Program iCeSugar Pro

Load OSS CAD Suite first:

```powershell
. "$env:OSS_CAD\environment.ps1"
```

Build the normal iCeSugar bitstream:

```powershell
cd icesugar_pro
make all
```

Program the normal build:

```powershell
make prog
```

Current useful iCeSugar targets:

| Target | Purpose |
|--------|---------|
| `make prog` | Normal full build, `FM_CIC_R=32` |
| `make prog_lcd_test` | LCD color-bar wiring test |
| `make prog_spi_rx_test` | PlutoSky-to-iCeSugar SPI receive display test |
| `make prog_i2s_tone_test` | Standalone I2S/DAC tone test |
| `make prog_full_audio_tone` | Full LCD path plus direct I2S tone |
| `make prog_fm_chain_test` | Internal synthetic FM through FPGA audio chain |
| `make prog_fm_spi8` | Current best external synthetic FM test build |
| `make prog_fm_spi12` | Alternate debug build for different SPI/audio rate |

For the current burst-mode synthetic FM audio test, use:

```powershell
make prog_fm_spi8
```

---

## 10. iCeSugar Simulation Checks

From `icesugar_pro/`:

```powershell
make sim_i2s
make sim_fm
make sim_lcd
make sim_fft
```

The LCD simulation may print Icarus warnings about constant selects in
`always_*` blocks. Those warnings are expected with this toolchain and are not
simulation failures.

---

## 11. Build PlutoSky Userspace Tools

From `plutosky/`:

```powershell
make spi-reg-build
make test-build
make stream-build
```

Useful targets:

| Target | Purpose |
|--------|---------|
| `make spi-reg-run` | Verify AXI SPI register access at `0x7C440000` |
| `make test-run TEST=longtone` | Simple known-good waterfall/SPI sanity test |
| `make stream-run STREAM_ARGS="..."` | Run the IQ streamer |

The Makefile copies the built program to the PlutoSky with `scp -O` and runs it
over SSH.

---

## 12. Verify PlutoSky Hardware

After power-cycling with the new BOOT.BIN:

```powershell
ssh root@192.168.2.1
```

On the board:

```bash
cat /sys/class/fpga_manager/fpga0/state
ls /sys/bus/iio/devices/
```

Expected:

- FPGA manager state is `operating`
- AD936x IIO devices are present

Then verify the AXI SPI block:

```powershell
cd plutosky
make spi-reg-run
```

This should pass all register checks.

---

## 13. Board-Level SPI And Waterfall Tests

First program the iCeSugar with the normal or debug bitstream:

```powershell
cd icesugar_pro
make prog_fm_spi8
```

Then run the simple PlutoSky IQ test:

```powershell
cd ..\plutosky
make test-run TEST=longtone
```

Expected LCD result:

```text
Two distinct thin red bands surrounded by mostly black.
```

If this fails, check the physical SPI wiring before debugging the SDR pipeline.

Current iCeSugar CS0 landing pins:

| PlutoSky JP5 signal | iCeSugar signal | iCeSugar site |
|---------------------|-----------------|---------------|
| SCK | `spi_clk` | D7 |
| MOSI | `mosi` | D8 |
| CS | `cs` | D9 |

---

## 14. Current Synthetic FM Test

The current best external synthetic FM test uses iCeSugar `prog_fm_spi8` and a
large burst from the PlutoSky userspace streamer:

```powershell
cd icesugar_pro
make prog_fm_spi8

cd ..\plutosky
make stream-run STREAM_ARGS="--mode synth-fm --rate 349000 --duration 20 --synth-amp 12000 --synth-dev 2500 --chunk-samples 65536"
```

Recent measured result:

```text
Requested: about 349000 samples/s
Actual:    about 348647 samples/s
```

This is the best synthetic FM audio test so far. Some pulsing/static can still
occur because the stream is userspace-driven and not hardware paced.

For display-only SPI sanity, this conservative command is also useful:

```powershell
make stream-run STREAM_ARGS="--mode synth-tone --rate 264000 --duration 20 --per-word-cs --synth-amp 32000 --word-delay-us 10"
```

Per-word CS is reliable for wiring/debug, but it is too slow for clean FM audio.

---

## 15. Live FM Test Starting Point

Live FM testing is the next step after synthetic FM. Start from the same
iCeSugar build:

```powershell
cd icesugar_pro
make prog_fm_spi8
```

Then try PlutoSky live FM mode:

```powershell
cd ..\plutosky
make stream-run STREAM_ARGS="--mode fm --freq-mhz 95.1 --adc-rate 0 --rate 349000 --duration 20 --chunk-samples 65536"
```

Notes:

- Change `--freq-mhz` to a strong local FM station.
- `--adc-rate 0` lets the app try its fallback AD9363 sample rates.
- The final printed `samples/s` matters. It should be near the requested output
  rate for the current `prog_fm_spi8` test.
- This is still a development path, not a final hardware-paced streamer.

---

## 16. Known Current Limitations

- JP5 SPI is currently about 12.5 MHz.
- Jumper-wire signal integrity matters. Keep SCK, MOSI, CS, and GND short.
- Per-word CS is too slow for audio-rate FM.
- Burst userspace streaming is much faster, but still has timing jitter and
  possible chunk-gap artifacts.
- A future hardware-paced or DMA-style streamer is expected for cleaner final
  FM audio.

