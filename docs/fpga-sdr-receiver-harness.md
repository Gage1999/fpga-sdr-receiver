# Triad Receiver — Frontend Test Harness Handoff (v2)

**Audience:** Claude Code, building this from scratch in a new repo.
**Companion doc:** `triad-fpga-architecture.md` — read it first; this doc assumes its terminology.
**Goal:** A host-side test harness for the Triad Receiver UI. Develop and test the rendering and UI code on a laptop *before* (and alongside) the FPGA gateware and Pico firmware exist. The closer the host code is to what runs on the Pico and what the FPGA renders, the higher the test value.

---

## 1. Background — what the real hardware does

The Triad Receiver UI is split across two chips:

- **Pi Pico 2 (RP2350, C firmware)** — owns UI state. Reads a Goodix capacitive touch controller over I²C (specific part TBD; GT911 family likely). Maintains current frequency, demod mode, volume, layout, button highlight state. Sends a packed **UI state struct** to the FPGA over SPI (Pico master), with partial diffs and periodic full syncs. Also sends commands to the Zynq over UART (out of scope here).

- **iCESugar-Pro (ECP5-25K + 32 MB SDRAM, SystemVerilog)** — owns the screen. Hybrid renderer:
  1. **Framebuffer in SDRAM** holds *persistent regions* (waterfall scrollback, GOES image) — written by the compositor, read by scan-out at the pixel clock through a 4-line EBR cache.
  2. **Live pixel shader** overlays *volatile UI* (status bar text, buttons, modal dialogs, touch cursor, spectrum bars) on top of `fb_under` at scan-out time. Reads from EBR ROMs (font, sprites, palette) and the UI state shadow.

See the architecture doc for the data path and EBR map.

The harness simulates both chips in one host process. The screen renders into an SDL window. Mouse clicks become touch events. The same `.c`/`.h` files in `shared/` and `pico/src/ui_logic.c` build for both Pico and host, with HAL-isolated platform differences.

**Test of success:** when we flash hardware, the C in `icesugar_pro/model/src/pixel_shader.c`, `icesugar_pro/model/src/fb_compositor.c`, and `pico/src/ui_logic.c` is bit-identical to what ran in the harness. The shader and compositor get hand-translated to SystemVerilog; the C is the executable spec.

### Hardware specs

| Item | Value |
|---|---|
| LCD | 4.3" 800×480 RGB-parallel, 60 Hz, RGB565 in our FB |
| FPGA | Lattice ECP5-25K |
| Off-board RAM | 32 MB SDRAM (FB lives here, double-buffered) |
| Touch | Goodix capacitive controller (model TBD; GT911 family likely) over I²C on the Pico |
| Pico↔FPGA | SPI, Pico master, MSB-first, CPOL=0 CPHA=0 |
| Endianness | Little-endian on the wire |

---

## 2. Repo layout

CMake. Targets: `host_harness`, `tests`, `pico_firmware` (only when `PICO_SDK_PATH` is defined).

