// 16x32 title/label font ROM - 96 glyphs (0x20..0x7F) x 32 rows of 16 bits.
module font_16x32_rom #(
    parameter MEMFILE = "build/font_16x32.mem"
) (
    input  logic [11:0] addr,   // {char_idx[6:0], row[4:0]}, 0..3071
    output logic [15:0] data
);
    (* ram_style = "logic" *)
    logic [15:0] mem [0:3071];

    initial $readmemh(MEMFILE, mem);

    always_comb data = mem[addr];
endmodule
