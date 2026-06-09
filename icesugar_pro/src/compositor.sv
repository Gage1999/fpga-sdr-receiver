module compositor #(
    parameter int ROW_WORDS = 800,
    parameter int NLINES = 480,
    parameter int FB_BASE_W = 0,
    parameter int VISIBLE_Y0 = 192,
    parameter int MAX_BURST = 512,
    parameter bit HALF_PAGE = 0,
    parameter bit TEST_PATTERN = 0
) (
    input logic clk,
    input logic rst,

    input logic [7:0] mag_in,
    input logic mag_valid,

    output logic [8:0] wf_base_row,

    output logic req_valid,
    output logic req_wr,
    output logic [24:0] req_addr,
    output logic [9:0] req_len,
    input logic req_ready,
    output logic [15:0] wr_data,
    output logic wr_valid,
    input logic wr_ready,
    input logic done,

    output logic busy
);

    function automatic logic [15:0] palette(input logic [7:0] m);
        begin
            palette = {
                m[7] ? 5'd31 : {m[6:3], 1'b0},
                m[6] ? 6'd63 : {m[5:0]},
                m[7] ? {m[4:0]} : (m[6] ? ~m[4:0] : {m[4:0]})
            };
        end
    endfunction

    logic [15:0] linebuf [0:ROW_WORDS-1];
    logic [15:0] linebuf_q;
    logic [15:0] wr_pipe;

    typedef enum logic [2:0] { S_FILL, S_REQ, S_WRITE, S_WAIT } state_e;
    state_e st;

    logic [10:0] fill_cnt;
    logic [18:0] cur_word;
    logic [10:0] words_left;
    logic [9:0] rd_ptr;
    logic [9:0] beats;
    logic [8:0] wf_write_row;
    logic [8:0] wf_next_write_row;
    assign wf_next_write_row = (wf_write_row == VISIBLE_Y0[8:0])
                             ? NLINES[8:0] - 9'd1
                             : wf_write_row - 9'd1;

    always_ff @(posedge clk) linebuf_q <= linebuf[rd_ptr];

    localparam int RW = HALF_PAGE ? 256 : 512;
    wire [9:0] col_w = 10'(cur_word % RW);
    wire [10:0] rem_row = 11'(RW) - {1'b0, col_w};
    wire [10:0] seg_cap = (rem_row < words_left) ? rem_row : words_left;
    wire [10:0] seg_w = (seg_cap < MAX_BURST[10:0]) ? seg_cap : MAX_BURST[10:0];
    logic [10:0] seg_r;
    always_ff @(posedge clk) seg_r <= seg_w;

    assign req_wr = 1'b1;
    assign req_addr = (25'(cur_word / RW) << 10) | (25'(col_w) << 1);
    assign req_len = seg_r[9:0];
    assign wr_data = wr_pipe;
    assign busy = (st != S_FILL) || (fill_cnt != 11'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_FILL;
            fill_cnt <= 11'd0;
            cur_word <= 19'd0;
            words_left <= 11'd0;
            rd_ptr <= 10'd0;
            beats <= 10'd0;
            wf_write_row <= VISIBLE_Y0[8:0];
            wf_base_row <= 9'd0;
            req_valid <= 1'b0;
            wr_valid <= 1'b0;
            wr_pipe <= 16'd0;
        end else begin
            case (st)
                S_FILL: begin
                    req_valid <= 1'b0;
                    wr_valid <= 1'b0;
                    if (mag_valid) begin
                        linebuf[fill_cnt[9:0]] <= palette(TEST_PATTERN ? {fill_cnt[9:8], 6'd0} : mag_in);
                        if (fill_cnt == ROW_WORDS[10:0] - 11'd1) begin
                            fill_cnt <= 11'd0;
                            cur_word <= wf_write_row * ROW_WORDS[18:0] + FB_BASE_W[18:0];
                            words_left <= ROW_WORDS[10:0];
                            rd_ptr <= 10'd0;
                            st <= S_REQ;
                        end else begin
                            fill_cnt <= fill_cnt + 11'd1;
                        end
                    end
                end

                S_REQ: begin
                    req_valid <= 1'b1;
                    beats <= 10'd0;
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0;
                        wr_pipe <= linebuf_q;
                        rd_ptr <= rd_ptr + 10'd1;
                        wr_valid <= 1'b1;
                        st <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    wr_valid <= 1'b1;
                    if (wr_ready && wr_valid) begin
                        if (beats == seg_r[9:0] - 10'd1) begin
                            wr_valid <= 1'b0;
                            cur_word <= cur_word + 19'(seg_r);
                            words_left <= words_left - seg_r;
                            st <= S_WAIT;
                        end else begin
                            wr_pipe <= linebuf_q;
                            rd_ptr <= rd_ptr + 10'd1;
                            beats <= beats + 10'd1;
                        end
                    end
                end

                S_WAIT: begin
                    if (done) begin
                        if (words_left == 11'd0) begin
                            wf_base_row <= wf_write_row - VISIBLE_Y0[8:0];
                            wf_write_row <= wf_next_write_row;
                            st <= S_FILL;
                        end else begin
                            st <= S_REQ;
                        end
                    end
                end

                default: st <= S_FILL;
            endcase
        end
    end

endmodule
