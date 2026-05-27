# Pico firmware build. Only included when -DBUILD_FIRMWARE=ON.
# Expects pico-sdk to be initialized by the parent (via pico_sdk_init()).
#
# Bring-up: see https://github.com/raspberrypi/pico-sdk for the standard
# import.cmake pattern. Add this once you have a Pico to flash:
#
#   include($ENV{PICO_SDK_PATH}/pico_sdk_init.cmake)
#   pico_sdk_init()

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
