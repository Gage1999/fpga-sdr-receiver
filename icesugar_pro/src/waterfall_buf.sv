module waterfall_buf #(
    parameter BINS = 256,
    parameter ROWS = 360
)(
    input logic clk,

    input logic [7:0] wr_magnitude,
    input logic wr_valid,

    input logic [7:0] rd_bin,
    input logic [8:0] rd_row_age,
    output logic [7:0] rd_magnitude,

    output logic [8:0] write_row
);

localparam ADDR_W = $clog2(BINS * ROWS);

logic [7:0] mem [0:BINS*ROWS-1];
logic [7:0] wr_bin;
logic [8:0] wr_row;

// Write
always_ff @(posedge clk) begin
    if (wr_valid) begin
        mem[{wr_row[8:0], wr_bin[7:0]}] <= wr_magnitude;
        if (wr_bin == BINS - 1) begin
            wr_bin <= 8'd0;
            wr_row <= (wr_row == ROWS - 1) ? 9'd0 : wr_row + 9'd1;
        end else begin
            wr_bin <= wr_bin + 8'd1;
        end
    end
end

assign write_row = wr_row;

// Read
logic [8:0] newest_row;
logic [8:0] eff_row;
logic [9:0] eff_row_wrap;

always_comb begin
    newest_row = (wr_row == 9'd0) ? 9'(ROWS - 1) : wr_row - 9'd1;
    eff_row_wrap = 10'd0;
    if (rd_row_age <= newest_row) begin
        eff_row = newest_row - rd_row_age;
    end else begin
        eff_row_wrap = 10'(newest_row) + 10'(ROWS) - 10'(rd_row_age);
        eff_row = eff_row_wrap[8:0];
    end
end

always_ff @(posedge clk)
    rd_magnitude <= mem[{eff_row[8:0], rd_bin[7:0]}];

initial begin
    wr_bin = 8'd0;
    wr_row = 9'd0;
end

endmodule

