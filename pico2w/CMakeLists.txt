# Pico firmware build. Only included when -DBUILD_FIRMWARE=ON.
# Expects the root CMakeLists.txt to import the Pico SDK before project()
# and call pico_sdk_init() before adding this directory.

add_executable(pico_firmware
    src/main.c
    src/hal_pico.c
    src/touch_goodix.c
    src/ui_logic.c
)
target_compile_definitions(pico_firmware PRIVATE TRIAD_FIRMWARE=1)
target_include_directories(pico_firmware PRIVATE include)
target_link_libraries(pico_firmware PRIVATE
    shared
    pico_stdlib
    hardware_spi
    hardware_i2c
)
pico_add_extra_outputs(pico_firmware)
