// Sprite ROM — 16 sprites x 32x32 px x RGB565 = 16384 halfwords.
//
// Backs pixel_shader's `sprite_addr`/`sprite_data` port. The shader forms the
// flat address itself (sprite_addr = {sprite_id[3:0], spy[4:0], spx[4:0]});
// this module is a dumb flat lookup, mirroring font8x16_rom.sv.
//
// Source of truth: icesugar_pro/model/src/sprites.c `sprite_rom[]`. Regenerate
// the .mem with tools/rom_to_mem.py whenever the C array changes. A pixel value
// of 0x0000 is the transparency sentinel (the shader maps it to the button bg).
//
// No ram_style hint: this is large enough (256 Kbit) that EBR inference is the
// right mapping — the architecture doc §5 budgets 11 DP16KD blocks for it.
module sprite_rom #(
    parameter MEMFILE = "build/sprite_rom.mem"
) (
    input  logic [13:0] addr,   // sprite_id*1024 + spy*32 + spx, 0..16383
    output logic [15:0] data
);
    logic [15:0] mem [0:16383];

    initial $readmemh(MEMFILE, mem);

    // Async read: matches the per-pixel C spec (same-evaluation lookup).
    always_comb data = mem[addr];
endmodule
