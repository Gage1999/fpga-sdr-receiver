cmake_minimum_required(VERSION 3.20)

option(BUILD_FIRMWARE "Build the Pico firmware (requires PICO_SDK_PATH)" OFF)
if(BUILD_FIRMWARE)
    if(DEFINED ENV{PICO_SDK_PATH})
        set(PICO_SDK_IMPORT "$ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake")
    elseif(PICO_SDK_PATH)
        set(PICO_SDK_IMPORT "${PICO_SDK_PATH}/external/pico_sdk_import.cmake")
    else()
        message(FATAL_ERROR "BUILD_FIRMWARE=ON but PICO_SDK_PATH is not set")
    endif()
    include("${PICO_SDK_IMPORT}")
endif()

project(fpga-sdr-receiver C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(BUILD_FIRMWARE)
    set(CMAKE_C_EXTENSIONS ON)
else()
    set(CMAKE_C_EXTENSIONS OFF)
endif()
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)
endif()

option(BUILD_HOST_HARNESS "Build the SDL host harness" ON)
option(BUILD_TESTS "Build host-side tests" ON)

add_compile_options(
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion
    -Wno-unused-parameter
)

add_library(shared STATIC
    shared/src/ui_state.c
    shared/src/wire_protocol.c
)
target_include_directories(shared PUBLIC shared/include)
target_compile_definitions(shared PUBLIC
    UI_STATE_VERSION=3
)

add_library(render_model STATIC
    icesugar_pro/model/src/regions.c
    icesugar_pro/model/src/pixel_shader.c
    icesugar_pro/model/src/fb_compositor.c
    icesugar_pro/model/src/font.c
    icesugar_pro/model/src/sprites.c
    icesugar_pro/model/src/palette.c
    icesugar_pro/model/src/aux_roms.c
)
target_include_directories(render_model PUBLIC icesugar_pro/model/include)
target_link_libraries(render_model PUBLIC shared)

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
        target_link_libraries(host_harness PRIVATE render_model SDL2::SDL2 SDL2::SDL2main)
        target_compile_definitions(host_harness PRIVATE TRIAD_HOST=1)
    else()
        message(STATUS "SDL2 not found - host_harness target disabled. Install with: brew install sdl2")
    endif()
endif()

if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(BUILD_FIRMWARE)
    pico_sdk_init()
    add_subdirectory(pico2w)
endif()
