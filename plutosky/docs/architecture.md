# PlutoSky 7020: Architecture

This document covers the hardware, boot chain, and FPGA design decisions.
Read this first before reading the build guide.

---

## Table of Contents

1. [Hardware Overview](#1-hardware-overview)
2. [Signal Chain](#2-signal-chain)
3. [Boot Chain](#3-boot-chain)
4. [FPGA Block Design](#4-fpga-block-design)
5. [EMIO GPIO Mapping](#5-emio-gpio-mapping)
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
| Expansion | JP5 connector, 4× GPIO, power rails (5V, 3.3V, 1.8V), GND |

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

### GPIO path (our addition)

```
Linux userspace (gpioset / Python)
  │  /dev/gpiochip0 lines 71-74
  ▼
Zynq PS7 EMIO GPIO bank 2 (EMIO[17:20])
  │  gpio_o[17:20] → IOBUF.I
  │  gpio_t[17:20] → IOBUF.T (tristate control)
  ▼
IOBUF primitives in PL (Bank 13, LVCMOS33)
  │  Physical pads: V10, U9, U10, T9
  ▼
JP5 connector pins 7, 9, 11, 13
  │
  ▼
(future) iCESugar Pro ECP5 → SPI/parallel → LCD display
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
| `sys_ps7` | processing_system7 | Zynq PS7: ARM cores, DDR, MIO, EMIO GPIO |
| `axi_ad9361` | axi_ad9361 (ADI) | AD9361/AD9363 LVDS data interface + register map |
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

The Vivado-generated `system_wrapper` exposes `gpio_i/o/t[20:0]` as ports.
`system_top.v` adds:

1. **AD9363 GPIO IOBUF**, `ad_iobuf` for EMIO[13:0] (gpio_status, gpio_ctl, en_agc, resetb)
2. **Loopback for EMIO[16:14]**, `up_enable` and `up_txnrx` drive axi_ad9361 directly; bits [14] are unused
3. **Bank 13 IOBUFs**, Four individual `IOBUF` primitives for EMIO[17:20] → io_3v3_0..3 → JP5

---

## 5. EMIO GPIO Mapping

Zynq PS GPIO has three banks:
- **Bank 0**: MIO 0–31 (PS pins)
- **Bank 1**: MIO 32–53 (PS pins)
- **Bank 2**: EMIO 0–31 → `gpiochip0` lines 54–85
- **Bank 3**: EMIO 32–63 → `gpiochip0` lines 86–117

Our design uses 21 EMIO bits:

| EMIO bit | gpiochip0 line | Signal | Direction | Note |
|---|---|---|---|---|
| 0–7 | 54–61 | gpio_status[7:0] | Input | AD9363 CTRL_OUT[7:0] |
| 8–11 | 62–65 | gpio_ctl[3:0] | Output | AD9363 CTRL_IN[3:0] |
| 12 | 66 | gpio_en_agc | Output | AD9363 EN_AGC |
| 13 | 67 | gpio_resetb | Output | AD9363 RESET_B |
| 14 | 68 | (unused) | Loopback |   |
| 15 | 69 | up_enable | Output | axi_ad9361 TX enable |
| 16 | 70 | up_txnrx | Output | axi_ad9361 TX/RX select |
| 17 | 71 | io_3v3_0 | Bidirectional | JP5 pin 7, FPGA ball V10 |
| 18 | 72 | io_3v3_1 | Bidirectional | JP5 pin 9, FPGA ball U9 |
| 19 | 73 | io_3v3_2 | Bidirectional | JP5 pin 11, FPGA ball U10 |
| 20 | 74 | io_3v3_3 | Bidirectional | JP5 pin 13, FPGA ball T9 |

**Driving the JP5 pins from Linux:**
```bash
# Drive all HIGH (+3.3V)
gpioset gpiochip0 71=1 72=1 73=1 74=1

# Drive all LOW (0V)
gpioset gpiochip0 71=0 72=0 73=0 74=0
```

---

## 6. AXI Address Map

These addresses must match the tezuka device tree (`devicetree.dtb`) and the
`maia_sdr.ko` driver. Do not change them without also updating the DTB.

| Instance | Base address | Size | Connected to |
|---|---|---|---|
| `axi_ad9361` | 0x79020000 | 64 KB | AXI GP0 (CPU) |
| `axi_ad9361_adc_dma` | 0x7C400000 | 64 KB | AXI GP0 (CPU) |
| `axi_ad9361_dac_dma` | 0x7C420000 | 64 KB | AXI GP0 (CPU) |
| `maia_sdr` | 0x7C460000 | 64 KB | AXI GP0 (CPU) |
| `maia_sdr` spectrometer DMA |   | 512 MB | AXI HP1 (DMA master) |
| ADC/DAC DMAs |   | 512 MB | AXI HP2 (DMA master) |
| `maia_sdr` recorder DMA |   | 512 MB | AXI HP2 (DMA master) |

