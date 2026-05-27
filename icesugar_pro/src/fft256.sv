module fft256 (
    input logic clk,
    input logic rst,

    input logic signed [15:0] i_in,
    input logic signed [15:0] q_in,
    input logic in_valid,

    output logic [7:0] bin_magnitude,
    output logic [7:0] bin_index,
    output logic bin_valid
);

localparam FILL = 4'd0;
localparam SETUP = 4'd1;
localparam READ_A = 4'd2;
localparam READ_B = 4'd3;
localparam LOAD_B = 4'd4;
localparam START = 4'd5;
localparam BF_START = 4'd6;
localparam WAIT0 = 4'd7;
localparam WAIT1 = 4'd8;
localparam WRITE_A = 4'd9;
localparam WRITE_B = 4'd10;
localparam OUT_SETUP = 4'd11;
localparam OUT_WAIT = 4'd12;
localparam OUTPUT = 4'd13;

logic [3:0] state;

logic fill_bank;
logic comp_bank;
logic [1:0] bank_full;

logic [7:0] fill_cnt;
logic [2:0] stage;
logic [6:0] bfly_cnt;
logic [7:0] out_cnt;

logic [7:0] idx_a, idx_b;
logic [7:0] span, half_span;
logic [7:0] group_base, k_in_group;
logic [6:0] tw_addr;

logic [7:0] rd_addr0, rd_addr1;
logic [7:0] wr_addr0, wr_addr1;
logic signed [15:0] wr_data0_r, wr_data0_i;
logic signed [15:0] wr_data1_r, wr_data1_i;
logic signed [15:0] rd_data0_r, rd_data0_i;
logic signed [15:0] rd_data1_r, rd_data1_i;
logic we0_r, we0_i, we1_r, we1_i;

logic signed [15:0] ar, ai, br, bi;
logic signed [15:0] wr, wi;
logic signed [15:0] pr, pi, qr, qi;
logic bfly_in_valid;
logic bfly_out_valid;
logic capture_ok;

function [7:0] bitrev8(input [7:0] x);
    integer n;
    begin
        for (n = 0; n < 8; n = n + 1)
            bitrev8[n] = x[7-n];
    end
endfunction

