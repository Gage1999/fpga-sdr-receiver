module i2s_tx #(
    parameter int CLK_HZ = 25_000_000,
    parameter int AUDIO_RATE = 43_625,
    parameter int SLOT_BITS = 32,
    parameter int BCLK_HALF_CYCLES = 0
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

localparam int FRAME = 2 * SLOT_BITS;
localparam int BCLK_HALF_INC = AUDIO_RATE * FRAME * 2;
localparam int BCLK_CNT_W = (BCLK_HALF_CYCLES > 1) ? $clog2(BCLK_HALF_CYCLES) : 1;

logic [31:0] bclk_acc;
logic bclk_tick;
logic [BCLK_CNT_W-1:0] bclk_cnt;

wire bclk_fall = bclk_tick & ~bclk;

logic [$clog2(FRAME)-1:0] bit_cnt = '0;
logic signed [15:0] l_hold = '0, r_hold = '0;
logic [SLOT_BITS-1:0] l_word, r_word;

assign l_word = {l_hold, 16'd0};
assign r_word = {r_hold, 16'd0};

initial begin
    bclk = 1'b1;
    lrclk = 1'b0;
    sdata = 1'b0;
    sample_req = 1'b0;
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        bclk_acc <= '0;
        bclk_cnt <= '0;
        bclk_tick <= 1'b0;
        bclk <= 1'b1;
    end else begin
        bclk_tick <= 1'b0;
        if (BCLK_HALF_CYCLES != 0) begin
            if (bclk_cnt == BCLK_HALF_CYCLES - 1) begin
                bclk_cnt <= '0;
                bclk_tick <= 1'b1;
                bclk <= ~bclk;
            end else begin
                bclk_cnt <= bclk_cnt + 1'b1;
            end
        end else begin
            if (bclk_acc + BCLK_HALF_INC >= CLK_HZ) begin
                bclk_acc <= bclk_acc + BCLK_HALF_INC - CLK_HZ;
                bclk_tick <= 1'b1;
                bclk <= ~bclk;
            end else begin
                bclk_acc <= bclk_acc + BCLK_HALF_INC;
            end
        end
    end
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        bit_cnt <= '0;
        lrclk <= 1'b0;
        sdata <= 1'b0;
        l_hold <= '0;
        r_hold <= '0;
        sample_req <= 1'b0;
    end else begin
        sample_req <= 1'b0;

        if (bclk_fall) begin
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
end

endmodule
