# Triad Receiver — iCESugar-Pro FPGA Architecture

**Audience:** the gateware author (you) and Claude Code on the SystemVerilog side.
**Scope:** how data moves through the ECP5, how the SDRAM is shared, what lives in EBR vs SDRAM, and how the display pipeline meets timing. Does not cover the audio path beyond noting where the I²S FIFO sits.

---

## 1. The big picture

```
                  ┌──────────────── ECP5-25K ─────────────────┐
                  │                                           │
   Pluto SPI ───► │ rx_fifo (EBR) ─► sdram_writer             │
                  │                       │                   │
   Pico SPI ────► │ ui_state_shadow (EBR) │                   │
                  │       │               ▼                   │
                  │       │          ┌─────────┐              │
                  │       │          │ SDRAM   │              │
                  │       │          │ ARBITER │              │
                  │       │          └─────────┘              │
                  │       │           ▲    ▲    ▲             │
                  │       │           │    │    │             │
                  │       │       writes  writes reads        │
                  │       │           │    │    │             │
                  │       │      compositor    line_cache     │
                  │       │      (waterfall,   (4xEBR)        │
                  │       │       GOES writer)      │          │
                  │       │                        ▼          │
                  │       └─────────► pixel_shader            │
                  │                        │                  │
                  │                  scan_timing              │
                  │                        │                  │
                  │                        ▼                  │
                  │                    LCD pins               │
                  └───────────────────────────────────────────┘
                              ▲
                              │
                          32 MB SDRAM
                          IS42S16160B
```

Three independent data paths share the SDRAM through an arbiter:
1. **Scan-out reader** — pulls one line at a time into the EBR line cache, hard real-time.
2. **Compositor writer** — writes waterfall/GOES updates from compositor staging.
3. **Ingest writer** — moves Pluto packets from the RX FIFO into their target SDRAM regions.

Plus one small path that doesn't touch SDRAM: the **pixel shader** reads the EBR line cache, the UI state shadow, and the EBR ROMs (font, sprites, palette) and emits final RGB to the LCD pins on the pixel clock.

---

## 2. Display timing

Standard 800×480 4.3" RGB-parallel timing, 60 Hz target:

| Param | Value |
|---|---|
| Pixel clock | 30 MHz (29.232 MHz exact) |
| H-active / H-total | 800 / 928 |
| V-active / V-total | 480 / 525 |
| Line time | 30.9 µs |
| Active per line | 26.7 µs |
| H-blank per line | 4.3 µs |
| V-blank between frames | ~1.39 ms (45 lines) |

A `scan_timing` module owns the LCD timing counters and emits HSYNC/VSYNC/DE plus the live `(x, y)` for the active region. It runs from a 30 MHz pixel-clock domain. Everything else (SDRAM, arbiter, compositor, RX) runs in the SDRAM clock domain (100 MHz). The line buffer in EBR is the clock-domain-crossing point — true dual-port, write side on SDRAM clock, read side on pixel clock.

---

## 3. SDRAM controller and arbiter

**SDRAM:** IS42S16160B, 32 MB, x16, target controller clock 100 MHz (conservative; 166 is the part max).

Build the controller to expose a simple **request/grant interface** with one queue per client:

```
client → req {addr, len, dir, data_src/dst} → granted? → burst transfer → done
```

Three clients with fixed priority:

| Client | Priority | Why |
|---|---|---|
| Scan-out reader | 0 (highest) | Hard real-time; missing a line = visible tear |
| Compositor writer | 1 | Soft real-time; can wait for V-blank if needed |
| Ingest writer (RX FIFO drain) | 2 | RX has its own 8 KB FIFO; can wait |

**Bandwidth budget at 60 fps:**

| Use | Bandwidth | % of 200 MB/s peak |
|---|---|---|
| Scan-out (480 lines × 1600 B × 60 Hz) | 46 MB/s | 23% |
| Waterfall scroll worst case (240 rows × 1600 B × 30 Hz) | 11 MB/s | 6% |
| GOES writes (~2 lines/sec × 1600 B) | 3 KB/s | <0.1% |
| Pluto ingest (Zynq → ECP5 SPI is the limit, ~1 MB/s) | 1 MB/s | 0.5% |
| **Total worst case** | **~58 MB/s** | **29%** |

Plenty of margin. The arbiter is fixed-priority round-robin among the lower two — don't bother with QoS.