```
triad-frontend/
├── README.md
├── CMakeLists.txt
├── docs/
│   ├── triad-fpga-architecture.md    # the companion doc
│   └── triad-frontend-harness.md     # this doc
├── shared/                           # PORTABLE C — Pico + host
│   ├── include/
│   │   ├── ui_state.h                # packed UI state struct + version
│   │   ├── wire_protocol.h           # SPI frame format, opcodes, CRC
│   │   ├── pixel_shader.h            # live shader entry point
│   │   ├── fb_compositor.h           # FB write primitives
│   │   ├── fb_accessor.h             # the only way to read/write the FB
│   │   ├── regions.h                 # region rectangles per layout
│   │   ├── screen_config.h           # 800x480, RGB565, timing constants
│   │   ├── font.h                    # font ROM declarations
│   │   ├── sprites.h                 # sprite ROM declarations
│   │   └── palette.h                 # palette LUT declarations
│   └── src/
│       ├── ui_state.c
│       ├── wire_protocol.c           # pack/unpack/CRC
│       ├── pixel_shader.c            # live overlay logic
│       ├── fb_compositor.c           # waterfall_step, goes_row_write, region_clear
│       ├── regions.c
│       ├── font.c                    # 8x16 + 16x32 ASCII bitmaps
│       ├── sprites.c                 # 16 sprites @ 32x32 RGB565
│       └── palette.c                 # waterfall + GOES palettes
├── pico/
│   ├── include/hal_pico.h
│   ├── src/
│   │   ├── main.c
│   │   ├── hal_pico.c                # Pico SDK impl of HAL
│   │   ├── ui_logic.c                # PORTABLE: also built on host
│   │   └── touch_goodix.c            # real hardware only
│   └── CMakeLists.txt
├── host/
│   ├── include/hal_host.h
│   ├── src/
│   │   ├── main.c                    # SDL window, event loop
│   │   ├── hal_host.c                # SDL/posix impl of HAL
│   │   ├── pico_sim.c                # hosts ui_logic.c
│   │   ├── fpga_sim.c                # hosts compositor + shader, drives "scan-out"
│   │   ├── fb_host.c                 # the FB on host (uint16_t[480][800] x 2)
│   │   ├── spi_link.c                # in-process SPI between sims
│   │   ├── input_map.c               # mouse/keyboard → touch events
│   │   └── synth_data.c              # fake spectrum/waterfall/GOES
│   └── CMakeLists.txt
├── tools/
│   └── rom_to_mem.py                 # converts icesugar_pro/model/src/font.c arrays to .mem files
└── tests/
    ├── CMakeLists.txt
    ├── test_ui_state.c
    ├── test_wire_protocol.c
    ├── test_pixel_shader.c           # golden images
    ├── test_fb_compositor.c          # golden images for waterfall scroll, GOES
    ├── test_ui_logic.c               # touch sequences → state assertions
    └── golden/
```

---

## 3. The portability contract — read carefully

Files in `shared/` are **pure portable C**:
- Only `<stdint.h>`, `<stddef.h>`, `<string.h>`, `<stdbool.h>`. No malloc, no stdio, no platform headers.
- I/O via passed-in buffers and accessor functions only.
- Fixed-width integer types for everything that crosses chip boundary or memory.
- Multi-byte fields packed little-endian.

`pico/src/ui_logic.c` is also portable. Its only dependency surface is `hal_pico.h`:
```c
uint64_t hal_now_us(void);
void     hal_log(const char *fmt, ...);
bool     hal_touch_poll(touch_event_t *out);
void     hal_spi_send(const uint8_t *buf, size_t len);
void     hal_sleep_ms(uint32_t ms);
```

### 3a. The framebuffer accessor (the key abstraction on the FPGA side)

`fb_compositor.c` and `pixel_shader.c` both go through `fb_accessor.h` — and **nothing else** in `shared/` may touch FB memory:

```c
typedef struct fb fb_t;  // opaque

// Read one RGB565 pixel.
// Hardware: fires a line-cache lookup (1-cycle BRAM read).
// Host: array index into uint16_t[480][800].
uint16_t fb_read(const fb_t *fb, uint16_t x, uint16_t y);

// Write pixel(s).
// Hardware: queues writes to the SDRAM controller via the compositor port.
// Host: array index assignment.
void fb_write(fb_t *fb, uint16_t x, uint16_t y, uint16_t rgb565);
void fb_write_row(fb_t *fb, uint16_t x, uint16_t y,
                  const uint16_t *src, uint16_t n);

// Swap front/back buffer pointers. Called at V-sync.
void fb_swap(fb_t *fb);
```

This keeps the door open for the FPGA implementation, where `fb_t` is *not* a flat array — it's a wrapper around the SDRAM controller's request/grant interface plus a row-pointer for the waterfall ring (see arch doc §7a).

**The host implementation is dumb on purpose.** No timing simulation, no arbitration, no row-pointer math (just literal copies for the waterfall scroll — comment notes the FPGA does it differently but the visible output is identical).

### 3b. Pixel shader contract

