# Host Model And Test Harness

This document describes the portable C model, host harness, and unit tests used
to validate UI and rendering behavior before it reaches hardware.

## Purpose

The project keeps shared UI/protocol logic in portable C so it can run in three
places:

| Location | Use |
|---|---|
| Host tests | Fast regression checks in CTest |
| Host harness | SDL preview of UI/rendering behavior |
| Pico firmware | Touch UI state machine |

The ECP5 pixel shader and compositor are hand-translated from the C reference
model into SystemVerilog. Golden-image tests and Verilator checks keep the two
implementations aligned.

## Portable Code Contract

Portable files avoid platform dependencies:

- No dynamic allocation
- No direct file or device I/O
- Fixed-width integer types for protocol-visible data
- Explicit little-endian packing for wire data
- Hardware-specific operations behind small HAL interfaces

Important paths:

| Path | Purpose |
|---|---|
| `shared/include/ui_state.h` | Packed UI state shared by host, Pico, and FPGA parser |
| `shared/include/wire_protocol.h` | `0xA5` frame format and opcodes |
| `shared/src/wire_protocol.c` | CRC, pack, and unpack helpers |
| `pico2w/src/ui_logic.c` | Portable UI state machine |
| `icesugar_pro/model/src/pixel_shader.c` | C reference for the live shader |
| `icesugar_pro/model/src/fb_compositor.c` | C reference for framebuffer operations |

## Host Harness

The optional SDL host harness builds when SDL2 is available:

```sh
cmake -B build -G Ninja
cmake --build build -j
./build/host_harness
```

On Windows, use Ninja with a GCC/Clang-style toolchain, MSYS2, or WSL. The root
CMake project currently uses GCC/Clang warning flags, so the Visual Studio
generator is not the recommended host-test path.

The harness simulates:

- Pico UI logic
- An in-process SPI link
- The FPGA-side rendering model
- Synthetic spectrum/waterfall/image data
- Mouse and keyboard input mapped to touch/UI events

It is a behavior preview, not a cycle-accurate SDRAM or FPGA timing simulator.

## Tests

Build and run host tests:

```sh
cmake -B build -G Ninja -DBUILD_HOST_HARNESS=OFF
cmake --build build -j
ctest --test-dir build --output-on-failure
```

CTest targets:

| Test | Coverage |
|---|---|
| `test_ui_state` | UI state defaults and packing expectations |
| `test_wire_protocol` | Frame encode/decode and CRC behavior |
| `test_pixel_shader` | Golden-image shader output |
| `test_fb_compositor` | Golden-image compositor behavior |
| `test_fb_buffering` | Framebuffer swap and access behavior |
| `test_ui_logic` | Touch/UI state-machine sequences |

Golden images live under `tests/golden/`. Update them only when the intended
visual behavior changes.

## Verilator Parity

The host C model also checks the RTL shader and ROM wrappers:

```sh
cmake -S . -B build -G Ninja -DBUILD_HOST_HARNESS=OFF
cmake --build build --target render_model shared
make -C icesugar_pro/sim run
```

These tests compare:

- Bare `pixel_shader.sv` against the C shader model
- `pixel_shader_top.sv` with generated ROM memories
- Generated `.mem` contents against the C ROM source arrays

## Adding Protocol Or UI Fields

When adding a field to `ui_state_t`:

1. Update `shared/include/ui_state.h`.
2. Bump `UI_STATE_VERSION`.
3. Update host and Pico UI logic.
4. Update ECP5 parsers if the field is consumed by hardware.
5. Add or update tests for the new behavior.

For fields that cross the wire, use fixed-size integer types and explicit
little-endian serialization.

## Adding Visual Assets

Font, sprite, and palette data live in the C model and are converted to FPGA
memory files by:

```sh
python3 tools/rom_to_mem.py --out icesugar_pro/build
```

The iCeSugar Makefile runs this automatically before synthesis and simulation.