**V-blank batching:** the compositor preferentially defers writes to V-blank when nothing's contending with scan-out. 1.39 ms × 200 MB/s × 50% efficiency = ~140 KB of write window per frame, which is nearly twice the entire waterfall region.

---

## 4. Scan-out path (the hard real-time one)

The scan-out reader runs ahead of the LCD by one line. Its job: at the start of every active line, the EBR line cache must already hold the correct row of pixels.

**Line cache (EBR):** 4 buffers × 1 line × 1600 bytes = 6.4 KB. Why 4 not 2:
- 1 = currently being read by `pixel_shader` for active pixels
- 1 = being filled by the SDRAM reader (next line)
- 2 = headroom for arbiter stalls (refresh, write contention)

The 4-deep ring smooths over arbiter stalls (refresh, write contention) of several line-times. SDRAM auto-refresh is tRFC ≈ 7 cycles ≈ 70 ns every 7.8 µs at 100 MHz ≈ 1% overhead in the worst case, which is well under the cache depth.

**Framebuffer layout — half-page (hardware-mandated).** *Logically* the framebuffer is still a flat `uint16_t[480][800]`: pixel (x, y) is word `W = y*800 + x`. **This logical mapping is the contract** — the C reference model (§11) and all pixel math are unchanged. What changed is only the *physical* placement of word W in SDRAM.

Hardware measurement (project note, 2026-05-29) found this board's IS42S16160B is reliable only for bursts that stay within **columns 0–255** of a row; any access reaching the 512-word page boundary returns a few corrupt words — the cause of the early display streaks. Three controller-level fixes (BL=8 bursts, guard cycles, 75 MHz) were each built and tested on hardware and **none** cleared it: it is a physical margin, not an RTL bug. So the framebuffer stores only **256 words per SDRAM row** (columns 0–255; columns 256–511 unused). Word W maps as:

```
SDRAM row    = W >> 8          // W / 256
SDRAM column = W & 255         // W % 256, always 0..255
byte address = FB_BASE + ((row << 10) | (col << 1))
```

An 800-word line therefore spans **4 SDRAM rows** (256+256+256+32) instead of 1.6, and **no burst ever reaches the marginal boundary column**. Each line is still fetched as page-aligned `{addr, len}` segments — now bounded to ≤256 words — and no single burst crosses a row. Writers (compositor) and the reader (scan_out) share this exact mapping; both carry a `HALF_PAGE` parameter and **must agree**, or the streaks return.

**Read trigger:** during H-blank of line N, kick the segmented burst read for line N+2 into whichever cache slot is free. For display line y the first segment starts at column `(y*800) mod 256` of row `(y*800) div 256` and runs to the end of that row (col 255); up to three further segments cover the remainder (≤4 segments/line). The controller activates, bursts, and precharges per segment (close-row policy).

**At pixel time:** the shader's FB-read accessor reads one word from the cache slot tagged with the current line. Single-cycle, deterministic, EBR-clean.