```c
// Pure function. Given UI state, FB pixel under this position, and EBR ROMs,
// return the final RGB565 for (x, y).
//
// On hardware: combinational + ROM lookups on the pixel clock.
uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const ui_state_t *ui,
                      const aux_roms_t *roms);
```

Constraints:
- No floats, no malloc, no globals beyond inputs.
- Multiply, add, shift, compare, table-lookup. Division flagged `// TODO_FPGA: reciprocal LUT`.
- Branchy is fine; deep nested branches hurt FPGA timing — prefer flat dispatch.

`aux_roms_t` is a struct of pointers to the font, sprite ROM, palettes. On host: `static const` arrays. On FPGA: EBR ROMs. The same C source generates both (see §10 on ROM generation).

---

## 4. UI state struct

`shared/include/ui_state.h`. Target small but not crippled — main FB-bound spectrum bins are kept in here so the live shader can draw them without touching SDRAM.

```c
#define UI_STATE_VERSION  2u

typedef enum : uint8_t { DEMOD_FM=0, DEMOD_AM=1, DEMOD_GOES=2, DEMOD_ADSB=3 } demod_mode_t;
typedef enum : uint8_t {
    LAYOUT_SPECTRUM_ONLY = 0,
    LAYOUT_GOES_FULL     = 1,
    LAYOUT_ADSB_FULL     = 2,   // full-screen ADS-B map
} layout_t;

#define UI_FLAG_MUTE         (1u << 0)
#define UI_FLAG_RECORD       (1u << 1)  // reserved; no visible record button
#define UI_FLAG_TOUCH_ACTIVE (1u << 2)

typedef struct __attribute__((packed)) {
    uint8_t  version;            // == UI_STATE_VERSION
    uint8_t  layout;             // layout_t
    uint8_t  demod;              // demod_mode_t
    uint8_t  volume;             // 0..100
    uint32_t freq_hz;
    uint16_t span_hz_log2;
    uint8_t  squelch;
    uint8_t  flags;
    uint16_t touch_x, touch_y;
    uint8_t  active_button;      // 0xFF = none
    uint8_t  brightness;
    uint8_t  reserved[2];
    char     rds_text[32];       // FM RDS/radio text, if decoded upstream
    uint16_t spectrum_bins[256]; // FFT magnitudes for live shader to draw bars
} ui_state_t;

_Static_assert(sizeof(ui_state_t) <= 1024, "ui_state_t exceeds 1KB shadow RAM");
```

Total: ~528 bytes, well under the 1 KB EBR shadow on the FPGA. If you'd rather keep the state struct small and push spectrum bins through a separate opcode, see §5 — the protocol supports it.

Decisions to enforce:
- Every struct carries a version byte; mismatched frames are dropped.
- No pointers, no variable-length fields.
- `_Static_assert` on `__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__` in `wire_protocol.c`.

---

## 5. Wire protocol (Pico → FPGA)

```
+------+--------+----------+-------------+--------+
| 0xA5 | OPCODE | LEN (LE) |   PAYLOAD   | CRC16  |
| 1 B  | 1 B    | 2 B      |   LEN B     | 2 B    |
+------+--------+----------+-------------+--------+
```

Opcodes:
- `0x01 OP_FULL_STATE` — full `ui_state_t`
- `0x02 OP_PARTIAL_STATE` — `[offset:u16][len:u16][bytes...]`, multiple chunks per frame allowed
- `0x03 OP_TOUCH_EVENT` — `{x:u16, y:u16, kind:u8}`, kinds: DOWN, MOVE, UP, SWIPE_L, SWIPE_R, TAP, LONG. (Note: the CST816S we originally planned for emits gesture codes directly. Most Goodix parts only report raw touch points; gesture detection happens on the Pico from the raw point stream. Wire protocol is unchanged either way.)
- `0x04 OP_HEARTBEAT` — empty, sent at 10 Hz
- `0x05 OP_SPECTRUM_BINS` — optional separate path for the 512-byte bins array if you want to keep `ui_state_t` smaller

CRC16-CCITT, init 0xFFFF, over OPCODE+LEN+PAYLOAD.

