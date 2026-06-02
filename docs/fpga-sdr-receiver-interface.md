# Triad Receiver - Inter-Device Interface (Zynq <-> ECP5 <-> Pico)

**Audience:** whoever wires the three boards together and writes the link
endpoints on each side.

**Scope:** the physical links between the PlutoSky (Zynq), the iCESugar-Pro
(ECP5), and the Pico 2W: pinout, the IQ/result stream format, the Pico
UI/control protocol, and where each mode is demodulated.

Related docs:

- `plutosky/docs/architecture.md` - inside the Zynq.
- `docs/fpga-sdr-receiver-architecture.md` - target ECP5 SDRAM/framebuffer
  architecture.
- `docs/fpga-sdr-receiver-harness.md` - host model of the Pico-to-ECP5 UI path.

> **Current status.** The integrated iCESugar bitstream uses the TLV JP5 stream,
> SDRAM-backed LCD/waterfall path, FM demod/audio path, Pico shared-frame parser,
> and a JP5 MISO radio-command relay. Pluto's current combined runtime is
> `plutosky/src/main.c` (`sdr_main`), which receives relay commands and can
> restart the active FM/GOES/ADS-B flow. FM IQ streaming and audio are the proven
> end-to-end path. GOES and ADS-B Pluto-side code can emit compact TLV result
> packets, but the ECP5 still only debug-captures those non-IQ packet types;
> image-row/object-list rendering is not wired yet.

Source-of-truth files:

- ECP5: `icesugar_pro/src/top.sv`, `spi_ui_cmd_rx.sv`, `spi_backchannel.sv`,
  `control_regs.sv`, `tlv_demux.sv`, `tlv_capture_sink.sv`, and
  `icesugar_pro/top.lpf`.
- Pluto: `plutosky/src/main.c`, `goes_stream.c`, `goes_lrit.c`,
  `ads_stream.c`, and `plutosky/Makefile`.
- Shared protocol: `shared/include/wire_protocol.h`,
  `shared/src/wire_protocol.c`, and `shared/include/ui_state.h`.

## 1. System Shape

The original proposal had Pluto-to-ECP5 SPI for IQ, Pico-to-ECP5 SPI for UI
state, and a Pico-to-Pluto UART for tuning. The built design uses the ECP5 as
the hub:

1. FM demodulation, audio, FFT, and waterfall run on the ECP5 from Pluto IQ.
2. The Pico talks only to the ECP5 using the shared `0xA5` UI frame protocol.
3. The ECP5 forwards radio commands to the Pluto over JP5 MISO using shared
   `OP_RADIO_COMMAND` frames.
4. GOES and ADS-B are Pluto-side workloads; their compact results are intended
   to cross JP5 as TLV packets.

```text
                       JP5 SPI MOSI: TLV IQ/results
   Antenna -> PlutoSky -------------------------------> iCESugar -> LCD/audio
                  ^                                         ^
                  | JP5 SPI MISO: radio commands            |
                  +-----------------------------------------+

   Pico 2W ---------------- SPI UI state frames ------------> iCESugar
      |
      +--------------------- I2C touch ---------------------> touch controller
```

## 2. Links

| Link | Endpoint | Master | Wires | Carries |
|---|---|---|---|---|
| Pluto -> ECP5 | JP5 CS0 TLV receiver | Zynq AXI Quad SPI | SCK, MOSI, CS | `TLV_IQ`, `TLV_IMAGE_ROW`, `TLV_OBJECT_LIST` |
| ECP5 -> Pluto | JP5 MISO relay | Zynq clocks, ECP5 drives data | MISO | shared `OP_RADIO_COMMAND` frames |
| Pico -> ECP5 | Pico UI SPI parser | Pico SPI0 | SCK, MOSI, CS | shared `0xA5` UI state frames |

The Pico link is MOSI-only. JP5 MISO is now driven by the ECP5 for the relay.
The iCeSugar-side JP5 MISO site is currently assumed to be `T3`; verify this
with a logic analyzer or continuity check before treating it as final.

