module rom_check_top (
    input  logic [11:0] font_addr,
    output logic [15:0] font_data,
    input  logic [13:0] sprite_addr,
    output logic [15:0] sprite_data
);
    font_16x32_rom u_font (.addr(font_addr), .data(font_data));
    sprite_rom     u_spr  (.addr(sprite_addr), .data(sprite_data));
endmodule