**Partial updates rule:** Pico keeps a "last sent" copy. Diffs sent as `OP_PARTIAL_STATE`. Every 16 frames sends `OP_FULL_STATE`. Bad-CRC frames are silently dropped; next full sync repairs.

API in `wire_protocol.c`, all portable:
```c
size_t wire_pack_full(uint8_t *out, size_t out_cap, const ui_state_t *st);
size_t wire_pack_partial(uint8_t *out, size_t out_cap,
                         const ui_state_t *prev, const ui_state_t *curr);
size_t wire_pack_touch(uint8_t *out, size_t out_cap, const touch_event_t *ev);
size_t wire_pack_heartbeat(uint8_t *out, size_t out_cap);

// Returns bytes consumed (0 if frame incomplete, <0 on error).
int wire_consume(const uint8_t *buf, size_t len,
                 ui_state_t *st_inout,
                 touch_event_queue_t *tq_inout);
```

---

## 6. Region layout

`shared/include/screen_config.h`:
```c
#define SCREEN_W 800
#define SCREEN_H 480
typedef uint16_t pixel_t;
#define RGB565(r,g,b) (((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3))
```

| Region | Origin | Size | Owner | Lives where |
|---|---|---|---|---|
| status | (0,0) | 800×64 | shader | live (FM/AM only) |
| spectrum | (0,64) | 800×128 | shader | live (from `spectrum_bins`) |
| waterfall | (0,192) | 800×288 | compositor | framebuffer |
| goes_full | (0,0) | 800×480 | compositor | 480×480 image + 320×480 stats panel (in `LAYOUT_GOES_FULL`) |
| adsb_full | (0,0) | 800×480 | compositor | framebuffer (in `LAYOUT_ADSB_FULL`) |
| overlay | varies | varies | shader | live (modal, cursor) |

`regions.c` exports a `region_at(x, y, layout)` lookup that returns the active region's kind + local-origin offset.

---

## 7. Live pixel shader (`pixel_shader.c`)

```c
uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const ui_state_t *ui,
                      const aux_roms_t *roms)
{
    region_t r = region_at(x, y, ui->layout);

    // Modal overlay short-circuits everything.
    if (r.kind == R_OVERLAY) return shade_overlay(x, y, ui, roms);

    switch (r.kind) {
    case R_STATUS:    return shade_status(x - r.x0, y - r.y0, r.w, ui, roms);
    case R_SPECTRUM:  return shade_spectrum(x - r.x0, y - r.y0, r.w, r.h, ui);
    case R_WATERFALL: return fb_under;   // FB-owned, pass through
    case R_GOES:       return fb_under;
    default:          return RGB565(0,0,0);
    }
}
```

Each `shade_*`:
- `shade_status` — frequency text, large FM RDS text, demod label, centered volume bar, and 48×48 touch buttons via font + sprite ROM. The mode button uses visually centered two-character labels (`FM`, `AM`, `GO`, `AD`) instead of small pictograms. The visible controls are tune up/down, volume up/down, mute, and mode; image modes hide the full status bar and expose only a floating MODE button.
- `shade_spectrum` — `bin_idx = (x * 256) >> log2(r.w)` (powers of 2 only — flag div); `bar_top = r.h - (bins[bin_idx] * r.h >> 16)`; foreground if `y >= bar_top`.
- `shade_overlay` — touch cursor crosshair if `flags & TOUCH_ACTIVE`, modal frames, focused-button border.

---

## 8. Framebuffer compositor (`fb_compositor.c`)

The narrow primitives that the FPGA implements as write-side FSMs (arch doc §7):

