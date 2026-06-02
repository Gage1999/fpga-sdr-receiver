# Pico-to-PlutoSky Control Backchannel

This note tracks the control path for changing receiver mode, FM frequency, and
FPGA audio volume from the Pico UI.

## Current Flow

```text
Pico UI
  -> shared 0xA5 UI frame over Pico SPI
  -> iCeSugar `spi_ui_cmd_rx.sv`
  -> `control_regs.sv` local FPGA state
  -> `spi_backchannel.sv` JP5 MISO relay
  -> PlutoSky `sdr_main`
  -> AD9363 / application mode configuration
```

The IQ/result path remains:

```text
PlutoSky `sdr_main`
  -> JP5 SPI MOSI TLV stream
  -> iCeSugar TLV demux
  -> FM demod/waterfall/audio, or debug capture for GOES/ADS-B result TLVs
```

## Pico to FPGA

The Pico sends shared `wire_protocol.c` frames:

```text
0xA5 opcode len_lo len_hi payload... crc_lo crc_hi
```

CRC coverage is `[opcode, len_lo, len_hi, payload...]`, using CRC16-CCITT
(`0xFFFF` init, `0x1021` polynomial).

`icesugar_pro/src/spi_ui_cmd_rx.sv` currently accepts `OP_FULL_STATE` and
`OP_PARTIAL_STATE`. It extracts the fields needed for radio/audio control:

| UI state field | FPGA command |
|---|---|
| `demod` | `RADIO_CMD_SET_MODE` |
| `volume` | `RADIO_CMD_SET_VOLUME` |
| `flags[0]` mute | `RADIO_CMD_SET_VOLUME` arg bit 8 |
| `freq_hz` | `RADIO_CMD_SET_FREQ` |

The Pico mode button cycles only through modes currently supported by the radio
path:

```text
FM (0) -> GOES (2) -> ADS-B (3) -> FM (0)
```

AM (`1`) remains in the shared UI enum, but it is not selected by the Pico mode
button and is ignored by the FPGA command parser.

## FPGA Commands

`icesugar_pro/src/control_regs.sv` decodes:

| Command | ID | Argument |
|---|---:|---|
| `RADIO_CMD_SET_MODE` | `0x01` | `arg[2:0]`: FM=`0`, GOES=`2`, ADS-B=`3` |
| `RADIO_CMD_SET_VOLUME` | `0x02` | `arg[7:0]` volume, `arg[8]` mute |
| `RADIO_CMD_SET_FREQ` | `0x03` | FM frequency in Hz |

Volume and mute are applied locally in the FPGA audio path. Mode and frequency
also need to reach Pluto because Pluto owns the AD9363 LO and the active
receiver application.

## FPGA to PlutoSky Relay

JP5 is controlled by Pluto as the SPI master. The FPGA can only return bytes
while Pluto clocks SCK, so `spi_backchannel.sv` shifts command frames on JP5
MISO during normal MOSI traffic.

Relay frame:

```text
0xA5 OP_RADIO_COMMAND len_lo len_hi cmd arg[7:0] arg[15:8] arg[23:16] arg[31:24] crc_lo crc_hi
```

For the current radio command relay:

```text
OP_RADIO_COMMAND = 0x06
LEN = 5
payload = cmd:u8, arg:u32 little-endian
```

When no command is pending, the FPGA shifts `0x00`.

Current FPGA limitation: the relay is a one-command mailbox. A small FIFO or
latest-value coalescing should replace this before treating rapid UI changes as
lossless.

## PlutoSky Runtime

The active combined runtime is `plutosky/src/main.c`, built as `sdr_main`.
`plutosky/Makefile` now points `all` and `radio-run` at this runtime.

`sdr_main`:

1. Sends TLV packets on JP5 MOSI.
2. Drains AXI SPI RX while transmitting so MISO command bytes are not lost during
   long TLV packets.
3. Parses shared `OP_RADIO_COMMAND` frames from the FPGA.
4. Applies `SET_MODE` by restarting the active FM/GOES/ADS-B flow.
5. Applies `SET_FREQ` by restarting the FM flow with the new LO.
6. Logs `SET_VOLUME`; volume/mute are already handled locally by the FPGA.
7. Polls the backchannel in GOES/ADS-B modes by sending a zero-length TLV when
   no real TLV traffic has created SPI clocks.

## Bring-Up Checks

1. Flash the current iCeSugar bitstream.
2. Run `make radio-run` from `plutosky/`.
3. Press Pico UI controls and confirm Pluto logs:

```text
[bchan] mode -> FM/GOES/ADS-B
[bchan] freq -> <hz> Hz
[bchan] volume=<n> mute=<0|1> (handled by ECP5)
```

4. If commands are not logged, verify JP5 MISO with a logic analyzer first. The
   iCeSugar-side MISO site is currently assumed to be `T3`.

## Remaining Work

1. Verify the JP5 MISO physical mapping.
2. Replace the FPGA one-command mailbox with a FIFO or latest-value coalescer.
3. Add a backchannel framing testbench for `spi_backchannel.sv`.
4. Make LCD status text use live `mode`, `freq_hz`, `volume`, and `mute`.
5. Render GOES `TLV_IMAGE_ROW` packets into SDRAM/framebuffer.
6. Render ADS-B `TLV_OBJECT_LIST` packets through object RAM/compositor logic.
