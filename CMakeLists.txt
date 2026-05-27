cmake_minimum_required(VERSION 3.20)
project(fpga-sdr-receiver C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)
endif()

option(BUILD_HOST_HARNESS "Build the SDL host harness" ON)
option(BUILD_TESTS "Build host-side tests" ON)
option(BUILD_FIRMWARE "Build the Pico firmware (requires PICO_SDK_PATH)" OFF)

# Treat warnings strictly — this codebase wants discipline.
add_compile_options(
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion
    -Wno-unused-parameter
)

# ──────────────────────────────────────────────────────────────────────────────
# shared/ — portable C library, built once, linked by host harness, tests,
# and the Pico firmware. No malloc, no platform calls. The C is the executable
# spec the iCESugar-Pro gateware will mimic.
# ──────────────────────────────────────────────────────────────────────────────
add_library(shared STATIC
    shared/src/ui_state.c
    shared/src/wire_protocol.c
    shared/src/regions.c
    shared/src/pixel_shader.c
    shared/src/fb_compositor.c
    shared/src/font.c
    shared/src/sprites.c
    shared/src/palette.c
    shared/src/aux_roms.c
)
target_include_directories(shared PUBLIC shared/include)
target_compile_definitions(shared PUBLIC
    UI_STATE_VERSION=1
)

# ──────────────────────────────────────────────────────────────────────────────
# host/ — SDL window, in-process Pico↔FPGA SPI link, synth data feed.
# Live demo + manual exercise of the system. Not built in CI when SDL absent.
# ──────────────────────────────────────────────────────────────────────────────
if(BUILD_HOST_HARNESS)
    find_package(SDL2 QUIET)
    if(SDL2_FOUND)
        add_executable(host_harness
            host/src/main.c
            host/src/hal_host.c
            host/src/pico_sim.c
            host/src/fpga_sim.c
            host/src/fb_host.c
            host/src/spi_link.c
            host/src/input_map.c
            host/src/synth_data.c
            pico2w/src/ui_logic.c
        )
        target_include_directories(host_harness PRIVATE
            host/include
            pico2w/include
        )
        target_link_libraries(host_harness PRIVATE shared SDL2::SDL2 SDL2::SDL2main)
        target_compile_definitions(host_harness PRIVATE TRIAD_HOST=1)
    else()
        message(STATUS "SDL2 not found — host_harness target disabled. Install with: brew install sdl2")
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# tests/ — pure compute, no SDL. Goes green on GitHub Actions.
# ──────────────────────────────────────────────────────────────────────────────
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# ──────────────────────────────────────────────────────────────────────────────
# pico2w/ — Pico 2W build, only when PICO_SDK_PATH is provided.
# ──────────────────────────────────────────────────────────────────────────────
if(BUILD_FIRMWARE)
    if(NOT DEFINED ENV{PICO_SDK_PATH})
        message(FATAL_ERROR "BUILD_FIRMWARE=ON but PICO_SDK_PATH is not set")
    endif()
    add_subdirectory(pico2w)
endif()