```c
void fb_compose_waterfall_step(fb_t *fb,
                               uint8_t layout,
                               const uint8_t magnitudes[800],
                               const uint16_t palette[256]);

void fb_compose_goes_row(fb_t *fb, uint8_t layout,
                         uint16_t row_y_in_region,
                         const uint8_t pixels[800],
                         const uint16_t palette[256]);

void fb_compose_goes_panel(fb_t *fb, uint8_t layout,
                           uint16_t row_y_in_region,
                           const aux_roms_t *roms);

void fb_compose_clear(fb_t *fb, region_t r, uint16_t color);

// ADS-B map: darkened static basemap fit below the header + range rings,
// FM/AM-style status header with zoom ladder, aircraft identifiers/altitude
// labels, and one high-contrast marker per aircraft. Slow-update, so no back
// buffer. The real version blits a Riverside map-image ROM; the fallback is
// procedural.
typedef struct {
    uint16_t x, y;
    char     ident[9];  // 8-byte tail/callsign plus local NUL terminator
    uint16_t alt_ft;
    uint16_t speed_kt;
} adsb_plane_t;

void fb_compose_adsb_frame(fb_t *fb, uint8_t layout,
                           const adsb_plane_t *planes, uint8_t n_planes);
```

The host implementation does the dumb thing (literal memmove for waterfall scroll). Comment in the header notes the FPGA uses ring-buffer addressing; visible behavior is identical, which is what the golden-image tests verify.

---

## 9. Host harness wiring

`host/src/main.c`:
```
init SDL window 800x480 (or scaled if your monitor is small)
init synth_data (background fills magnitudes + GOES rows)
init fb_host (two uint16_t[480][800])
init fpga_sim (compositor, shader, scan-out)
init pico_sim (ui_state, touch queue, ui_logic.c instance)
init spi_link (in-process pipe between sims)

loop @ 60 Hz:
    poll SDL events
        mouse → input_map → touch_event_t → push to pico_sim's hal_touch_poll queue
        keyboard → button presses or gestures (see §10b)
    pico_sim.tick():
        ui_logic.c runs one iteration
        ui_logic mutates its ui_state_t
        on change, calls hal_spi_send() with packed wire frames
        hal_host pushes bytes to spi_link
    fpga_sim.tick():
        drain spi_link, wire_consume() updates fpga_sim's ui_state shadow
        if synth_data has new magnitudes → fb_compose_waterfall_step()
        if synth_data has new GOES row    → fb_compose_goes_row() at the current source row
        for y in 0..479: for x in 0..799:
            uint16_t fb_under = fb_read(fb, x, y);
            framebuf_out[y][x] = pixel_shader(x, y, fb_under, &ui, &roms);
    blit framebuf_out to SDL texture
    fb_swap(fb)
```

`spi_link.c`:
```c
typedef struct spi_link spi_link_t;
spi_link_t *spi_link_new_inproc(void);
void spi_link_send(spi_link_t *l, const uint8_t *buf, size_t len);
size_t spi_link_recv(spi_link_t *l, uint8_t *buf, size_t cap);  // non-blocking
```

In-process implementation: ring buffer + mutex. **Critical:** the in-process variant must send bytes in the same wire format as SPI — no `memcpy(struct)` shortcuts across the boundary. This is the discipline that catches endianness bugs and packing bugs before hardware bring-up.

Stub a `spi_link_new_socket(const char *path)` for later — same interface, AF_UNIX SOCK_STREAM. Don't implement it now.

---

## 10. ROMs (font, sprites, palettes)

The shader's EBR ROMs need to be **the same data** on host and FPGA. The C arrays in `icesugar_pro/model/src/font.c`, `sprites.c`, `palette.c` are the source of truth.

A small Python tool `tools/rom_to_mem.py` parses these C files and emits `.mem` files in the format the ECP5 toolchain consumes for `$readmemh` initialization. CMake runs it as a build step before the FPGA build (when invoked, not in the host build).

This way:
- Add a new sprite → write the C array → host harness sees it immediately (golden tests update) → FPGA build picks up new `.mem` automatically.
- Sprite/font geometry (8×16, 16×32, 32×32) is declared as compile-time constants in headers and used by both shader and ROM generator.

### 10a. ROM contents

