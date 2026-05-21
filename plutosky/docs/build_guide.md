# Build Guide: Bitstream and BOOT.BIN

How to rebuild the FPGA bitstream and create a new `BOOT.BIN` from scratch.
Run this if you want to modify the design or need to reproduce the artifacts.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Build the maia_sdr IP (one-time)](#2-build-the-maia_sdr-ip-one-time)
3. [Build the Bitstream](#3-build-the-bitstream)
4. [Build BOOT.BIN](#4-build-bootbin)
5. [Deploy to the Board](#5-deploy-to-the-board)
6. [Verify](#6-verify)

---

## 1. Prerequisites

### Tools required

| Tool | Purpose |
|---|---|
| Vivado 2022.1 | Synthesis, implementation, bitstream, bootgen |
| oss-cad-suite | Yosys for maia_sdr IP generation |
| Python 3.10+ | Test scripts (`apt_receive.py`, `test_spi.py`, etc.) |

### Environment setup

Set these shell variables once before running any build commands. Add them to
your `.bashrc` or set them at the start of each session:

```bash
export VIVADO=/c/Xilinx/Vivado/2022.1   # adjust to your Vivado install path
export OSS_CAD=/c/oss-cad-suite          # adjust to your oss-cad-suite install path
export ADI_IGNORE_VERSION_CHECK=1        # suppress version mismatch (we use 2022.1, ADI targets 2022.2)
export ADI_NO_BITSTREAM_COMPRESSION=1   # tezuka FSBL does not set COMP_EN; compressed bitstream will not boot
```

All Vivado commands below use `$VIVADO` so they work regardless of install location.
The build steps (sections 2 and 3) require **Git Bash** — the `.sh` scripts and
`export` syntax are bash-specific. SSH and file transfer commands work from any shell.

### Repository layout required

```
project/
  fishball7020_rf/                    ← this repo
  maia-sdr/                           ← submodule (github.com/maia-sdr/maia-sdr)
    maia-hdl/
      adi-hdl/                        <- sub-submodule, ADI HDL library used by the build
        library/axi_ad9361/           ← must be pre-built (component.xml present)
      ip/maia-sdr/maia_iio/           ← pre-built maia IP (component.xml must exist)
```

After cloning, initialize the submodules:

```bash
git submodule update --init                          # fetch maia-sdr
cd plutosky/src/maia-sdr && git submodule update --init maia-hdl/adi-hdl  # fetch adi-hdl inside it
cd ..
```

Only `maia-hdl/adi-hdl` needs to be initialized, `maia-hdl/XilinxUnisimLibrary`
is not used by this build.

All 11 ADI HDL library IPs must be packaged before the Vivado build can run.
Do this once after cloning (or after updating the submodule):

```bash
bash plutosky/src/fishball7020_rf/build_libs.sh
```

This packages `axi_ad9361`, `axi_dmac`, `util_cpack2`, and 8 other IPs used by
the block design. Takes a few minutes. Re-run if you update `adi-hdl`.

---

## 2. Build the maia_sdr IP (one-time)

The maia_sdr IP is generated from Python (amaranth HDL) and synthesized with
Yosys. Only needs to be done once; the result is checked in to the repo.

**Skip this step** if `plutosky/src/maia-sdr/maia-hdl/ip/maia-sdr/maia_iio/component.xml` already exists.

```bash
cd plutosky/src/maia-sdr/maia-hdl

# Install maia_hdl Python package
pip install -e .
pip install amaranth

# oss-cad-suite must be in PATH for its native Yosys binary.
export PATH="$OSS_CAD/bin:$OSS_CAD/lib:$PATH"

MAIA_PYTHON=$(command -v python3)   # or full path, e.g. ~/.pyenv/pyenv-win/shims/python3

# Generate maia_sdr.v (~2 minutes)
cd ip/maia-sdr/maia_iio
$MAIA_PYTHON -m maia_hdl.maia_sdr --config maia_iio maia_sdr.v

# Package as Vivado IP
cd ..
IP_CORE_VERSION=0.6.2 MAIA_SDR_CONFIG=maia_iio $VIVADO/bin/vivado -mode batch -source package_ip.tcl
```

---

## 3. Build the Bitstream

```bash
$VIVADO/bin/vivado -mode batch -source plutosky/src/fishball7020_rf/rebuild.tcl
```

`rebuild.tcl` sets its own working directory before sourcing `system_project.tcl`,
so it can be run from the repo root without a manual `cd`.

Expect 15–25 minutes. The bitstream lands at:
```
plutosky/src/fishball7020_rf/fishball7020_rf.runs/impl_1/system_top.bit
```

**Expected end of `vivado.log`:**
```
write_bitstream completed successfully
51 Infos, 0 Warnings, 7 Critical Warnings and 0 Errors encountered.
```

---

## 4. Build BOOT.BIN

BOOT.BIN contains three partitions: FSBL + bitstream + U-Boot, packed by `bootgen`.

### Pre-built components

`boot_parts/fsbl.elf` and `boot_parts/u-boot.bin` are already committed.
You only need to re-run bootgen when the bitstream changes.

### Step 1: Run bootgen

```bash
cd plutosky/src/boot_parts
$VIVADO/bin/bootgen -arch zynq -image fishball7020_rf.bif -o BOOT.bin -w on
```

The BIF file (`plutosky/src/boot_parts/fishball7020_rf.bif`):
```
the_ROM_image:
{
    [bootloader] fsbl.elf
    ../plutosky/src/fishball7020_rf/fishball7020_rf.runs/impl_1/system_top.bit
    [load=0x04000000, startup=0x04000000] u-boot.bin
}
```

- `[bootloader]`, marks the FSBL; the Zynq ROM loads it into OCM and runs it first
- `.bit` entry, FSBL programs this into the PL fabric; **must be uncompressed** (tezuka FSBL does not set `COMP_EN`)
- `[load=..., startup=...]`, raw binary without ELF headers; tells bootgen where to place and jump to U-Boot

**Expected output:**
```
[WARNING]: Partition fsbl.elf.0 range is overlapped with partition system_top.bit.0 memory range
[INFO]   : Bootimage generated successfully
```

The overlap warning is a Vivado 2022.1 cosmetic issue, the BOOT.BIN works correctly.

### Step 2: Verify the BOOT.BIN structure

```bash
$VIVADO/bin/bootgen -arch zynq -read plutosky/src/boot_parts/BOOT.bin
```

Should show three partitions: `fsbl.elf`, `system_top.bit`, `u-boot.bin`.

---

## 5. Deploy to the Board

Configure SSH access in `~/.ssh/config` (recommended) so you don't need to
pass `-i` on every command:

```
Host pluto-usb
    HostName 192.168.2.1
    User root
    IdentityFile ~/.ssh/<your_key>
```

### Copy BOOT.BIN to the SD card

`scp -O` works with the board's Dropbear SSH server (`-O` forces legacy SCP
protocol instead of SFTP, which Dropbear does not support):

```bash
scp -O plutosky/src/boot_parts/BOOT.bin pluto-usb:/boot/BOOT.bin.new

# Verify integrity
md5sum plutosky/src/boot_parts/BOOT.bin
ssh pluto-usb "md5sum /boot/BOOT.bin.new"

# Atomically swap in (keeps original as fallback)
ssh pluto-usb "cp /boot/BOOT.bin /boot/BOOT.bin.bak && mv /boot/BOOT.bin.new /boot/BOOT.bin && sync"
```

### Copy autorun.sh (if changed)

```bash
scp -O plutosky/src/board/autorun.sh pluto-usb:/mnt/jffs2/autorun.sh
ssh pluto-usb "chmod +x /mnt/jffs2/autorun.sh && sync"
```

---

## 6. Verify

**Cold-boot the board** (full power cycle, not just `reboot`). The FSBL must
re-read BOOT.BIN from the SD card.

```bash
# Run the AXI SPI probe from the host (sends devmem commands over SSH)
python3 plutosky/tests/test_spi.py
```

Expected: SPICR reads back 0x0000009E, CS toggles between ~3.3V and ~0V, SCK idles at ~3.3V (CPOL=1), MOSI follows the last bit of each byte sent.

### Confirm the right bitstream loaded

```bash
# FSBL configures PL from BOOT.BIN before Linux starts; state should read "operating"
ssh pluto-usb "cat /sys/class/fpga_manager/fpga0/state"

# AD9361 IIO device present confirms PL + driver init succeeded
ssh pluto-usb "ls /sys/bus/iio/devices/"
# Expected: iio:device0  iio:device1  (or similar)
```
