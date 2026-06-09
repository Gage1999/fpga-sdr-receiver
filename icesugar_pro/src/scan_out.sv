module scan_out #(
    parameter int LINE_WORDS = 800,
    parameter int NLINES = 480,
    parameter int PREFETCH = 2,
    parameter int FB_BASE_W = 0,
    parameter int VISIBLE_Y0 = 192,
    parameter int MAX_BURST = 512,
    parameter bit HALF_PAGE = 0
) (
    input logic clk,
    input logic rst,

    input logic [8:0] px_line,
    input logic px_hblank,
    input logic [8:0] wf_base_row,

    // To sdram_ctrl request port
    output logic req_valid,
    output logic [24:0] req_addr,
    output logic [9:0] req_len,
    input logic req_ready,
    input logic [15:0] rd_data,
    input logic rd_valid,
    input logic done,

    // To line_cache write port
    output logic [1:0] w_slot,
    output logic [9:0] w_col,
    output logic [15:0] w_data,
    output logic w_en,

    output logic busy
);

    typedef enum logic [1:0] { S_IDLE, S_REQ, S_RX, S_WAIT } state_e;
    state_e st;

    logic [18:0] cur_word;
    logic [10:0] words_left;
    logic [9:0] w_col_ctr;
    logic [9:0] beats;
    logic [1:0] slot_r;

    localparam int RW = HALF_PAGE ? 256 : 512;
    wire [9:0] col_w = 10'(cur_word % RW);
    wire [10:0] rem_row = 11'(RW) - {1'b0, col_w};
    wire [10:0] seg_cap = (rem_row < words_left) ? rem_row : words_left;
    wire [10:0] seg_w = (seg_cap < MAX_BURST[10:0]) ? seg_cap : MAX_BURST[10:0];
    logic [10:0] seg_r;
    always_ff @(posedge clk) seg_r <= seg_w;

    assign req_addr = (25'(cur_word / RW) << 10) | (25'(col_w) << 1);
    assign req_len = seg_r[9:0];

    assign w_en = (st == S_RX) && rd_valid;
    assign w_slot = slot_r;
    assign w_col = w_col_ctr;
    assign w_data = rd_data;
    assign busy = (st != S_IDLE);

    logic hb1, hb2, hb3;
    logic [8:0] ln1, ln2;
    always_ff @(posedge clk) begin
        hb1 <= px_hblank; hb2 <= hb1; hb3 <= hb2;
        ln1 <= px_line;   ln2 <= ln1;
    end
    wire hb_rise = hb2 & ~hb3;

    localparam int VISIBLE_LINES = NLINES - VISIBLE_Y0;
    wire [9:0] disp_line = {1'b0, ln2} + PREFETCH[9:0];
    wire disp_valid = (disp_line < NLINES[9:0]);
    wire disp_wf_band = disp_valid && (disp_line >= VISIBLE_Y0[9:0]);
    wire [11:0] wf_rel = {2'b0, (disp_line - VISIBLE_Y0[9:0])};
    wire [11:0] wf_sum = wf_rel + {3'b0, wf_base_row};
    wire [11:0] wf_wrap = (wf_sum >= VISIBLE_LINES[11:0]) ? (wf_sum - VISIBLE_LINES[11:0]) : wf_sum;
    wire [11:0] esum = disp_wf_band ? (VISIBLE_Y0[11:0] + wf_wrap) : {2'b0, disp_line};
    logic [11:0] esum_r;
    always_ff @(posedge clk) esum_r <= esum;
    logic [11:0] esum_rr;
    always_ff @(posedge clk) esum_rr <= esum_r;
    logic [8:0] eff_line_r;
    always_ff @(posedge clk) eff_line_r <= esum_rr[8:0];

    logic [1:0] dsl1, dsl2, dsl3;
    always_ff @(posedge clk) begin dsl1 <= disp_line[1:0]; dsl2 <= dsl1; dsl3 <= dsl2; end

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            req_valid <= 1'b0;
            cur_word <= 19'd0;
            words_left <= 11'd0;
            w_col_ctr <= 10'd0;
            beats <= 10'd0;
            slot_r <= 2'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    req_valid <= 1'b0;
                    if (hb_rise) begin
                        cur_word <= eff_line_r * LINE_WORDS[18:0] + FB_BASE_W[18:0];
                        words_left <= LINE_WORDS[10:0];
                        w_col_ctr <= 10'd0;
                        slot_r <= dsl3;
                        st <= S_REQ;
                    end
                end

                S_REQ: begin
                    req_valid <= 1'b1;
                    beats <= 10'd0;
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0;
                        st <= S_RX;
                    end
                end

                S_RX: begin
                    if (rd_valid) begin
                        w_col_ctr <= w_col_ctr + 10'd1;
                        if (beats == seg_r[9:0] - 10'd1) begin
                            cur_word <= cur_word + 19'(seg_r);
                            words_left <= words_left - seg_r;
                            st <= S_WAIT;
                        end else begin
                            beats <= beats + 10'd1;
                        end
                    end
                end

                S_WAIT: begin
                    if (done) begin
                        if (words_left == 11'd0) st <= S_IDLE;
                        else                     st <= S_REQ;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