| ROM | Spec | Source |
|---|---|---|
| Font 8×16 | 96 ASCII chars × 16 rows × 1 byte | `font_8x16.c` static const |
| Font 16×32 | 96 chars × 32 rows × 2 bytes | `font_16x32.c` |
| Sprites | 16 × 32×32 RGB565 = 32 KB | `sprites.c`, named indices for tune, volume, mute, and mode icons |
| Waterfall palette | 256 × RGB565 | `palette.c`, e.g. `viridis_565[256]` |
| GOES palette | 256 × RGB565 | `palette.c`, grayscale-with-tint |

### 10b. Input map

Mouse:
- left-down → `touch_event_t{kind=DOWN, x, y}` in screen coords
- motion held → MOVE
- up → UP

Keyboard equivalents (for scripted tests and laptop use without a touchscreen):
- ←/→ → SWIPE_L / SWIPE_R
- ↑/↓ → freq tune buttons (synth touches at button center)
- M → mute toggle
- 1/2/3 → layout switch
- Space → tap at cursor
- L → LONG gesture
- F11 → fullscreen the window

---

## 11. Tests

`tests/` runs without SDL — pure compute, suitable for CI.

**`test_ui_state.c`** — pack/unpack roundtrip, fuzz with deterministic random states, verify `_Static_assert`s.

**`test_wire_protocol.c`**
- Full state pack → consume → assert byte-equal recovered state
- Sequential mutations → partial diffs → applied on receiver → assert state convergence
- CRC corruption → assert error and no state mutation
- Resync: garbage prefix → consumer skips to magic byte

**`test_pixel_shader.c`** — golden-image regression. Curated `ui_state_t` configs render the full screen via `pixel_shader` over a known FB content. Compare byte-for-byte to PNGs. `--update-goldens` flag for deliberate updates.

**`test_fb_compositor.c`** — golden images for waterfall scroll sequences, GOES row writes, region clears. Also verifies that N waterfall_steps + a clear gets you back to a known state.

**`test_ui_logic.c`** — drive `ui_logic.c` through scripted touch sequences with mock HAL, assert resulting state. E.g. "tap freq-up 5 times → freq increased by 5×step".

---

## 12. Acceptance checklist

- [ ] `cmake -B build && cmake --build build` produces `host_harness` and `tests` on Linux/macOS.
- [ ] `./build/host_harness` shows the 800×480 window, four regions populated by synth data, mouse/keyboard input updates state and visibly changes the screen.
- [ ] `ctest` passes; ≥3 golden cases for shader, ≥3 for compositor.
- [ ] No file in `shared/` includes anything from `host/` or `pico/`.
- [ ] No file in `shared/` calls `malloc`, `printf`, or any platform API.
- [ ] `pico/src/ui_logic.c` compiles cleanly into `host_harness` and (with `PICO_SDK_PATH` set) into Pico firmware.
- [ ] `wire_protocol.c` is the only place that touches byte layout for SPI.
- [ ] No file outside `fb_accessor.h` implementations touches FB memory directly.
- [ ] `tools/rom_to_mem.py` runs and emits `.mem` files matching the C source.
- [ ] README explains: how to run, how to add a UI state field (version-bump dance), how to add a sprite (C array → ROM rebuild), how to update goldens.

---

## 13. What we're explicitly NOT building yet

- Real Goodix I²C driver (`pico/src/touch_goodix.c` — stub). Pin down exact part + I²C address on hardware bring-up.
- Real Pico SPI master + DMA (HAL stub).
- Zynq-side anything; `synth_data.c` feeds magnitudes/GOES.
- Audio path. Out of scope for the frontend harness.
- SDRAM controller, line-buffer cache, arbiter — all modeled as "a flat array" on host. Real implementation is in the architecture doc, built on the gateware side later.
- Unix-socket SPI link — stub the function, leave for later.

---

## 14. Notes for design judgment calls

- If a sub-decision isn't covered here, prefer the choice that makes the FPGA port easier — fewer dynamic allocations, smaller fixed buffers, integer math, table lookups over computed values.
- Prefer slightly verbose C over clever C if the clever version uses features that don't translate cleanly to combinational logic.
- When in doubt about endianness, byte order, or struct packing: write the test before the code.

That's the brief. Build it, then we'll iterate against the architecture doc as gateware comes online.
