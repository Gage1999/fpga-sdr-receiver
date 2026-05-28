# Pixel shader / FPGA integration — handoff

**Last updated:** 2026-05-28

Snapshot of where the FPGA-side renderer work stands, what's done, and
what's next. Companion to `fpga-sdr-receiver-architecture.md` (the
overall design) — that doc describes *what we're building*, this one
describes *how far in we are*.

---

## Current state at a glance

| Thing | Status |
|---|---|
| C reference model (`icesugar_pro/model/`) | Refactored: precompute split out from per-pixel path. All 5 golden tests pass. |
| `pixel_shader.sv` (Verilator sim) | **Full parity, 6/6 cases at 100% (2,304,000 / 2,304,000 px)** |
| Existing FM bitstream (`top.sv`) | Builds clean. LUT 15% / FF 10% / BRAM 87.5% / IO 14%. Timing has 2.5× headroom. |
| `scan_timing.sv` extracted from `lcd.sv` | Done. Same bitstream output, +73 LUTs (module-boundary overhead). |
| Partner's `sdram_ctrl.sv` (origin/main) | First commit landed (`b0b1aa2`). Single-client interface, request/grant style. See *open issues* below. |
| Pico firmware (`pico2w/`) | Skeleton only. `ui_logic.c` validated, but touch/SPI HAL and main loop are stubs. |
| SDRAM-side gateware (arbiter, scan-out, compositor) | Not started. |

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

## What's next

Prioritized list. Anything in P1/P2/P3 is independent of the SDRAM
controller working — they can be done while partner iterates on
`sdram_ctrl.sv`. P4 needs at least the mock SDRAM stack (#13–#15).

### P1 — Foundational, SDRAM-independent
All complete. ✅

### P2 — Build out the shader integration surface
- **#7 `sprite_rom.sv` + .mem generation** — mirror the
  `font8x16_rom.sv` pattern. Used by the sprite-backed buttons. Arch doc
  §5 budgets 11 EBR blocks; fits comfortably once waterfall moves to SDRAM.
- **#11 `font_16x32_rom.sv` + .mem** — same pattern. Add
  `(* ram_style = "logic" *)` to push to FFs (~3k FFs instead of 3 BRAMs).
- **#12 UI state shadow SV** — 1KB double-buffered EBR per arch doc §8.
  Pico SPI writes back buffer; shader reads front buffer; flip at V-sync.
  Needs an opcode parser front-end for `OP_FULL_STATE` /
  `OP_PARTIAL_STATE`. Output ports mirror the `shader_state_t` fields
  `pixel_shader.sv` already expects.

### P3 — Mock-SDRAM stack (sim only, no partner dependency)
- **#13 `mock_sdram.sv`** — implements partner's interface
  (`req_valid/ready/wr/addr/len`, `wr_data/valid/ready`, `rd_data/valid`,
  `done`) backed by a flat reg array or BRAM. Lets us develop and test
  scan-out / arbiter / compositor without real hardware.
- **#14 `sdram_arbiter.sv`** — 3-client fixed priority (scan-out >
  compositor > ingest). Sits between clients and the single-port
  controller. Per arch doc §3. (blocked by #13)
- **#15 `scan_out_reader.sv` + 4-deep line cache** — per arch doc §4. At
  H-blank of line N, kick burst read for line N+2 into a free cache slot.
  CDC point: true-dual-port EBR, write 100 MHz / read 30 MHz. (blocked
  by #14)

### P4 — Needs working SDRAM stack
- **#16 Compositor write-side FSMs** — `waterfall_step`,
  `goes_row_write`, `region_clear`, `adsb_frame`. Each drives the
  arbiter's compositor port. Validate against `fb_compositor.c` via a
  parity harness analogous to the shader one. (blocked by #14)
- **#17 Ingest writer** — drains existing `spi_iq_slave` / `async_fifo`
  IQ stream into target SDRAM regions. Also handles ADS-B basemap
  one-shot load via a new wire opcode from Pico. (blocked by #14)
- **#18 Integrate: replace `u_lcd` in `top.sv`** — wire scan_timing +
  scan_out_reader + line cache + pixel_shader + LCD pin driver,
  replacing current `u_lcd`. First end-to-end bitstream of the new
  architecture. (blocked by #7, #9, #10, #11, #12, #15, #16 — i.e.
  everything above except the SDRAM controller itself)

---

## Open issues with partner's SDRAM controller (`b0b1aa2`)

Worth discussing before #14 / #15 are written against the interface:

1. **Single-client interface.** Controller has one `req_valid/ready`
   pair, not per-client queues. Means the arbiter (#14) is now clearly
   *our* work, not the controller's. Confirm that's intended.
2. **`req_len` is 6-bit (max 63).** A full 800-pixel scan-out line is
   800 16-bit words. Either widen `req_len` to ≥10 bits, or have
   clients chunk into multiple back-to-back requests (slower due to
   per-burst RAS/CAS overhead).
3. **No explicit init-done signal.** `req_ready` presumably stays low
   during the 200 µs `S_INIT_*` states then goes high in `S_IDLE`;
   would be cleaner to expose as a dedicated `ready_after_init` output.
4. **No status/diagnostic ports** beyond `done`. For hardware bring-up,
   a current-state output and a refresh-count register would help.
5. **BL=8 in MODE_REG.** Confirm `req_len` is in 16-bit words (not BL=8
   groups) so requests aren't restricted to multiples of 8.
6. **Lattice config flash sharing.** No SPI flash master included.
   Per the discussion in this session: ADS-B basemap will load from
   Pico (extended wire protocol) rather than direct flash access.

These don't block #13 (mock SDRAM) — we can implement the mock against
the *intended* contract while these are sorted out.

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
cmake --build build
ctest --test-dir build --output-on-failure

# Verilator parity harness (6 cases, 100% expected)
cd icesugar_pro/sim
make run

# Bitstream still builds
cd ../..  # back to icesugar_pro/
source ~/oss-cad-suite/environment    # or: fpga (the user's alias)
make build/top.bit
# Expect: ~49/56 DP16KD, ~3776 LUTs, all clocks PASS
```

If any of these regress, something landed on `main` that shouldn't have.
The parity harness is the canary for the shader; the goldens are the
canary for the C model.

---

## Files touched this session

```
icesugar_pro/model/include/pixel_shader.h    (modified — added shader_state_t)
icesugar_pro/model/src/pixel_shader.c        (modified — split prepare / pixel)
icesugar_pro/src/scan_timing.sv              (new — extracted from lcd.sv)
icesugar_pro/src/lcd.sv                      (modified — uses scan_timing)
icesugar_pro/Makefile                        (modified — added scan_timing.sv)
icesugar_pro/sim/.gitignore                  (new)
icesugar_pro/sim/Makefile                    (new — Verilator parity build)
icesugar_pro/sim/pixel_shader.sv             (new — SV translation of pixel_shader)
icesugar_pro/sim/tb_pixel_shader.cpp         (new — C++ parity testbench)
tests/test_pixel_shader.c                    (modified — calls prepare)
host/src/fpga_sim.c                          (modified — calls prepare)
docs/fpga-shader-handoff.md                  (new — this doc)
```

---

## Recommended next move

#7 + #11 together — both are mechanical `font8x16_rom.sv`-pattern
modules with associated `rom_to_mem.py` updates. ~1 session.

Then #12 (UI state shadow + SPI opcode parser) is the next meaty
piece — needs more design thought (double-buffer flip timing,
back-buffer write coherence) but unblocks everything from #18.

Anything beyond that needs at least the mock SDRAM (#13) so #14/#15
can be developed against it.
