module spectrum_bin_ram #(
    parameter INIT_FILE = ""
) (
    // Write port.
    input logic wr_clk,
    input logic wr_en,
    input logic [7:0] wr_addr,
    input logic [15:0] wr_data,

    // Read port
    input logic [7:0] rd_addr,
    output logic [15:0] rd_data
);
    logic [15:0] mem [0:255];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always_comb rd_data = mem[rd_addr];
endmodule
