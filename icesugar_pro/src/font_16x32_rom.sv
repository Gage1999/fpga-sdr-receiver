// 16x32 title/label font ROM — 96 glyphs (0x20..0x7F) x 32 rows of 16 bits.
//
// Backs pixel_shader's `font16_addr`/`font16_data` port. The shader does the
// ASCII range-check and index math itself (char_norm = c-0x20, addr =
// {char_norm, row}); this module is a dumb flat lookup, mirroring the memory
// pattern of font8x16_rom.sv but with the flat address the shader produces.
//
// Source of truth: icesugar_pro/model/src/font.c `font_16x32[]`. Regenerate
// the .mem with tools/rom_to_mem.py whenever the C array changes.
//
// (* ram_style = "logic" *) pushes this to LUT/FF logic rather than EBR — the
// handoff budgets the EBR blocks elsewhere and a constant ROM maps cheaply to
// logic. Functionally identical; the attribute is a synthesis hint only.
module font_16x32_rom #(
    parameter MEMFILE = "build/font_16x32.mem"
) (
    input  logic [11:0] addr,   // {char_idx[6:0], row[4:0]}, 0..3071
    output logic [15:0] data
);
    (* ram_style = "logic" *)
    logic [15:0] mem [0:3071];

    initial $readmemh(MEMFILE, mem);

    // Async (combinational) read: matches the C executable spec, which reads
    // the glyph row in the same per-pixel evaluation. The pixel_shader only
    // ever drives addr in 0..3071 (char clamped to [0x20,0x80)), so no
    // out-of-range access occurs.
    always_comb data = mem[addr];
endmodule
