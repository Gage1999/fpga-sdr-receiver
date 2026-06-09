# PlutoSky Build Guide

This guide covers the PlutoSky side of the project: rebuilding the Zynq
bitstream/BOOT.BIN, building the ARM userspace programs, and running the final
demo flow with the iCeSugar Pro.

Commands assume Windows Terminal with PowerShell unless noted otherwise.

## Repository Layout

| Path | Role |
|---|---|
| `plutosky/src/fishball7020_rf/` | Vivado project scripts and top-level Zynq design |
| `plutosky/src/boot_parts/` | FSBL, U-Boot, BIF file, and BOOT.BIN inputs |
| `plutosky/src/main.c` | Final combined FM/GOES/ADS-B runtime (`sdr_main`) |
| `plutosky/src/icesugar_stream.c` | Standalone IQ streamer diagnostic |
| `plutosky/tests/test_spi_reg.c` | AXI SPI register sanity test |

The final presentation path is:

```text
PlutoSky AD9363 -> sdr_main -> JP5 SPI TLV stream -> iCeSugar Pro
```

## Requirements

| Tool | Purpose |
|---|---|
| Vivado 2022.1 | Zynq synthesis, implementation, and bootgen |
| Vitis 2022.1 ARM GCC | Builds PlutoSky userspace binaries |
| Git for Windows | Runs ADI HDL helper scripts with Bash |
| Python 3.10+ | Builds Maia SDR helper IP when needed |
| OSS CAD Suite | Builds/programs the iCeSugar Pro bitstream |

Set the paths for your machine:

```powershell
$env:VIVADO = "C:\Xilinx\Vivado\2022.1"
$env:OSS_CAD = "C:\path\to\oss-cad-suite"
$env:ADI_IGNORE_VERSION_CHECK = "1"
$env:ADI_NO_BITSTREAM_COMPRESSION = "1"
```

The PlutoSky Makefile defaults to this Vitis compiler:

```text
C:/Xilinx/Vitis/2022.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc
```

Override it if your install is elsewhere:

```powershell
make CROSS=C:/path/to/arm-linux-gnueabihf-gcc sdr-build
```

## First-Time Setup

Initialize submodules:

```powershell
git submodule update --init
cd plutosky\src\maia-sdr
git submodule update --init maia-hdl/adi-hdl
cd ..\..\..
```

Package the ADI HDL library IPs:

```powershell
& "C:\Program Files\Git\bin\bash.exe" plutosky\src\fishball7020_rf\build_libs.sh
```

If the Maia SDR IP is missing, build and package it:

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

The expected packaged IP is:

```text
plutosky\src\maia-sdr\maia-hdl\ip\maia-sdr\maia_iio\component.xml
```

## Rebuild The PlutoSky FPGA Image

Build the Zynq bitstream:

```powershell
& "$env:VIVADO\bin\vivado" -mode batch -source plutosky\src\fishball7020_rf\rebuild.tcl
```

Output:

```text
plutosky\src\fishball7020_rf\fishball7020_rf.runs\impl_1\system_top.bit
```

Build BOOT.BIN:

```powershell
cd plutosky\src\boot_parts
& "$env:VIVADO\bin\bootgen" -arch zynq -image fishball7020_rf.bif -o BOOT.bin -w on
cd ..\..\..
```

Verify the image contents:

```powershell
& "$env:VIVADO\bin\bootgen" -arch zynq -read plutosky\src\boot_parts\BOOT.bin
```

Expected partitions:

```text
fsbl.elf
system_top.bit
u-boot.bin
```

Vivado 2022.1 may warn about FSBL/bitstream overlap in this image layout. The
warning is expected for this board package.

## Deploy BOOT.BIN

The board appears over USB Ethernet at `192.168.2.1`.

Copy the image:

```powershell
scp -O plutosky\src\boot_parts\BOOT.bin root@192.168.2.1:/boot/BOOT.bin.new
```

Check the transfer:

```powershell
$local = (Get-FileHash -Algorithm MD5 "plutosky\src\boot_parts\BOOT.bin").Hash.ToLower()
$remote = (ssh root@192.168.2.1 "md5sum /boot/BOOT.bin.new").Split(" ")[0]
Write-Host "Local : $local"
Write-Host "Remote: $remote"
```

Install it and power-cycle the board:

```powershell
ssh root@192.168.2.1 "cp /boot/BOOT.bin /boot/BOOT.bin.bak && mv /boot/BOOT.bin.new /boot/BOOT.bin && sync"
```

After reboot, verify the board:

```powershell
ssh root@192.168.2.1
```

```bash
cat /sys/class/fpga_manager/fpga0/state
ls /sys/bus/iio/devices/
```

Expected:

- FPGA manager state is `operating`
- AD936x IIO devices are present

## Build PlutoSky Userspace

From `plutosky/`:

```powershell
make sdr-build
```

Useful targets:

| Target | Purpose |
|---|---|
| `make sdr-build` | Build the final combined runtime |
| `make sdr-run SDR_MODE=fm SDR_FREQ=95.1` | Deploy and run the final runtime |
| `make radio-run FREQ_MHZ=95.1` | Convenience FM run target for the final runtime |
| `make spi-reg-run` | Verify AXI SPI register access at `0x7C440000` |
| `make stream-run STREAM_ARGS="..."` | Run the standalone IQ streamer diagnostic |
| `make synth-fm-run` | Run synthetic FM through the standalone IQ streamer |

`radio-run` and `sdr-run` both launch `/root/sdr_main` on the board.

## Final Demo Run

Build and program the iCeSugar Pro from `icesugar_pro/`:

```powershell
. "$env:OSS_CAD\environment.ps1"
make prog
```

Run the PlutoSky FM path from `plutosky/`:

```powershell
make radio-run FREQ_MHZ=95.1
```

Use a strong local FM station for `FREQ_MHZ`.

Expected result:

- The iCeSugar display shows live spectrum/waterfall activity.
- FM audio is produced by the iCeSugar I2S path.
- Pico UI mode/frequency commands are relayed back to `sdr_main` through JP5
  MISO.

## Diagnostics

Verify the AXI SPI block:

```powershell
make spi-reg-run
```

Run a synthetic FM source through the same Pluto-to-iCeSugar SPI link:

```powershell
make synth-fm-run
```

Run the standalone TLV test stream:

```powershell
make stream-run STREAM_ARGS="--mode tlv-test --rate 260417 --chunk-samples 256 --duration 20"
```

Useful iCeSugar targets:

| Target | Purpose |
|---|---|
| `make prog` | Final integrated display/audio build |
| `make prog_lcd_test` | LCD wiring diagnostic |
| `make prog_fm_audio_test` | Minimal hardware-proven FM audio path |
| `make prog_fm_audio_iq_test` | FPGA-generated FM IQ through demod/audio |
| `make prog_sdram_test` | SDRAM controller diagnostic |
| `make prog_tlv_link_test` | TLV receive/link diagnostic |

## Notes

- JP5 SPI runs at about 12.5 MHz with the current `C_SCK_RATIO=8` setting.
- Keep JP5 SCK, MOSI, MISO, CS, and GND wiring short.
- The final PlutoSky runtime is `sdr_main`; `icesugar_stream` is retained only
  as a diagnostic utility.
