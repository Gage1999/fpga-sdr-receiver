function(add_triad_test name)
    set(srcs ${ARGN})
    add_executable(${name} ${srcs})
    target_link_libraries(${name} PRIVATE render_model)
    target_include_directories(${name} PRIVATE
        ${CMAKE_SOURCE_DIR}/pico2w/include
    )
    # Run from repo root so relative golden paths resolve consistently.
    add_test(NAME ${name}
             COMMAND ${name}
             WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
endfunction()

add_triad_test(test_ui_state       test_ui_state.c)
add_triad_test(test_wire_protocol  test_wire_protocol.c)
add_triad_test(test_pixel_shader   test_pixel_shader.c test_fb_host.c)
add_triad_test(test_fb_compositor  test_fb_compositor.c test_fb_host.c)
add_triad_test(test_fb_buffering   test_fb_buffering.c test_fb_host.c)
add_triad_test(test_ui_logic       test_ui_logic.c ${CMAKE_SOURCE_DIR}/pico2w/src/ui_logic.c)
