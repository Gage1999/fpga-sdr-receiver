cmake_minimum_required(VERSION 3.13)

# Standalone Pico 2 W bring-up tool, built independently of the main
# firmware (pico2w/CMakeLists.txt). PICO_SDK_PATH comes from the environment.
include(pico_sdk_import.cmake)

set(PICO_BOARD pico2_w CACHE STRING "Board type")

project(i2c_touch_probe C CXX ASM)

pico_sdk_init()

add_executable(i2c_touch_probe i2c_touch_probe.c)
target_link_libraries(i2c_touch_probe pico_stdlib hardware_i2c)

# Results over USB CDC serial; no debug probe / UART needed.
pico_enable_stdio_usb(i2c_touch_probe 1)
pico_enable_stdio_uart(i2c_touch_probe 0)

# Emit output as soon as USB enumerates, without waiting for the host to
# assert DTR (macOS cu/cat doesn't reliably raise it).
target_compile_definitions(i2c_touch_probe PRIVATE PICO_STDIO_USB_CONNECTION_WITHOUT_DTR=1)

pico_add_extra_outputs(i2c_touch_probe)
