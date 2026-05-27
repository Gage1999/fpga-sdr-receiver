# PlutoSky 7020: Architecture

This document covers the hardware, boot chain, and FPGA design decisions.
Read this first before reading the build guide.

---

## Table of Contents

1. [Hardware Overview](#1-hardware-overview)
2. [Signal Chain](#2-signal-chain)
3. [Boot Chain](#3-boot-chain)
4. [FPGA Block Design](#4-fpga-block-design)
5. [JP5 AXI SPI Link](#5-jp5-axi-spi-link)
6. [AXI Address Map](#6-axi-address-map)
7. [Design Decisions](#7-design-decisions)

---

## 1. Hardware Overview

**Board**: PlutoSky 7020, internally called "fishball7020"

| Component | Detail |
|---|---|
| SoC | Xilinx XC7Z020-2CLG400I (Zynq-7000) |
| Package | CLG400, 400-ball BGA, 54 MIO pins |
| RF IC | Analog Devices AD9363 (AD9361-compatible) |
| RF interface | 6-lane LVDS, up to 61.44 MSPS (30.72 MSPS complex) |
| DDR3 | 32-bit wide (two 16-bit chips), 533 MHz |
| FPGA banks | Bank 34 (2.5V HR), Bank 35 (1.8V HR), Bank 13 (3.3V HR) |
| Flash | QSPI on MIO 1–6, JFFS2 filesystem on mtd2 |
| Storage | MicroSD card, FAT partition at /boot |
| USB | USB 2.0 OTG, reset on MIO 46, gadget IP 192.168.2.1 |
| Expansion | JP5 connector, AXI SPI signals, power rails (5V, 3.3V, 1.8V), GND |

**Important CLG400 differences from the stock ADI reference design** (`adrv9364z7020/ccbob_lvds`,
which targets the `fbg676` package on a carrier board):

| Parameter | ADI reference (fbg676) | fishball7020 (clg400) |
|---|---|---|
| PCW_PACKAGE_NAME | fbg676 | clg400 |
| Bank 0 voltage | 1.8V | 3.3V |
| USB reset MIO | MIO 7 | MIO 46 |
| Ethernet | ENET0 + ENET1 | none |
| SPI1 | enabled | disabled |
| DDR bus width | 32-bit | 32-bit |
| DDR delays | different | from tezuka HWH |

All of these differences are applied in `system_bd.tcl`.

---

## 2. Signal Chain

### RF receive path (current focus)

```
Antenna
  │  RF signal (137 MHz for NOAA APT, or any frequency in AD9363 range)
  ▼
AD9363 RF front end
  │  LVDS 6-lane data bus (12 bits I + 12 bits Q at up to 61.44 MSPS)
  ▼
axi_ad9361 (PL core, ADI IP)
  │  AXI-Stream: adc_data_i0[15:0], adc_data_q0[15:0]  (16-bit signed)
  ▼
CS8/CS16 IQ mux (ad_bus_mux)
  │  Selects 8-bit CS8 or 16-bit CS16 mode per libiio request
  ▼
util_cpack2 (AXI-Stream packer)
  │  Packs I/Q channels into a single AXI-Stream
  ▼
axi_ad9361_adc_dma (AXI DMAC)
  │  DMA to DDR3 via AXI HP2 slave port
  ▼
Linux kernel / libiio (PS, ARM Cortex-A9)
  │  /dev/iio:device0, IQ samples available to userspace
  ▼
libiio userspace (e.g. iio_readdev, Python)
```

### maia-sdr spectrometer path (parallel, for web UI)

```
axi_ad9361 → 12-bit slice → maia_sdr IP (spectrometer)
  │  DMA to DDR3 via AXI HP1 slave port
  ▼
maia_sdr.ko driver → /dev/maia-sdr-spectrometer
  │  WebSocket stream
  ▼
maia-httpd (web server) → browser waterfall display
```

### JP5 SPI path to iCeSugar Pro

```
Linux userspace (`icesugar_stream`, `test_icesugar`)
  │  /dev/mem mmap of AXI SPI registers at 0x7C440000
  ▼
AXI Quad SPI (`axi_spi_jp5`)
  │  8-bit SPI transfers, Mode 3, manual CS
  ▼
JP5 pins, Bank 13 LVCMOS33
  │  SCK, MOSI, CS; MISO present but unused by current IQ stream
  ▼
iCeSugar Pro CS0 SPI receiver
  │
  ▼
FFT/waterfall and FM demod/audio
```

---

## 3. Boot Chain

```
Power on
  │
  ▼
FSBL (First Stage Bootloader), from BOOT.BIN partition 0
  │  Initializes PS: DDR, PLL, MIO pin mux, clock gating
  │  Programs PL with bitstream from BOOT.BIN partition 1
  │  Hands off to U-Boot
  ▼
U-Boot, from BOOT.BIN partition 2 (load/exec 0x04000000)
  │  Reads uEnv.txt from SD card FAT partition
  │  Loads uImage (kernel) and devicetree.dtb from SD card
  ▼
Linux kernel (armv7l, SMP, PREEMPT)
  │  Initramfs rootfs (read-only ramdisk, cannot brick the OS)
  │  Drivers load: cf_axi_adc, axi-ad9361, maia_sdr, dma-axi-dmac
  │  AD9361 initializes + runs dig_tune (LVDS calibration)
  ▼
Init scripts
  │  S20jffs2: mounts mtd2 → /mnt/jffs2
  │  S98autostart: sources /mnt/jffs2/autorun.sh (if present)
  ▼
autorun.sh
  │  Installs SSH authorized key from /mnt/jffs2/ssh/authorized_keys
  ▼
Board ready, SSH available at 192.168.2.1
```

**Key implication**: The PL is configured by the FSBL before Linux even starts.
By baking our bitstream into BOOT.BIN, the Bank 13 IOBUFs are active from the
moment the kernel boots. No runtime bitstream loading or rebooting required.

**Rootfs is a ramdisk**: Any writes outside `/mnt/jffs2/` are lost on reboot.
The only persistent storage is:
- SD card FAT partition (`/boot`), kernel, DTB, BOOT.BIN
- JFFS2 flash (`/mnt/jffs2`), autorun.sh, SSH keys, custom scripts (~896 KB total)

---

## 4. FPGA Block Design

The design is based on **maia-hdl `pluto_iio`** (`maia-sdr/maia-hdl/projects/pluto_iio/`)
with adaptations for the fishball7020's LVDS RF interface and CLG400 PS7 configuration.

### IP blocks

| Instance | IP | Description |
|---|---|---|
| `sys_ps7` | processing_system7 | Zynq PS7: ARM cores, DDR, MIO, control pins |
| `axi_ad9361` | axi_ad9361 (ADI) | AD9361/AD9363 LVDS data interface + register map |
| `axi_spi_jp5` | axi_quad_spi | JP5 SPI master for iCeSugar IQ/display stream |
| `maia_sdr` | maia_sdr_maia_iio | Spectrometer, recorder, IQ correction (maia-hdl) |
| `axi_ad9361_adc_dma` | axi_dmac (ADI) | ADC → DDR3 DMA (HP2 slave) |
| `axi_ad9361_dac_dma` | axi_dmac (ADI) | DDR3 → DAC DMA (HP2 slave) |
| `maia_sdr_clk` | clk_wiz | MMCM: 62.5 / 125 / 187.5 MHz for maia_sdr |
| `cpack` / `tx_upack` | util_cpack2 / util_upack2 | IQ channel pack/unpack |
| `muxcs8` / `muxcs8_tx_*` | ad_bus_mux | CS8/CS16 IQ mode selection |
| `sys_rstgen` | proc_sys_reset | Reset sequencing |
| `sys_concat_intc` | xlconcat | 16-port interrupt concatenator → IRQ_F2P |

### Source files

| File | Role |
|---|---|
| `system_bd.tcl` | Tcl block design script, creates all IPs, connections, addresses |
| `system_top.v` | Top-level Verilog, wraps BD, instantiates Bank 13 IOBUFs |
| `system_constr.xdc` | Pin constraints, PACKAGE_PIN, IOSTANDARD, DIFF_TERM, DRIVE |
| `system_project.tcl` | Vivado project creation and build launch |

### What `system_top.v` adds on top of the BD wrapper

The Vivado-generated `system_wrapper` exposes AD9363 control pins and JP5 SPI
ports. `system_top.v` connects those ports to the board pins.
`system_top.v` adds:

1. **AD9363 control IOBUF**, `ad_iobuf` for status/control/en_agc/resetb pins
2. **Loopback for internal control**, `up_enable` and `up_txnrx` drive axi_ad9361 directly
3. **JP5 SPI outputs**, SCK/MOSI/CS from `axi_spi_jp5` routed to Bank 13 pins

---

## 5. JP5 AXI SPI Link

The current PlutoSky bitstream instantiates `axi_quad_spi` as `axi_spi_jp5` and
maps it into the CPU AXI address space.

AXI SPI configuration:

| Parameter | Value |
|---|---|
| IP | Xilinx AXI Quad SPI |
| Instance | `axi_spi_jp5` |
| Base address | `0x7C440000` |
| AXI clock | 100 MHz |
| SCK ratio | 8 |
| SCK rate | about 12.5 MHz |
| SPI mode | Mode 3, CPOL=1, CPHA=1 |
| Transfer width | 8 bits |
| Slave selects | 1 |

Current JP5 pin use:

| JP5 pin | FPGA ball | SPI signal | Direction |
|---|---|---|---|
| 7 | V10 | SCK | PlutoSky to iCeSugar |
| 9 | U9 | MOSI | PlutoSky to iCeSugar |
| 13 | T9 | CS | PlutoSky to iCeSugar |
| 11 | U10 | MISO | iCeSugar to PlutoSky, unused for current IQ stream |

The current userspace code sends one IQ sample as four MSB-first bytes:

```text
[I15..I0][Q15..Q0]
```

`plutosky/tests/test_spi_reg.c` verifies the AXI SPI register block.
`plutosky/tests/test_icesugar.c` and `plutosky/src/icesugar_stream.c` use the
controller to send synthetic or live IQ to the iCeSugar Pro.

---

## 6. AXI Address Map

These addresses must match the tezuka device tree (`devicetree.dtb`) and the
`maia_sdr.ko` driver. Do not change them without also updating the DTB.

| Instance | Base address | Size | Connected to |
|---|---|---|---|
| `axi_ad9361` | 0x79020000 | 64 KB | AXI GP0 (CPU) |
| `axi_ad9361_adc_dma` | 0x7C400000 | 64 KB | AXI GP0 (CPU) |
| `axi_ad9361_dac_dma` | 0x7C420000 | 64 KB | AXI GP0 (CPU) |
| `axi_spi_jp5` | 0x7C440000 | 64 KB | AXI GP0 (CPU) |
| `maia_sdr` | 0x7C460000 | 64 KB | AXI GP0 (CPU) |
| `maia_sdr` spectrometer DMA |   | 512 MB | AXI HP1 (DMA master) |
| ADC/DAC DMAs |   | 512 MB | AXI HP2 (DMA master) |
| `maia_sdr` recorder DMA |   | 512 MB | AXI HP2 (DMA master) |
