module font8x16_rom (
    input logic [7:0] ascii,
    input logic [3:0] row,
    output logic [7:0] bits
);

logic [7:0] mem [0:1535];
logic [6:0] char_idx;
logic [10:0] addr;

initial begin
    $readmemh("build/font_8x16.mem", mem);
end

always_comb begin
    if (ascii < 8'h20 || ascii >= 8'h80)
        char_idx = 7'd31; // '?'
    else
        char_idx = ascii[6:0] - 7'd32;

    addr = {char_idx, row};
    bits = mem[addr];
end

endmodule