function [7:0] abs16_hi(input logic signed [15:0] x);
    logic signed [15:0] neg_x;
    begin
        neg_x = -x;
        if (x == -16'sd32768)
            abs16_hi = 8'hff;
        else if (x[15])
            abs16_hi = neg_x[15:8];
        else
            abs16_hi = x[15:8];
    end
endfunction

ram256x16 u_buf0_r (
    .clk (clk),
    .we (we0_r),
    .waddr (wr_addr0),
    .wdata (wr_data0_r),
    .raddr (rd_addr0),
    .rdata (rd_data0_r)
);

ram256x16 u_buf0_i (
    .clk (clk),
    .we (we0_i),
    .waddr (wr_addr0),
    .wdata (wr_data0_i),
    .raddr (rd_addr0),
    .rdata (rd_data0_i)
);

ram256x16 u_buf1_r (
    .clk (clk),
    .we (we1_r),
    .waddr (wr_addr1),
    .wdata (wr_data1_r),
    .raddr (rd_addr1),
    .rdata (rd_data1_r)
);

ram256x16 u_buf1_i (
    .clk (clk),
    .we (we1_i),
    .waddr (wr_addr1),
    .wdata (wr_data1_i),
    .raddr (rd_addr1),
    .rdata (rd_data1_i)
);

butterfly u_bfly (
    .clk (clk),
    .ar (ar),
    .ai (ai),
    .br (br),
    .bi (bi),
    .wr (wr),
    .wi (wi),
    .in_valid (bfly_in_valid),
    .pr (pr),
    .pi (pi),
    .qr (qr),
    .qi (qi),
    .out_valid (bfly_out_valid)
);

twiddle_rom u_tw (
    .clk (clk),
    .addr (tw_addr),
    .cos_out (wr),
    .sin_out (wi)
);

always_comb begin
    span = 8'd2 << stage;
    half_span = 8'd1 << stage;
    group_base = {bfly_cnt[6:0], 1'b0} & ~(span - 8'd1);
    k_in_group = {1'b0, bfly_cnt} & (half_span - 8'd1);
    capture_ok = in_valid && !bank_full[fill_bank] &&
                 ((state == FILL) || (fill_bank != comp_bank)) &&
                 !((state == OUTPUT) && (out_cnt == 8'd255));
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= FILL;
        fill_bank <= 1'b0;
        comp_bank <= 1'b0;
        bank_full <= 2'b00;
        fill_cnt <= 8'd0;
        stage <= 3'd0;
        bfly_cnt <= 7'd0;
        out_cnt <= 8'd0;
        idx_a <= 8'd0;
        idx_b <= 8'd0;
        tw_addr <= 7'd0;
        rd_addr0 <= 8'd0;
        rd_addr1 <= 8'd0;
        wr_addr0 <= 8'd0;
        wr_addr1 <= 8'd0;
        wr_data0_r <= '0;
        wr_data0_i <= '0;
        wr_data1_r <= '0;
        wr_data1_i <= '0;
        we0_r <= 1'b0;
        we0_i <= 1'b0;
        we1_r <= 1'b0;
        we1_i <= 1'b0;
        ar <= '0;
        ai <= '0;
        br <= '0;
        bi <= '0;
        bin_magnitude <= 8'd0;
        bin_index <= 8'd0;
        bin_valid <= 1'b0;
        bfly_in_valid <= 1'b0;
    end else begin
        we0_r <= 1'b0;
        we0_i <= 1'b0;
        we1_r <= 1'b0;
        we1_i <= 1'b0;
        bin_valid <= 1'b0;
        bfly_in_valid <= 1'b0;

        if (capture_ok) begin
            if (fill_bank == 1'b0) begin
                wr_addr0 <= bitrev8(fill_cnt);
                wr_data0_r <= i_in;
                wr_data0_i <= q_in;
                we0_r <= 1'b1;
                we0_i <= 1'b1;
            end else begin
                wr_addr1 <= bitrev8(fill_cnt);
                wr_data1_r <= i_in;
                wr_data1_i <= q_in;
                we1_r <= 1'b1;
                we1_i <= 1'b1;
            end

            if (fill_cnt == 8'd255) begin
                bank_full[fill_bank] <= 1'b1;
                fill_bank <= ~fill_bank;
                fill_cnt <= 8'd0;

                if (state == FILL) begin
                    comp_bank <= fill_bank;
                    bank_full[fill_bank] <= 1'b0;
                    stage <= 3'd0;
                    bfly_cnt <= 7'd0;
                    state <= SETUP;
                end
            end else begin
                fill_cnt <= fill_cnt + 8'd1;
            end
        end

        case (state)
            FILL: begin
            end

            SETUP: begin
                idx_a <= group_base + k_in_group;
                idx_b <= group_base + k_in_group + half_span;
                tw_addr <= (7'(k_in_group[6:0]) << (7 - stage));
                if (comp_bank == 1'b0)
                    rd_addr0 <= group_base + k_in_group;
                else
                    rd_addr1 <= group_base + k_in_group;
                state <= READ_A;
            end

            READ_A: begin
                state <= READ_B;
            end

            READ_B: begin
                if (comp_bank == 1'b0) begin
                    ar <= rd_data0_r;
                    ai <= rd_data0_i;
                    rd_addr0 <= idx_b;
                end else begin
                    ar <= rd_data1_r;
                    ai <= rd_data1_i;
                    rd_addr1 <= idx_b;
                end
                state <= LOAD_B;
            end

            LOAD_B: begin
                state <= START;
            end

            START: begin
                if (comp_bank == 1'b0) begin
                    br <= rd_data0_r;
                    bi <= rd_data0_i;
                end else begin
                    br <= rd_data1_r;
                    bi <= rd_data1_i;
                end
                state <= BF_START;
            end

            BF_START: begin
                bfly_in_valid <= 1'b1;
                state <= WAIT0;
            end

            WAIT0: begin
                state <= WAIT1;
            end

            WAIT1: begin
                state <= WRITE_A;
            end

            WRITE_A: begin
                if (comp_bank == 1'b0) begin
                    wr_addr0 <= idx_a;
                    wr_data0_r <= pr >>> 1;
                    wr_data0_i <= pi >>> 1;
                    we0_r <= 1'b1;
                    we0_i <= 1'b1;
                end else begin
                    wr_addr1 <= idx_a;
                    wr_data1_r <= pr >>> 1;
                    wr_data1_i <= pi >>> 1;
                    we1_r <= 1'b1;
                    we1_i <= 1'b1;
                end
                state <= WRITE_B;
            end

            WRITE_B: begin
                if (comp_bank == 1'b0) begin
                    wr_addr0 <= idx_b;
                    wr_data0_r <= qr >>> 1;
                    wr_data0_i <= qi >>> 1;
                    we0_r <= 1'b1;
                    we0_i <= 1'b1;
                end else begin
                    wr_addr1 <= idx_b;
                    wr_data1_r <= qr >>> 1;
                    wr_data1_i <= qi >>> 1;
                    we1_r <= 1'b1;
                    we1_i <= 1'b1;
                end

                if (bfly_cnt == 7'd127) begin
                    bfly_cnt <= 7'd0;
                    if (stage == 3'd7) begin
                        out_cnt <= 8'd0;
                        state <= OUT_SETUP;
                    end else begin
                        stage <= stage + 3'd1;
                        state <= SETUP;
                    end
                end else begin
                    bfly_cnt <= bfly_cnt + 7'd1;
                    state <= SETUP;
                end
            end

            OUT_SETUP: begin
                if (comp_bank == 1'b0)
                    rd_addr0 <= out_cnt;
                else
                    rd_addr1 <= out_cnt;
                state <= OUT_WAIT;
            end

            OUT_WAIT: begin
                state <= OUTPUT;
            end

            OUTPUT: begin
                bin_index <= out_cnt;
                if (comp_bank == 1'b0) begin
                    bin_magnitude <= abs16_hi(rd_data0_r) + abs16_hi(rd_data0_i);
                end else begin
                    bin_magnitude <= abs16_hi(rd_data1_r) + abs16_hi(rd_data1_i);
                end
                bin_valid <= 1'b1;

                if (out_cnt == 8'd255) begin
                    bank_full[comp_bank] <= 1'b0;
                    if (bank_full[~comp_bank]) begin
                        comp_bank <= ~comp_bank;
                        bank_full[~comp_bank] <= 1'b0;
                        stage <= 3'd0;
                        bfly_cnt <= 7'd0;
                        out_cnt <= 8'd0;
                        state <= SETUP;
                    end else begin
                        state <= FILL;
                    end
                end else begin
                    out_cnt <= out_cnt + 8'd1;
                    if (comp_bank == 1'b0)
                        rd_addr0 <= out_cnt + 8'd1;
                    else
                        rd_addr1 <= out_cnt + 8'd1;
                end
            end

            default: begin
                state <= FILL;
            end
        endcase
    end
end

endmodule

module ram256x16 (
    input logic clk,
    input logic we,
    input logic [7:0] waddr,
    input logic signed [15:0] wdata,
    input logic [7:0] raddr,
    output logic signed [15:0] rdata
);

logic signed [15:0] mem [0:255];

always_ff @(posedge clk) begin
    if (we)
        mem[waddr] <= wdata;
    rdata <= mem[raddr];
end

endmodule

