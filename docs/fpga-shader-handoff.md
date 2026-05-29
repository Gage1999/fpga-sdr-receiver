# Pixel shader / FPGA integration — handoff

**Last updated:** 2026-05-29 (post SDRAM-stack merge, PR #4)

Snapshot of where the FPGA-side renderer work stands, what's done, and
what's next. Companion to `fpga-sdr-receiver-architecture.md` (the
overall design) — that doc describes *what we're building*, this one
describes *how far in we are*.

---

## Current state at a glance

| Thing | Status |
|---|---|
| C reference model (`icesugar_pro/model/`) | Refactored: precompute split out from per-pixel path. All 5 golden tests pass. |
| `pixel_shader.sv` (now in `icesugar_pro/src/`) | **Full parity, 6/6 cases at 100% (2,304,000 / 2,304,000 px)** — both bare core and end-to-end through the wrapper. |
| Shader memories + wrapper (`font_16x32_rom`, `sprite_rom`, `spectrum_bin_ram`, `pixel_shader_top`) | **Done.** Synthesizable; yosys `synth_ecp5` clean (no latches/warnings). Shader is now a self-contained block, no loose ROM ports. |
| Existing FM bitstream (`top.sv`) | Builds clean (re-verified with oss-cad-suite). DP16KD 49/56 (87.5%) · LUT 3714/24288 (15%) · FF 2392 (9%) · IO 28/197 (14%). All clocks PASS. |
| FPGA toolchain | **Installed** at `~/oss-cad-suite` (release 2026-05-28): yosys 0.65, nextpnr-ecp5 0.10, ecppack 1.4. Verilator 5.020 via apt. |
| `scan_timing.sv` extracted from `lcd.sv` | Done. Same bitstream output, +73 LUTs (module-boundary overhead). |
| SDRAM stack (`sdram_ctrl`, `sdram_arb`, `scan_out`, `line_cache`, `compositor`) | **Landed** (PR #4, `f52c78b`). All 7 `make sim_integration` tbs pass. `top_sdram_wf` proves the full read/write/CDC chain at **5/56 DP16KD**. Compositor = waterfall_step only. See "SDRAM stack landed" below. |
| Shader ↔ SDRAM integration | **Not wired.** `top_sdram_wf` sends raw FB → LCD; `pixel_shader_top` is in nothing but its parity harness. This is gap #18. |
| Pico firmware (`pico2w/`) | Skeleton only. `ui_logic.c` validated, but touch/SPI HAL and main loop are stubs. |

---

## What landed this session

Commits in order, all on `main`:

1. `80eba89` — **shader: split per-frame precompute from per-pixel path**
   - Introduced `shader_state_t` + `pixel_shader_prepare()` in C.
   - Lifted `format_freq_mhz`, `label_origin`, volume scaling, demod label,
     RDS line build, mute-sprite select out of the per-pixel function.
   - Goldens unchanged byte-for-byte. Callers (`test_pixel_shader.c`,
     `host/src/fpga_sim.c`) updated to call `prepare` once per frame.

2. `31a10cc` — **sim: add Verilator parity harness for pixel_shader**
   - New `icesugar_pro/sim/` with `pixel_shader.sv`, `tb_pixel_shader.cpp`,
     `Makefile`. Drives Verilated SV against the C reference, byte-compares.
   - All shade_* paths implemented: region dispatch, overlay, spectrum,
     status (text + buttons + sprite ROM). Spectrum-only layout: 100%.

3. `ffe363e` — **lcd: extract scan_timing into its own module**
   - `scan_timing.sv` owns HSYNC counters + DE generation (parameterized
     for 800×480/928×525 per arch doc §2). `lcd.sv` is now pure pixel logic.
   - No behavior change; bitstream still timing-clean.

4. `2ef30c1` — **sim: add GOES + ADS-B layout cases to parity harness**
   - Added `goes_layout` + `adsb_layout` test cases. Initially exposed the
     stubbed `shade_image_mode_button` as 9216 missing px (99.40% / 98.20%).

5. `b81c5fd` — **sim: translate shade_image_mode_button — full parity on image layouts**
   - Image-layout floating MODE / ZOOM_IN / ZOOM_OUT buttons. Unified
     status-bar and image-layout button rendering via `any_btn_*` mux on
     {id, x0, bg, is_text}. All 6 parity cases at 100%.

---

## This session — synthesizable shader block + budget verification

The shader was parity-correct but still a *harness artifact*: `pixel_shader.sv`
exposed raw ROM address/data ports backed by C arrays in the testbench. This
session turned it into a self-contained, synthesizable hardware block and
verified resource budget on the real ECP5 toolchain.

**Done:**

- **Moved** `pixel_shader.sv` `sim/` → `src/` (it is RTL; one source of truth,
  now compiled by both the parity harness and synthesis).
- **`src/font_16x32_rom.sv`** (#11) — flat async ROM, 3072×16, `(* ram_style =
  "logic" *)`, `$readmemh build/font_16x32.mem`.
- **`src/sprite_rom.sv`** (#7) — flat async ROM, 16384×16.
- **`src/spectrum_bin_ram.sv`** — 256×16 dual-port (clocked write / async read).
- **`src/pixel_shader_top.sv`** — synthesizable wrapper wiring the shader to all
  three memories. This is the block `top.sv` instantiates at #18.
- **Build/verify:** `tools/rom_to_mem.py` already emits all ROMs. New Verilator
  harnesses (`tb_pixel_shader_top.cpp` end-to-end, `tb_rom_check.cpp`
  `.mem`-vs-C). `make synth_shader` (yosys) added. Fixed a `_Static_assert`
  GCC-vs-clang portability gap that blocked the harness on Linux.

**Verified green (real tools — Verilator 5.020 + oss-cad-suite 2026-05-28):**

- C goldens 6/6 · bare shader parity 6/6 (2.3M px) · **wrapper end-to-end parity
  6/6 with real `.mem` ROMs + spectrum RAM** · ROM equivalence exact
  (3072/3072 + 16384/16384) · `verilator --lint-only -Wall` clean · `yosys
  synth_ecp5` clean (no latches/warnings).

### Budget (assuming framebuffers/waterfall move to SDRAM)

Measured, not estimated. Baseline `top.bit` reproduces 49/56 DP16KD (45 =
waterfall `u_wf`, 4 = FFT ping-pong).

The shader's async-read ROMs (the current parity-faithful form) **can't** map to
EBR — EBR read is synchronous — so yosys maps them to logic/distributed RAM:

| Memory | Current async form | #18 sync-read EBR form (measured) |
|---|---|---|
| `font_16x32_rom` | LUT logic (ram_style=logic) | **3** DP16KD |
| `sprite_rom` | LUT logic (sparse → folds small) | **15** DP16KD (full 16 sprites) |
| `spectrum_bin_ram` | `TRELLIS_DPR16X4` distributed LUTRAM ✓ | **1** DP16KD |
| **shader total** | **0 DP16KD**, ~2.6k LUT4, 32 DPR16X4, 3 DSP, ~0 FF | **19 DP16KD** |

**Decision: use the sync-read EBR form** (see Decisions above). With the
waterfall now in SDRAM (measured: `top_sdram_wf` = 5/56), there's ample EBR,
so the shader ROMs map to BRAM rather than the async-LUT dodge. The async
form's apparent 0-DP16KD cost was also misleading — `sprite_rom` folds cheaply
only because most of the 16 sprite slots are still blank; the sync-read form
(15 DP16KD) is flat regardless of contents.

**Projected integrated budget** for the new SDRAM top (#18):

| Block | DP16KD |
|---|---:|
| FFT ping-pong buffers | 4 |
| line_cache (4×1024×16) | 4 |
| shader ROMs (sprite 15 + font16 3 + spectrum 1) | 19 |
| waterfall staging / misc | ~1 |
| **projected total** | **~28 / 56 (50%)** |

Comfortably within budget, ~28 blocks free — versus the 87.5% the BRAM-waterfall
`top.sv` was pinned at. LUT/FF/DSP all well under 50%.

---

## SDRAM stack landed (PR #4, `f52c78b`)

Partner's drop went well past the controller and collapsed most of the
P3/P4 SDRAM tasks. All 7 integration sims pass (`make sim_integration`):

- **`sdram_ctrl.sv`** — controller. `req_len` widened to 10-bit (full
  512-word page); `BURST_MODE` (full-page vs BL=8) and `RD_LAT`
  parameterized. `req_ready` held low during the ~200 µs init so clients
  can't issue early (init-gating issue resolved). Closes-row policy.
- **`sdram_arb.sv`** (was #14) — 3-client fixed priority (0=scan_out >
  1=compositor > 2=ingest), no preemption, read-data broadcast with
  per-lane `rd_valid`. Matches arch §3. ✅
- **`scan_out.sv` + `line_cache.sv`** (was #15) — page-aligned segment
  splitting, waterfall base-row modulo, CDC line cache (4×1024×16 =
  4 EBR, registered read). ✅
- **`compositor.sv`** (part of #16) — `waterfall_step` only: mag row →
  RGB565 → page-split burst write + base-row bump. `TEST_PATTERN` mode.
  `goes_row_write` / `adsb_frame` not built; `region_clear` exists only
  as an inline startup-clear FSM in `top_sdram_wf`. ⚠️ partial
- **`top_sdram_wf/color/cal.sv`** — bring-up tops proving the full
  read/write/CDC chain. `top_sdram_wf` measures **5/56 DP16KD** (vs
  49/56 for the BRAM-waterfall `top.sv`) — the framebuffer→SDRAM
  migration reclaims ~44 blocks as designed.

**Known design note:** the tops run `MAX_BURST=256` + `HALF_PAGE=1`
(256 words/SDRAM row) to dodge the marginal 512-column page-boundary
case. `scan_out` and `compositor` **must share the same `HALF_PAGE`**
or their addressing diverges. Uses 2× SDRAM rows — irrelevant at 32 MB.

## Decisions (2026-05-29)

- **Shader ROMs map to BRAM** (sync-read EBR form, ~19 DP16KD: sprite 15,
  font16 3, spectrum 1). The async-LUT form was only a BRAM-saving dodge;
  with the waterfall now in SDRAM there's ample EBR, so use it. **This
  means #18 registers the ROM reads** (arch §9 "1-cycle ROM-lookup
  pipeline") — which also fixes pixel-clock timing. The combinational
  parity harness must grow a pipeline-aware mode, or keep the
  combinational core for parity and wrap a registered-read version for
  synthesis.
- **Integration targets a new SDRAM top**, NOT `top.sv`. The FM
  BRAM-waterfall bitstream is left as-is; the shipping renderer is a new
  top descended from `top_sdram_wf`.

## What's next

### Done
P1 (parity harness, scan_timing, image-mode buttons) · P2 ROMs (#7, #11) ·
SDRAM stack (#14, #15, #16-waterfall) — all complete.

### #12 — UI state shadow SV (next; unblocked)
1KB double-buffered EBR per arch doc §8. Pico SPI writes back buffer;
shader reads front buffer; flip at V-sync. Needs an opcode parser
front-end for `OP_FULL_STATE` / `OP_PARTIAL_STATE`. Output ports mirror
the `shader_state_t` fields `pixel_shader.sv` already consumes. This is
the source of the shader's prepared inputs — without it the shader has
nothing to render, so it gates #18.

### #18 — Integrate the shader into a new SDRAM top (the headline gap)
Today `top_sdram_wf` sends the raw framebuffer pixel straight to the LCD
(`px_data → LCD_R/G/B`); `pixel_shader_top` is in nothing but its parity
harness. Build a new top that wires:
`scan_timing → (x,y)` · `line_cache.r_data → fb_under` · UI shadow front
buffer → shader prepared inputs · `pixel_shader_top → LCD pins`.
Two integration details to get right:
- `line_cache` read is registered (1-cycle); reconcile against `(x,y)`
  via the read-one-line-ahead scheme so pixel and FB byte align.
- ROM reads become registered (per the decision above) — pipeline the
  shader by a cycle, absorbed by the line cache.
(blocked by #12)

### Remaining compositor / ingest work
- **#16 remainder** — `goes_row_write`, `adsb_frame`, and a reusable
  `region_clear` op. Only the image modes need these; lower priority.
- **#17 Ingest writer** — wire the existing `spi_iq_slave` / `async_fifo`
  IQ stream into the compositor (replacing `top_sdram_wf`'s synthetic
  generator). Plus ADS-B basemap one-shot load via a new Pico wire opcode.

---

## SDRAM controller open issues — status after PR #4

The earlier interface concerns, reconciled against the landed code:

1. **Single-client interface** — confirmed intended; `sdram_arb.sv`
   provides the per-client queues on top. ✅ resolved
2. **`req_len` too narrow** — now 10-bit (full 512-word page). ✅ resolved
3. **No explicit init-done** — `req_ready` held low through the ~200 µs
   init, high in `S_IDLE`; functionally gates clients. No dedicated
   `init_done` output, but the arbiter just waits on `req_ready`, so a
   client's first request blocks until init completes. ✅ acceptable
4. **No status/diagnostic ports** — `sdram_arb` exposes `gnt_valid`/`gnt`;
   controller still only exposes `done`. ⚠️ minor, add if HW bring-up needs it
5. **BL=8 vs words** — `BURST_MODE` param; `req_len` is in 16-bit words. ✅ resolved
6. **Config flash / basemap load** — still open; ADS-B basemap loads from
   Pico (extended wire protocol), part of #17. ⏳ deferred

---

## BRAM headroom plan

Current bitstream: 49 / 56 DP16KD blocks (87.5%).

Of the 49, 44 are the waterfall buffer (`u_wf.mem`, 256×360×8) and 4 are
the FFT ping-pong buffers. Per the existing arch and the user's
roadmap, **the waterfall is slated for SDRAM streaming through a
smaller BRAM staging buffer.** When that lands, BRAM utilization drops
to roughly:

- FFT ping-pong: 4 blocks (stays)
- Line cache (4× 1600 B): 3 blocks
- font_16x32: 3 blocks (or 0 if FF-mapped)
- sprite ROM: 11 blocks (per arch doc §5)
- UI state shadow: 1 block
- spectrum bin RAM: 1 block
- waterfall staging line buffer: 1 block

= ~23 / 56, comfortable with ~33 blocks free for late additions.

So nothing about the new renderer needs BRAM optimization right now —
just make sure waterfall→SDRAM migration is the first thing that
happens once the controller is wired (arch doc §10 step 6, which is
also when scan_out_reader needs to be working).

---

## Pico firmware state

Skeleton present; *not* deployment-ready. From this session's audit:

- ✅ `ui_logic.c` (222 lines) — gesture detection, UI state mutation,
  validated by `test_ui_logic` in the host harness.
- ⚠️ `main.c` (29 lines) — stub. Tick loop sketched, doesn't poll touch
  or send SPI.
- ⚠️ `hal_pico.c` — stubs. `hal_touch_poll` returns false. `hal_spi_send`
  is raw bytes (no wire-protocol framing).
- ⚠️ `touch_goodix.c` — pure stub. Goodix part number not pinned down.
- ⚠️ `CMakeLists.txt` — `pico_sdk_init()` is in a comment block.

Pico bring-up is a parallel track. Estimated 2–3 focused sessions with
the board in hand. Not blocking any FPGA-side work.

---

## How to verify state locally

```sh
# C model still passes goldens
cd <repo root>
cmake -S . -B build -DBUILD_HOST_HARNESS=OFF && cmake --build build
ctest --test-dir build --output-on-failure        # 6/6 expected

# Verilator: bare-core parity + end-to-end wrapper parity + ROM .mem-vs-C
cd icesugar_pro/sim
make run        # run_shader 6/6 100%, run_top 6/6 100%, run_rom PASS
make lint       # verilator --lint-only -Wall on the synthesizable hierarchy

# FPGA toolchain
source ~/oss-cad-suite/environment    # or: fpga (the user's alias)

# Existing FM bitstream still builds
cd ..           # icesugar_pro/
make build/top.bit
# Expect: 49/56 DP16KD, 3714 LUTs, FF 2392, all clocks PASS

# Shader block synthesizes clean + area check
make synth_shader     # yosys synth_ecp5 -> build/shader.json (+ build/shader_synth.log)
```

If any of these regress, something landed on `main` that shouldn't have.
The parity harness is the canary for the shader; the goldens are the
canary for the C model.

**In CI** (`.github/workflows/ci.yml`): the `build-and-test` job runs the
C goldens (ctest) on Linux + macOS; the `shader-rtl` job (Linux, apt
verilator) runs `make -C icesugar_pro/sim lint` then `make … run`, so the
shader RTL canary fires on every push/PR — not just when someone
remembers to run it locally. The bitstream build (`make build/top.bit`)
and `synth_shader` still need the oss-cad-suite toolchain and are
local-only.

---

## Files touched — synthesizable shader block (this session)

```
icesugar_pro/src/pixel_shader.sv             (moved from sim/ — single source of truth)
icesugar_pro/src/font_16x32_rom.sv           (new — #11, flat async ROM 3072x16)
icesugar_pro/src/sprite_rom.sv               (new — #7, flat async ROM 16384x16)
icesugar_pro/src/spectrum_bin_ram.sv         (new — 256x16 dual-port, clocked wr / async rd)
icesugar_pro/src/pixel_shader_top.sv         (new — synthesizable wrapper: shader + 3 memories)
icesugar_pro/Makefile                        (modified — added synth_shader target)
icesugar_pro/sim/Makefile                    (modified — 3 harnesses + lint + mem gen; _Static_assert fix)
icesugar_pro/sim/.gitignore                  (modified — obj_shader/ obj_top/ obj_rom/ build/)
icesugar_pro/sim/rom_check_top.sv            (new — test-only top for ROM sweep)
icesugar_pro/sim/tb_pixel_shader_top.cpp     (new — end-to-end wrapper parity vs C)
icesugar_pro/sim/tb_rom_check.cpp            (new — .mem-vs-C ROM equivalence sweep)
docs/fpga-shader-handoff.md                  (modified — this update)
```

## Files touched — shader translation (earlier session)

```
icesugar_pro/model/include/pixel_shader.h    (modified — added shader_state_t)
icesugar_pro/model/src/pixel_shader.c        (modified — split prepare / pixel)
icesugar_pro/src/scan_timing.sv              (new — extracted from lcd.sv)
icesugar_pro/src/lcd.sv                      (modified — uses scan_timing)
icesugar_pro/Makefile                        (modified — added scan_timing.sv)
icesugar_pro/sim/Makefile                    (new — Verilator parity build)
icesugar_pro/sim/tb_pixel_shader.cpp         (new — C++ parity testbench)
tests/test_pixel_shader.c                    (modified — calls prepare)
host/src/fpga_sim.c                          (modified — calls prepare)
docs/fpga-shader-handoff.md                  (new — this doc)
```

---

## Recommended next move

#7 + #11 + the spectrum RAM + the `pixel_shader_top` wrapper are done — the
shader is a complete synthesizable block and the budget is verified. The next
meaty piece is **#12 (UI state shadow + SPI opcode parser)**, which feeds the
wrapper's prepared-state ports and unblocks everything from #18.

#12 has a real design fork to settle first: **who runs
`pixel_shader_prepare()`?** The wire protocol (`wire_pack_full`) currently sends
raw `ui_state_t` (freq_hz, volume, rds_text, …), but the wrapper's inputs are
the *prepared* fields (freq_text, label origins, volume_fill_px, …). Either:
  (a) the **Pico** runs `prepare()` and the shadow stores prepared state (small
      FPGA-side shadow, but changes the SPI contract / Pico firmware), or
  (b) the **FPGA** stores raw `ui_state` and a small V-blank "prepare engine"
      computes the derived fields in hardware (keeps the contract, but
      `format_freq_mhz` division + the `label_origin` glyph scan become gateware).
Decide this before writing #12.

Anything beyond that needs at least the mock SDRAM (#13) so #14/#15 can be
developed against it. At #18, register the ROM reads (sync-read EBR, arch §9) —
the budget table above uses that form.