**Tearing:** when the compositor writes the waterfall during active scan, the FB-read might see half-old/half-new pixels. Acceptable for waterfall (it's already a moving image). For UI elements you want clean updates: keep them in the live shader path, not the FB.

---

## 5. EBR allocation map

Total: 56 blocks × 2304 bytes ≈ 126 KB. Target utilization **~50%**, leaving room for late-stage growth and unanticipated buffers.

| Use | Blocks | Bytes | Why this size / headroom rationale |
|---|---:|---:|---|
| Scan-out line cache (4 lines) | 3 | 6,400 | 2 functional + 2 headroom for arbiter stall |
| Compositor write line buffer | 1 | 1,600 | scratch for waterfall scroll, GOES row staging |
| Font ROM (8×16 body + 16×32 title) | 2 | 7,680 | two sizes; bump to 3 if we need a third |
| Sprite ROM (16 × 32×32 RGB565) | 11 | 32,768 | start with 6 sprites, room for 16 |
| Palette LUTs (2 × 256 RGB565) | 1 | 1,024 | waterfall + GOES, separately tunable |
| RX FIFO (Pluto → SDRAM staging) | 4 | 9,216 | 8 KB absorbs ≥8 ms of SPI burst |
| Audio FIFO (I²S out) | 2 | 4,608 | ~12 ms stereo cushion @ 48 kHz |
| UI state shadow (double-buffered) | 1 | 1,024 | tear-free shader read of UI state |
| Spectrum bin RAM (256 × 16, dual-port) | 1 | 512 | shader read + Pico write |
| GOES line accumulator | 1 | 800 | pre-compose before SDRAM write |
| **Total allocated** | **27** | **~65 KB** | |
| **Headroom (free)** | **29** | **~63 KB** | room for audio DSP, debug RAM, A/B buffers, etc. |

**Block-not-byte rounding:** EBR blocks are minimum-allocation units. A 512-byte palette uses one 2.3 KB block. Don't fight this — count blocks, not bytes.

**Naming convention:** every EBR-backed module gets a `*_ram.sv` instantiating the dual-port primitive (or your `dp_buffer` from earlier work) with the right depth and width. Top-level keeps a `localparam` table mapping logical use to block count so the budget is auditable in one file.

---

## 6. SDRAM memory map

32 MB is enormous relative to need. Allocate generously:

| Region | Address range | Size | Use |
|---|---|---|---|
| FB_FRONT | 0x0000_0000 – 0x0017_FFFF | 1.5 MB | active framebuffer (RGB565, 800×480, **half-page**: 256 words/row, see §4) |
| FB_BACK | 0x0018_0000 – 0x002F_FFFF | 1.5 MB | back buffer; swap pointer at V-sync |
| WATERFALL_HISTORY | 0x0030_0000 – 0x0037_FFFF | 512 KB | extra waterfall depth (scrollback) |
| GOES_FULL_IMAGE | 0x0038_0000 – 0x003F_FFFF | 512 KB | full GOES image at 909×... if we go beyond strip |
| ADSB_BASEMAP | 0x0040_0000 – 0x004B_FFFF | 768 KB | static Riverside map image, 800×448 RGB565 = 700 KB (generated by `tools/map_to_rom.py`) |
| AUDIO_RING | 0x004C_0000 – 0x004F_FFFF | 256 KB | optional audio history for replay |
| SCRATCH | 0x0050_0000 – 0x01FF_FFFF | ~27 MB | unallocated; future use |

Each framebuffer reserves **1.5 MB**, not 768 KB: the half-page layout (§4) uses 256 of each row's 512 columns, so 800×480 = 384,000 live words occupy 1,500 SDRAM rows × 1024 bytes = 1.5 MB of address space. Only 768 KB is live pixel data; the rest is the skipped upper half of each row. The *logical* model is still a flat `uint16_t[480][800]`, so the harness model (§11) is unchanged — only the word→address function differs (§4). The 32 MB part makes the 2× footprint a non-issue (FB_FRONT+FB_BACK = 3 MB total).

**Half-page applies to any region read or written as row-major image bursts.** WATERFALL_HISTORY, GOES_FULL_IMAGE, and ADSB_BASEMAP are row-major images too: when their read/write paths are built, store them half-page (256 words/row) and size them ×2, exactly like the framebuffer — revisit their sizes at that point. AUDIO_RING is sequential, not image rows; chunk its bursts to ≤256 words so they don't reach the boundary.

The ECP5 only needs to know about FB_FRONT/FB_BACK plus the scratch waterfall/GOES/ADS-B regions for compositor writes. Everything else is "we have it if we need it." The ADS-B map is static, so the compositor blits it from ADSB_BASEMAP once on mode entry and then only redraws plane markers, labels, and the compact header. ADSB_BASEMAP is populated from SPI config flash at boot (it's too big for EBR); `tools/map_to_rom.py` produces that RGB565 image centered on a given lat/lon, with `--dark` available for a low-brightness display asset. The C reference model loads the tracked Riverside basemap when present and otherwise falls back to a stylized stand-in.

---

## 7. Compositor (FB write side)

Three primitive operations, each implemented as a small write-side FSM that submits SDRAM bursts:

### 7a. `waterfall_step`
- Input: 800-element `magnitudes` array (one row from the spectrum), palette index per pixel.
- Action: shift the waterfall region in SDRAM down by 1 row, write new top row.
- Trick: don't actually copy. Use a **base-row pointer** modulo region height; the scan-out reader applies the same modulo when reading. Writing one new row is the only SDRAM traffic.
- Cost: 1 burst read of palette LUT (already in EBR), 1 write of one 800-word row (1600 bytes) into the framebuffer, split into page-aligned segments using the **same half-page mapping as the scan-out read** (see §4) — the compositor's `HALF_PAGE` must match scan_out's. ~9 µs at 100 MHz.

### 7b. `goes_row_write`
- Input: 800-byte grayscale row, target Y in GOES region. A real decoder should
  derive target Y from frame/line sync or hold blank until it has sync.
- Action: downsample the incoming row into the 480×480 square image area,
  expand each grayscale byte to RGB565 (`val | val<<5 | val>>1` for green
  emphasis or via GOES palette), and leave the remaining 320 px for the side
  status panel.
- Frequency: 2 lines/sec from the satellite. Trivial.

### 7c. `region_clear`
- Input: rectangle, fill color.
- Action: row-by-row burst writes. Used on layout change.
- Frequency: rare.

### 7d. `adsb_frame`
- Input: aircraft list (region-local x/y per plane). Basemap is static.
- Action: on mode entry, blit ADSB_BASEMAP into the region (or, in the C
  reference / mock, draw a procedural grid+river placeholder). Each update,
  redraw the basemap under the changed area and plot a dot per aircraft.
- Frequency: ~1–2 Hz (plane positions). Slow enough that single-buffering is
  fine — no tearing risk like the per-frame waterfall.

The compositor FSM picks one op at a time, no preemption. Each op has its own valid/done handshake with the arbiter.

---

## 8. UI state path

Pico SPI slave on the FPGA writes the UI state shadow RAM (EBR). The shadow is **double-buffered**:
- `shadow_a`, `shadow_b` — both 1 KB, true dual-port.
- A `front_select` register flips at V-sync.
- Pico writes always go to the back; shader reads always come from the front.
- Result: every frame sees a coherent UI state, no mid-frame tears from in-flight partial updates.

The Pico's `OP_PARTIAL_STATE` opcode lets it write a few bytes at a time without disturbing the rest. On `OP_FULL_STATE`, the whole back buffer is rewritten before the next V-sync flip.

The current FM/AM display bitstream implements a reduced version of this path in
`icesugar_pro/src/ui_wire_rx.sv`: it CRC-validates the canonical `0xA5` frames
and commits only the live-display fields (`layout`, `demod`, `volume`,
`freq_hz`, `span_hz_log2`, `flags`, touch coordinates, `active_button`, and
the first 24 printable RDS characters).
`ui_status_prepare.sv` then formats the center frequency, visible band range
(`freq_hz ± span/2`), mode labels, and volume fill. The spectrum shader and
waterfall row expander consume the full 256-bin FFT row; `span_hz_log2` now
drives the spectrum FFT input decimator in `top.sv`. The full 1 KB
double-buffered raw-state shadow remains the target for image-mode payloads and
larger UI surfaces.

---

## 9. Pixel shader (live overlay)

Runs on the pixel clock. Inputs each cycle:
- `(x, y)` from `scan_timing`
- One pixel from the line cache (`fb_under`)
- The current UI state shadow (front buffer)
- Tap into font ROM, sprite ROM, palette LUTs as needed

Output: one RGB565 pixel per cycle.

The C reference in the harness has the same signature and is the spec for what the gateware computes. Translating to SystemVerilog: each `shade_*` becomes a small combinational + 1-cycle ROM-lookup pipeline. Pipeline depth is absorbed by the line cache (read 1 line ahead).

**No SDRAM in the shader.** All state visible to the shader is in EBR or registers.

---

## 10. Bring-up order

1. SDRAM controller standalone — write known pattern, read back, verify.
2. SDRAM + scan-out reader → solid color FB → display.
3. Add line cache + arbiter → scrolling test pattern from FB.
4. Add UI state shadow + Pico SPI slave → live touch cursor as overlay (no FB).
5. Add font/sprite ROMs + status bar shader → frequency display.
6. Add compositor `waterfall_step` → moving waterfall from synthetic data.
7. Add Pluto SPI ingest → real spectrum/waterfall.
8. GOES path.

Each step is independently testable on hardware with a logic analyzer + the harness running the same UI logic in parallel for cross-checking.

---

## 11. What the harness does NOT model

For clarity, the host harness (separate doc) intentionally skips:
- SDRAM timing, refresh, arbitration
- Line cache fill latency
- Clock domain crossing
- EBR block boundaries

The harness models the FB as a flat `uint16_t[480][800]` and the EBR ROMs as `static const` arrays. The portability discipline is what carries the design from harness to hardware — see the handoff doc, section 3.
