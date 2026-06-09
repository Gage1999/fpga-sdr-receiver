# Inter-Device Interface

This document describes the board-to-board links between the PlutoSky 7020, the
iCeSugar Pro, and the Pico 2W.

The final demo path is FM:

```text
PlutoSky AD9363 -> JP5 TLV IQ stream -> iCeSugar Pro -> LCD + I2S audio
Pico touch UI   -> UI SPI frames     -> iCeSugar Pro -> JP5 command relay
```

## Boards And Roles

| Board | Role |
|---|---|
| PlutoSky 7020 | RF front end, AD9363 control, FM/GOES/ADS-B userspace runtime |
| iCeSugar Pro | ECP5 display/audio fabric, TLV receiver, Pico UI parser |
| Pico 2W | Touch UI state machine and Goodix touch interface |

## Physical Links

| Link | Master | Signals | Payload |
|---|---|---|---|
| PlutoSky JP5 -> iCeSugar | PlutoSky Zynq | SCK, MOSI, CS | TLV IQ/result stream |
| iCeSugar -> PlutoSky JP5 | PlutoSky clocks, iCeSugar drives | MISO | Radio command backchannel |
| Pico -> iCeSugar | Pico SPI0 | SCK, MOSI, CS | Shared `0xA5` UI frames |
| Pico -> touch panel | Pico I2C0 | SDA, SCL | Goodix GT911 touch data |

## JP5 SPI Link

The PlutoSky design instantiates a Xilinx AXI Quad SPI controller at
`0x7C440000`. It runs SPI mode 3, 8-bit transfers, MSB-first, at about
12.5 MHz with the current SCK divider.

| JP5 pin | PlutoSky ball | iCeSugar signal | Direction |
|---|---|---|---|
| 7 | V10 | `spi_clk` | PlutoSky -> iCeSugar |
| 9 | U9 | `mosi` | PlutoSky -> iCeSugar |
| 13 | T9 | `cs` | PlutoSky -> iCeSugar |
| 11 | U10 | `miso` | iCeSugar -> PlutoSky |

## PlutoSky To iCeSugar TLV Stream

JP5 MOSI uses a simple TLV frame:

```text
byte 0      type
byte 1..2   payload length, big-endian
byte 3..    payload
```

| Type | Name | Payload | ECP5 status |
|---:|---|---|---|
| `0x00` | `TLV_IQ` | Repeated signed CS16 `[I15..I0][Q15..Q0]` | Active final path |
| `0x01` | `TLV_IMAGE_ROW` | GOES/LRIT image row data | Reserved extension path |
| `0x02` | `TLV_OBJECT_LIST` | ADS-B aircraft list | Reserved extension path |

The final iCeSugar bitstream routes `TLV_IQ` through `spi_frame_rx`,
`tlv_demux`, and `tlv_iq_sink`. IQ feeds both the FFT/waterfall display path and
the FM demod/audio path.

At 12.5 MHz SCK, CS16 IQ uses 32 SPI bits per complex sample, giving about
390k complex samples/s of raw link budget.

## Pico To iCeSugar UI Frames

The Pico sends shared wire-protocol frames to the ECP5:

```text
0xA5 opcode len_lo len_hi payload... crc_lo crc_hi
```

Rules:

- `0xA5` is frame magic and is not included in the CRC.
- Length and CRC are little-endian.
- CRC is CRC16-CCITT, init `0xFFFF`, polynomial `0x1021`.
- CRC covers `opcode`, `len_lo`, `len_hi`, and the payload.

Important opcodes:

| Opcode | Name | Purpose |
|---:|---|---|
| `0x01` | `OP_FULL_STATE` | Full packed `ui_state_t` |
| `0x02` | `OP_PARTIAL_STATE` | Offset/length patches into `ui_state_t` |
| `0x04` | `OP_HEARTBEAT` | Link liveness |
| `0x06` | `OP_RADIO_COMMAND` | ECP5-to-Pluto command relay |

The iCeSugar parser validates version and CRC before applying display fields.
The active display path uses:

| Field | Use |
|---|---|
| `layout` / `demod` | Mode labels and display layout selection |
| `volume` / mute flag | Audio gain and status bar |
| `freq_hz` | Frequency display and Pluto retune command |
| `span_hz_log2` | FFT input decimation / spectrum span |
| `touch_x`, `touch_y`, `active_button` | Touch overlay and button highlight |
| `rds_text` | Status-line text fallback |

## Command Backchannel

The ECP5 applies volume/mute locally and relays radio commands back to PlutoSky
over JP5 MISO. Pluto clocks the link, so the ECP5 shifts command bytes whenever
normal TLV traffic or a backchannel poll provides SCK edges.

Relay frame payload:

```text
cmd:u8 arg:u32_le
```

| Command | Meaning |
|---|---|
| `SET_MODE` | Switch active runtime mode: FM, GOES, ADS-B |
| `SET_FREQ` | Retune FM center frequency |
| `SET_VOLUME` | Ignored by PlutoSky; handled by ECP5 audio |

PlutoSky receives these frames in `plutosky/src/main.c` (`sdr_main`).

## Mode Status

| Mode | Demodulation location | Link payload | Public status |
|---|---|---|---|
| FM | iCeSugar Pro | `TLV_IQ` | Final demo path |
| GOES | PlutoSky | `TLV_IMAGE_ROW` | Runtime/protocol extension path |
| ADS-B | PlutoSky | `TLV_OBJECT_LIST` | Runtime/protocol extension path |
| RDS | iCeSugar Pro | Derived from FM MPX | Standalone RTL modules retained for future integration |

FM is the showcase path. GOES and ADS-B remain documented protocol modes so the
repo has a clear extension route without presenting unfinished renderers as part
of the default build.
