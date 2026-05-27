module i2s_tx #(
    parameter CLK_HZ = 25_000_000,
    parameter BCLK_DIV = 12,
    parameter SLOT_BITS = 32
)(
    input logic clk,
    input logic rst,

    input logic signed [15:0] left_in,
    input logic signed [15:0] right_in,
    output logic sample_req,

    output logic bclk,
    output logic lrclk,
    output logic sdata
);

localparam HALF = BCLK_DIV / 2;
localparam FRAME = 2 * SLOT_BITS;

logic [$clog2(BCLK_DIV)-1:0] clk_cnt = '0;
logic [$clog2(FRAME)-1:0] bit_cnt = '0;

logic signed [15:0] l_hold = '0, r_hold = '0;
logic [SLOT_BITS-1:0] l_word;
logic [SLOT_BITS-1:0] r_word;

assign l_word = {l_hold, 16'd0};
assign r_word = {r_hold, 16'd0};

initial begin
    bclk = 1'b1;
    lrclk = 1'b0;
    sdata = 1'b0;
    sample_req = 1'b0;
end

// BCLK
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        clk_cnt <= '0;
        bclk <= 1'b1;
    end else begin
        if (clk_cnt == BCLK_DIV - 1) begin
            clk_cnt <= '0;
            bclk <= 1'b1;
        end else begin
            clk_cnt <= clk_cnt + 1'b1;
            if (clk_cnt == HALF)
                bclk <= 1'b0;
        end
    end
end

// Serializer
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        bit_cnt <= '0;
        lrclk <= 1'b0;
        sdata <= 1'b0;
        l_hold <= '0;
        r_hold <= '0;
        sample_req <= 1'b0;
    end else if (clk_cnt == HALF) begin
        sample_req <= 1'b0;

        if (bit_cnt == FRAME - 1) begin
            l_hold <= left_in;
            r_hold <= right_in;
            sample_req <= 1'b1;
            bit_cnt <= '0;
            lrclk <= 1'b0;
            sdata <= r_word[0];
        end else begin
            bit_cnt <= bit_cnt + 1'b1;

            if (bit_cnt == 0) begin
                sdata <= l_word[SLOT_BITS-1];
            end else if (bit_cnt < SLOT_BITS - 1) begin
                sdata <= l_word[SLOT_BITS-1-bit_cnt];
            end else if (bit_cnt == SLOT_BITS - 1) begin
                lrclk <= 1'b1;
                sdata <= l_word[0];
            end else begin
                sdata <= r_word[2*SLOT_BITS-1-bit_cnt];
            end
        end
    end
end

endmodule

