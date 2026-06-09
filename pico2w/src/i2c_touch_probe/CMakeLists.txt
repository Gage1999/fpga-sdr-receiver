cmake_minimum_required(VERSION 3.13)

include(pico_sdk_import.cmake)

set(PICO_BOARD pico2_w CACHE STRING "Board type")

project(i2c_touch_probe C CXX ASM)

pico_sdk_init()

add_executable(i2c_touch_probe i2c_touch_probe.c)
target_link_libraries(i2c_touch_probe pico_stdlib hardware_i2c)

pico_enable_stdio_usb(i2c_touch_probe 1)
pico_enable_stdio_uart(i2c_touch_probe 0)

target_compile_definitions(i2c_touch_probe PRIVATE PICO_STDIO_USB_CONNECTION_WITHOUT_DTR=1)

pico_add_extra_outputs(i2c_touch_probe)