### JP5 SPI

Zynq master: `axi_spi_jp5` (`axi_quad_spi`) at `0x7C440000`, SPI mode 3
(CPOL=1, CPHA=1), 8-bit transfers, MSB-first.

| JP5 pin | Zynq ball | ECP5 pin/site | Signal | Direction |
|---|---|---|---|---|
| 7 | V10 | D7 (`spi_clk`) | SCK | Zynq -> ECP5 |
| 9 | U9 | D8 (`mosi`) | MOSI | Zynq -> ECP5 |
| 13 | T9 | D9 (`cs`) | CS | Zynq -> ECP5 |
| 11 | U10 | T3 (`miso`, assumed) | MISO | ECP5 -> Zynq |

### Pico UI SPI

Pico master, SPI mode 0 (CPOL=0, CPHA=0), 8-bit transfers, MSB-first. CS idles
high and one complete shared wire frame is sent per CS-low window.

| Signal | Pico 2W | iCESugar-Pro header | ECP5 pin |
|---|---|---|---|
| SCK | GP18 / SPI0 SCK | P5 | D12 (`spi_clk_pico`) |
| MOSI | GP19 / SPI0 TX | P5 | C11 (`mosi_pico`) |
| CS | GP17 / GPIO output | P5 | D13 (`cs1`) |
| GND | any GND | P5 | GND |

## 3. Pluto -> ECP5 TLV Stream

The JP5 MOSI stream is TLV framed:

```text
byte 0      type
byte 1..2   length, big-endian payload byte count
byte 3..    payload
```

Types currently used:

| Type | Name | Payload |
|---:|---|---|
| `0x00` | `TLV_IQ` | repeated `[I15..I0][Q15..Q0]`, signed CS16 |
| `0x01` | `TLV_IMAGE_ROW` | GOES/LRIT row bytes from Pluto-side decoder |
| `0x02` | `TLV_OBJECT_LIST` | ADS-B aircraft list from Pluto-side decoder |

`spi_frame_rx` receives bytes, `tlv_demux` routes payloads, and `tlv_iq_sink`
reassembles IQ samples for FFT/waterfall and FM demod. Image-row and object-list
packets are currently counted/captured for debug only.

At roughly 12.5 MHz SCK, CS16 IQ costs 32 SPI bits per complex sample, or about
390 k complex samples/s. The FM path is sized around that budget.

## 4. Pico -> ECP5 UI Protocol

The canonical Pico-to-ECP5 protocol is implemented in `shared/src/wire_protocol.c`
and declared in `shared/include/wire_protocol.h`.

```text
+------+--------+----------+-------------+----------+
| 0xA5 | OPCODE | LEN (LE) |   PAYLOAD   | CRC (LE) |
+------+--------+----------+-------------+----------+
```

Rules:

- `0xA5` is the frame magic and is not included in the CRC.
- `LEN` is the payload length in bytes, little-endian.
- CRC is CRC16-CCITT, init `0xFFFF`, polynomial `0x1021`, no reflection.
- CRC coverage is `[OPCODE, LEN_LO, LEN_HI, payload...]`.
- Maximum payload is `WIRE_MAX_PAYLOAD` = 1024 bytes.

Opcodes:

| Opcode | Name | Payload | Purpose |
|---:|---|---|---|
| `0x01` | `OP_FULL_STATE` | full packed `ui_state_t` | periodic full UI state |
| `0x02` | `OP_PARTIAL_STATE` | repeated `{offset:u16, len:u16, bytes[len]}` | UI state diff |
| `0x03` | `OP_TOUCH_EVENT` | `{x:u16, y:u16, kind:u8}` | optional touch echo/debug |
| `0x04` | `OP_HEARTBEAT` | empty | link liveness |
| `0x05` | `OP_SPECTRUM_BINS` | `256 * u16` | optional spectrum-bin fast path |
| `0x06` | `OP_RADIO_COMMAND` | `{cmd:u8, arg:u32}` | ECP5 -> Pluto radio relay |

