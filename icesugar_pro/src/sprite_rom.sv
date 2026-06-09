module sprite_rom #(
    parameter MEMFILE = "build/sprite_rom.mem"
) (
    input logic [13:0] addr,
    output logic [15:0] data
);
    logic [15:0] mem [0:16383];

    initial $readmemh(MEMFILE, mem);

    always_comb data = mem[addr];
endmodule
