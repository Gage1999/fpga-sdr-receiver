# Triad Receiver — Inter-Device Interface (Zynq ↔ ECP5 ↔ Pico)

**Audience:** whoever wires the three boards together and writes the link
endpoints on each side.
**Scope:** the physical links between the PlutoSky (Zynq), the iCESugar-Pro
(ECP5), and the Pico 2W — pinout, the IQ stream format, the command protocol,
and where each mode is demodulated. Sits between the per-device docs:

- `plutosky/docs/architecture.md` — inside the Zynq (now §5 *JP5 AXI SPI Link*).
- `docs/fpga-sdr-receiver-architecture.md` — inside the ECP5 (the full SDRAM-
  backed renderer design; the *target*, not all of it built yet).
- `docs/fpga-sdr-receiver-harness.md` — the host model of the Pico↔ECP5 UI path.

> **Status (what's actually built).** The current bitstream implements **FM
> only**: Pluto streams raw IQ over JP5 SPI; the ECP5 does FFT → waterfall and
> FM demod → I²S, and drives the LCD from an **on-chip** waterfall buffer (no
> SDRAM in this build yet). GOES and ADS-B modes, the SDRAM framebuffer, and the
> Pluto-retune path are **not yet wired** — see §7. Source of truth for this
> doc: `icesugar_pro/src/{top,spi_iq_slave,spi_cmd_slave,control_regs}.sv`,
> `icesugar_pro/top.lpf`, and `plutosky/src/icesugar_stream.c`.

---

## 1. How this differs from the proposal (and from an earlier sketch)

The original proposal (`proposal/proposal.typ`) had Pluto→ECP5 SPI (IQ),
Pico→ECP5 SPI (state), and a **Pico↔Pluto UART** for tuning. The built design:

1. **The ECP5 is the hub, and demod runs on it.** FM is demodulated in ECP5
   fabric from the raw IQ stream — the Zynq just digitizes and ships IQ. This is
   the "demod on the iCESugar" goal, and for FM it's done.
2. **The Pico↔Pluto UART is replaced by the hub relay.** The Pico talks only to
   the ECP5; the ECP5 forwards tuning/mode commands on to the Pluto — the radio
   is controlled *through the hub*, not over a direct Pico↔Pluto link. The relay
   leg (ECP5 → Pluto, over the JP5 return wire) isn't wired in the gateware yet,
   so today the Pluto's LO is still set by the `icesugar_stream` CLI. Closing
   that leg is the main thing left — see §7.
3. **Two plain SPI links, not a custom multi-lane bus.** An earlier sketch
   proposed a source-synchronous link with separate raw-IQ / framed-packet lanes
   (D0/D1/D2) and an IRQ line. That was **not** built; the implementation uses
   two ordinary SPI slaves on the ECP5 (one per master). The packet-framing idea
   is still a reasonable home for the GOES/ADS-B return path if one is added
   later (§6, §7).

---

## 2. Topology

```
                       ┌──────── JP5 SPI: raw IQ (CS16) ────────┐
   Antenna ──RF──► PlutoSky (Zynq) ◄·· relayed commands (planned)·· iCESugar (ECP5) ──RGB──► LCD
                   LO set by relay      (JP5 return wire)         │  │
                   (CLI for now)                                  │  └─ FM demod ─► I²S ─► PCM5102 ─► spkr
                                                                  │
                        Pico 2W ──SPI: commands ──────────────────►┘
                           │            (ECP5 forwards to Pluto)
                           └── I²C ──► touch controller
```

| Link | ECP5 slave | Master | Wires | Carries |
|---|---|---|---|---|
| **Pluto → ECP5** (JP5) | CS0 (`spi_iq_slave`) | Zynq `axi_quad_spi` | SCK, MOSI, CS | raw IQ, 32-bit words |
| **Pico → ECP5** | CS1 (`spi_cmd_slave`) | Pico | SCK, MOSI, CS | commands `{u8,u32}` |
| **ECP5 → Pluto** (relay, *planned*) | — | ECP5 | JP5 return wire (MISO, pin 11) | tuning/mode commands |

Both SPI links are **MOSI-only as built** — MISO is unconnected on JP5 (pin 11)
and unused on the Pico link. The hub relay (ECP5 → Pluto) is the intended use of
that JP5 return wire; until it's wired, there is no path from the UI to the radio.

---

## 3. Physical layer

### 3a. Pluto → ECP5 (JP5 SPI, CS0)

Zynq master: `axi_spi_jp5` (`axi_quad_spi`) at `0x7C440000`, **Mode 3
(CPOL=1, CPHA=1)**, 8-bit transfers, SCK ratio 8 off the 100 MHz AXI clock →
**≈12.5 MHz SCK**, 1 slave select, MSB-first.

| JP5 pin | Zynq ball | ECP5 pin | Signal | Direction |
|---|---|---|---|---|
| 7  | V10 | D7 (`spi_clk`) | SCK  | Zynq → ECP5 |
| 9  | U9  | D8 (`mosi`)    | MOSI | Zynq → ECP5 |
| 13 | T9  | D9 (`cs`)      | CS   | Zynq → ECP5 |
| 11 | U10 | — (unused)     | MISO | (reserved for a future ECP5 → Zynq path) |

### 3b. Pico → ECP5 (command SPI, CS1)

Pico master, MSB-first. ECP5 pins from `top.lpf`:

| Signal | ECP5 pin |
|---|---|
| SCK  | B11 (`spi_clk_pico`) |
| MOSI | C11 (`mosi_pico`) |
| CS   | D11 (`cs1`) |

(The harness doc specifies CPOL=0/CPHA=0 for the Pico link; confirm against the
`spi_cmd_slave` sampling edge during bring-up.)

### 3c. ECP5 outputs

- **I²S** → PCM5102: `i2s_bclk` R8, `i2s_lrclk` C4, `i2s_sdata` R7.
- **LCD** (16-bit RGB565): `LCD_R[4:0]`, `LCD_G[5:0]`, `LCD_B[4:0]`,
  `LCD_CLK` J13, `LCD_DEN` F13.
- ECP5 reference clock 25 MHz on P6. Device: `LFE5U-25F-6BG256C`.

---

## 4. Pluto → ECP5: the IQ stream

One complex sample per 32 SCK cycles, MSB-first:

```
[ I15 .. I0 ][ Q15 .. Q0 ]     (16-bit signed I, 16-bit signed Q — "CS16")
```

`spi_iq_slave` shifts 32 bits and raises `iq_valid` on the 32nd; `top.sv`
crosses it into the 25 MHz domain through a small async FIFO. The Zynq packs it
the same way in `icesugar_stream.c` (`[I15..I0][Q15..Q0]`, four bytes).

**Throughput ceiling.** 12.5 MHz SCK ÷ 32 bits/sample = **390 625 complex
samples/s**. That is exactly the sample rate `icesugar_stream`'s synthetic path
uses — the radio is sized to the link. A 200 kHz FM channel fits comfortably
(≈390 kHz of capture, room for the waterfall span). To go wider later: stream
**CS8** (16 bits/sample → 781 ksps; the AD9361 has a CS8 mode) or raise the AXI
SPI SCK ratio.

---

## 5. Pico → ECP5: command protocol

Fixed **5-byte** frames, MSB-first: one command byte then a 32-bit big-endian
argument. `spi_cmd_slave` deserializes and hands `{cmd, arg}` across to the
system clock with a toggle synchronizer; `control_regs` applies them. Implemented
today (`control_regs.sv`):

| cmd | Name | arg | Effect |
|---|---|---|---|
| `0x01` | SET_MODE   | `arg[2:0]` = mode (`0` = FM; others reserved) | sets `mode` |
| `0x02` | SET_VOLUME | `arg[7:0]` = volume, `arg[8]` = mute | sets volume/mute |
| `0x03` | SET_FREQ   | `arg` = freq in Hz (reset default 100.1 MHz) | sets `freq_hz` register |

> ⚠️ `SET_FREQ` updates a register on the **ECP5** only. There is no link back to
> the Pluto, so it does **not** retune the radio today (§7, issue 1).

> **Reconciliation with the harness wire protocol.** `shared/src/wire_protocol.c`
> (and its tests) model Pico↔ECP5 as a richer **UI-state push**
> (`OP_FULL_STATE`/`OP_PARTIAL_STATE`/`OP_TOUCH_EVENT`/…). The gateware's command
> set is a small subset. Before Pico bring-up, decide whether the gateware grows
> to consume the full wire protocol, or the Pico is reduced to these three
> commands (plus whatever the status bar needs to render). Not yet unified.

---

## 6. ECP5 internal dataflow (as built)

```
   JP5 SPI ─► spi_iq_slave ─► async FIFO ─► fft256 ─► waterfall_buf (256×360, BRAM) ─► LCD
   (CS0)          (CS16)        (CDC)         │
                                              └─────► FM demod ─► i2s_tx ─► PCM5102

   Pico SPI ─► spi_cmd_slave ─► control_regs ─► {mode, volume, mute, freq_hz}
   (CS1)
```

The waterfall lives in an on-chip buffer, frame-decimated (every 32nd FFT
frame). **No SDRAM is instantiated in this build** — `top.lpf` has no SDRAM
pins. The full SDRAM-backed framebuffer + compositor in
`docs/fpga-sdr-receiver-architecture.md` (and the C reference model in
`icesugar_pro/model/`) is the target for the image modes (GOES/ADS-B) and the
double-buffered renderer; it is not part of the current FM-only bitstream.

---

## 7. Demod placement, modes, and the open paths

**Where demod runs.** FM/APT are cheap in fabric and the ECP5 already owns the
FFT and I²S, so they run on-chip — done for FM. GOES HRIT (carrier/symbol
recovery, Viterbi, Reed-Solomon, JPEG2000) and ADS-B Mode-S (bursty 1 Mbit/s PPM
+ CRC) are Zynq workloads, and their *results* (an image strip, an aircraft
list) cost far less link bandwidth than their raw IQ would (GOES ~1.2 Msps and
ADS-B ~2 Msps both blow past even the CS8 ceiling). So the intended split is:

| Mode | Demod on | Crosses JP5 as | Status |
|---|---|---|---|
| FM | ECP5 | raw IQ (CS16) | **built** |
| FM RDS metadata | PlutoSky-side decoder | compact text field in UI state | display slot built in host model; decoder/transport not wired |
| NOAA APT ("GOES" today) | ECP5 | raw IQ | feasible, not wired |
| GOES HRIT | Zynq | decoded image rows/tiles | not wired (needs a Zynq→ECP5 data path beyond bare IQ) |
| ADS-B | Zynq | aircraft list | not wired (see §8) |

**Open issues (real, from the code):**

1. **The command relay to the Pluto isn't wired yet (the main gap).** By design
   the ECP5 forwards Pico tuning/mode commands to the Pluto over the JP5 return
   wire (the currently-unused MISO, ECP5 → Zynq), where `icesugar_stream` applies
   them to the AD9361. Today that leg doesn't exist: the ECP5 just stores
   `freq_hz` and the Pluto's LO is a CLI argument. Wiring this — an ECP5 SPI/
   serial master out, and a reader on the Zynq side — is what makes the UI
   actually tune the radio.
2. **Only FM mode is wired.** `mode` exists (3 bits) but only `MODE_FM` does
   anything. GOES/ADS-B need both the Zynq decoders and an ECP5 ingest path for
   their (non-IQ) data.
3. **No SDRAM in the current build.** Image modes and the double-buffered
   framebuffer depend on the SDRAM controller from the architecture doc.
4. **Pico protocol** not yet reconciled with the harness wire protocol (§5).

---

## 8. ADS-B — the simple extension

ADS-B follows the **GOES pattern**: decode on the Zynq, send a compact result,
and reuse the display plumbing the repo already has. It needs **no raw IQ over
the link**, so bandwidth is a non-issue; the missing piece is a Zynq→ECP5 data
path for non-IQ payloads (issue 1/2 above).

**Zynq side:** tune 1090 MHz (~2 Msps internally), run Mode-S preamble + PPM +
CRC, keep an aircraft table, and emit it ~1 Hz. Cleanest transport given today's
links is to add a framed packet over the (currently unused) JP5 MISO or a second
CS, e.g.:

```
count(u8), then count × {
    icao(u24),          // 24-bit ICAO address
    x(u16), y(u16),     // pre-projected to logical map pixels; ECP5 fits viewport
    callsign/tail(8),   // text bytes, e.g. N321UA; ECP5 model adds local NUL
    alt_ft(u16),
    speed_kt(u16),
    flags(u8)           // bit0 position valid, bit1 has callsign/tail, …
}
```

**ECP5 side:** already specified in the model. `DEMOD_ADSB`/`LAYOUT_ADSB_FULL`
exist in `ui_state.h`; the SDRAM map has `ADSB_BASEMAP`; `fb_compositor.c` has
`fb_compose_adsb_frame()` with a dark basemap pass fitted below the header,
range rings, an FM/AM-style status header with interactive 25/50/75-mi zoom
buttons, tail/callsign + altitude labels, and high-contrast aircraft markers;
`tools/map_to_rom.py` builds the UCR-centered basemap and can export a dark
RGB565 asset with `--dark`. On mode entry the compositor blits the basemap once,
then plots aircraft metadata per update — slow enough to single-buffer.

So once the SDRAM framebuffer and a non-IQ Zynq→ECP5 path exist, ADS-B is:
add a `mode` value, an `ADSB_PLANES` packet, and a 1090 MHz antenna (§9). The
rendering side is done.

---

## 9. Antennas (manual swap — decided)

FM (~70 cm whip), GOES HRIT (~4.4 cm; needs a directional dish/patch **plus an
LNA at the antenna** — the signal is ≈ −110 to −120 dBm), and ADS-B (1090 MHz
monopole/colinear) are three physically different setups. We do **not** build an
RF switch — the user swaps the antenna at RX1, which is what amateur ground
stations do and keeps the RF budget clean. On a switch to GOES the LCD should
prompt *"Connect dish antenna to RX1, confirm"* before the LO moves. The LNA
matters more than antenna sophistication (a SAWbird+ GOES LNA on a modest patch
beats a fancy antenna bare).
</content>