The Pico currently cycles only through supported receiver modes:

```text
FM (0) -> GOES (2) -> ADS-B (3) -> FM (0)
```

`ui_state_t` is the payload contract for `OP_FULL_STATE`, and partial updates
use byte offsets into the same packed struct. The active iCE display parser
(`icesugar_pro/src/ui_wire_rx.sv`) validates CRC and applies these
display-relevant fields:

| Offset | Field | Type | Display use |
|---:|---|---|---|
| `0` | `version` | `u8` | Must equal `UI_STATE_VERSION` (`3`) or the frame is dropped. |
| `1` | `layout` | `u8` | `0` spectrum/waterfall, `1` GOES, `2` ADS-B. |
| `2` | `demod` | `u8` | `0` FM, `1` AM, `2` GOES, `3` ADS-B; drives the status label and mode button text. |
| `3` | `volume` | `u8` | `0..100`, rendered as the status volume bar. The separate command parser scales this to `0..255` for audio gain. |
| `4` | `freq_hz` | `u32 le` | Center frequency in Hz. |
| `8` | `span_hz_log2` | `u16 le` | Visible RF span request is `1 << span_hz_log2` Hz; Pico clamps it to `13..18`, and the active FM/AM bitstream maps it to the spectrum FFT input decimator. |
| `11` | `flags` | `u8` | Bit 0 is mute, bit 2 is touch-active overlay. |
| `12` | `touch_x` | `u16 le` | Touch crosshair X, low 10 bits used. |
| `14` | `touch_y` | `u16 le` | Touch crosshair Y, low 10 bits used. |
| `16` | `active_button` | `u8` | Button highlight; `0xFF` means none. |
| `20` | `rds_text[32]` | `char[32]` | Active FPGA parser captures the first 24 printable characters; the status row renders the first 20 left-aligned to avoid the right-side buttons. |
| `52` | `spectrum_bins[256]` | `u16 le[256]` | Host/model path. The active FM bitstream writes spectrum bins from the FPGA FFT instead. |

FM/AM zoom uses `span_hz_log2`. The spectrum overlay displays the current
visible band as `LLL.lll-RRR.rrrMHz`, computed as
`freq_hz ± (1 << span_hz_log2) / 2`. The active FM/AM bitstream keeps the
display density fixed at 256 FFT bins and changes the FFT input rate before
`fft256`: narrower spans use more IQ decimation, so Hz/bin changes while
pixels/bin stays constant. The waterfall history is not rewritten on zoom
changes; existing SDRAM rows keep their previous scale and only new rows use
the current DSP span.

| `span_hz_log2` | Nominal RF span | FFT input decimation | Display FFT bins |
|---:|---:|---:|---:|
| `18` | 262 kHz | 1 | 256 |
| `17` | 131 kHz | 2 | 256 |
| `16` | 65 kHz | 4 | 256 |
| `15` | 33 kHz | 8 | 256 |
| `14` | 16 kHz | 16 | 256 |
| `13` | 8 kHz | 32 | 256 |

Bring-up heartbeat frame:

```text
A5 04 00 00 5C 10
```

AM (`1`) remains in `ui_state.h` for the shared UI model, but it is not selected
by the Pico mode button and is ignored by the FPGA radio command parser.

## 5. ECP5 Pico Parser and Radio Commands

`top.sv` instantiates two CS1 parsers against the same `0xA5` wire frames:

- `spi_ui_cmd_rx.sv` extracts only the fields that should become radio/audio
  commands.
- `ui_wire_rx.sv` keeps the display state fields used by the shader, RDS line,
  touch overlay, and spectrum span.

The old bring-up shim is still kept as source for electrical SPI smoke tests,
but `top.sv` no longer instantiates it.

| UI field | FPGA command |
|---|---|
| `demod` | `RADIO_CMD_SET_MODE` |
| `volume` | `RADIO_CMD_SET_VOLUME` |
| `flags[0]` mute | `RADIO_CMD_SET_VOLUME` arg bit 8 |
| `freq_hz` | `RADIO_CMD_SET_FREQ` |

Command arguments:

| Command | ID | Argument |
|---|---:|---|
| `RADIO_CMD_SET_MODE` | `0x01` | FM=`0`, GOES=`2`, ADS-B=`3` |
| `RADIO_CMD_SET_VOLUME` | `0x02` | `arg[7:0]` scaled `0..255` volume, `arg[8]` mute |
| `RADIO_CMD_SET_FREQ` | `0x03` | FM frequency in Hz |

`control_regs.sv` applies volume/mute locally for ECP5 audio. `spi_backchannel.sv`
queues relay frames for Pluto. The current relay is a one-command mailbox, not
the final small FIFO.

## 6. ECP5 Internal Dataflow

```text
JP5 SPI -> spi_frame_rx -> byte FIFO -> tlv_demux -> tlv_iq_sink
                                                        |
                                                        +-> spectrum_zoom_decimator -> fft256
                                                        |                             |
                                                        |                             +-> spectrum_bin_ram
                                                        |                             +-> waterfall row expand -> SDRAM compositor
                                                        |
                                                        +-> FM demod -> I2S -> PCM5102

Pico SPI -> spi_ui_cmd_rx -> control_regs -> local audio state
                                      |
                                      +-> spi_backchannel -> JP5 MISO
         -> ui_wire_rx -> ui_status_prepare -> pixel_shader_top

TLV_IMAGE_ROW / TLV_OBJECT_LIST -> tlv_capture_sink debug counters/capture
```

The FM waterfall/LCD path is SDRAM-backed in the integrated top. The SDRAM
controller, arbiter, startup framebuffer clear, scan-out line cache, and
waterfall compositor are instantiated. GOES image rows and ADS-B object lists do
not yet feed that compositor.

The active display build uses SDRAM scan-out for the waterfall framebuffer.
`ui_wire_rx` currently stores only the fields needed by the live status bar,
buttons, touch overlay, RDS text, and FM/AM zoom. Full 1 KB
double-buffered UI shadow RAM is still the target architecture for image-mode
payloads and broader state surfaces.

`spectrum_zoom_decimator.sv` is the first-pass DSP-side zoom block. It keeps
all 256 FFT bins on screen by averaging/decimating the FFT input for narrower
requested spans. It is not a full frequency-translating DDC or FIR channelizer;
center-frequency shifts rely on the Pico command relay retuning the Pluto LO.

## 7. Demod Placement and Mode Status

| Mode | Demod on | Crosses JP5 as | Status |
|---|---|---|---|
| FM | ECP5 | `TLV_IQ` raw IQ | built/proven; FFT zoom uses the ECP5 decimator |
| AM | not wired | `TLV_IQ` raw IQ | spectrum/zoom display path exists; AM audio demod is not implemented |
| FM RDS metadata | Pluto | compact UI/text metadata | display slot modeled; status row renders left-aligned text with no static prefix |
| GOES HRIT | Pluto | `TLV_IMAGE_ROW` decoded rows | Pluto decoder/transport started; ECP5 render path not wired |
| ADS-B | Pluto | `TLV_OBJECT_LIST` aircraft list | Pluto decoder/transport started; ECP5 render path not wired |

Open code gaps:

1. Verify JP5 MISO physical mapping (`T3` on iCeSugar side).
2. Add a real FPGA relay FIFO or latest-value coalescing for command bursts.
3. Replace the zoom mock with a proper DDC/FIR path if narrow-span alias control
   matters on hardware.
4. Render `TLV_IMAGE_ROW` into SDRAM/framebuffer for GOES.
5. Render `TLV_OBJECT_LIST` through object RAM/compositor/pixel shader for ADS-B.
6. Implement the full double-buffered UI state shadow RAM if the LCD shader
   should follow all Pico UI state directly.

## 8. Antennas

FM, GOES HRIT, and ADS-B need different antenna setups. The current plan is a
manual antenna swap at RX1 rather than an RF switch. The LCD/UI should eventually
prompt before moving into a mode that expects a different antenna.
