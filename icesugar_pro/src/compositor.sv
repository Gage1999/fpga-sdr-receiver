// compositor.sv
// Waterfall write side (SDRAM clock domain): map a row of magnitudes to RGB565,
// burst-write it into the framebuffer, then bump the waterfall base-row pointer
// (scroll trick, no copy). Writes use the same page-aligned segment splitting as
// scan_out (arch doc §4/§7a). The mag stream crosses from the 25 MHz FFT domain
// through an async_fifo upstream; here mag_in/mag_valid are already in this domain.

module compositor #(
    parameter int ROW_WORDS = 800,
    parameter int PAGE_WORDS = 512,
    parameter int NLINES     = 480,
    parameter int FB_BASE_W  = 0
) (
    input  logic        clk,          // SDRAM clock
    input  logic        rst,

    // Magnitude row input (already in SDRAM domain)
    input  logic [7:0]  mag_in,
    input  logic        mag_valid,    // one strobe per pixel, ROW_WORDS per row

    // Waterfall base pointer (to scan_out)
    output logic [8:0]  wf_base_row,

    // To sdram_ctrl / sdram_arb write port
    output logic        req_valid,
    output logic        req_wr,
    output logic [24:0] req_addr,
    output logic [9:0]  req_len,
    input  logic        req_ready,
    output logic [15:0] wr_data,
    output logic        wr_valid,
    input  logic        wr_ready,
    input  logic        done,

    output logic        busy          // high while filling/writing a row
);

    // 8-bit magnitude -> RGB565 (placeholder palette; swap for color_lut at integration)
    function automatic logic [15:0] palette(input logic [7:0] m);
        palette = {m[7:3], m[7:2], m[7:3]};
    endfunction

    logic [15:0] linebuf [0:ROW_WORDS-1];

    typedef enum logic [1:0] { S_FILL, S_REQ, S_WRITE, S_WAIT } state_e;
    state_e st;

    logic [10:0] fill_cnt;     // 0..ROW_WORDS
    logic [18:0] cur_word;     // global word index of current segment start
    logic [10:0] words_left;
    logic [9:0]  rd_ptr;       // read index into linebuf
    logic [9:0]  beats;        // wr beats accepted this segment
    logic [8:0]  wf_write_row; // line currently being written

    wire [8:0]  col_w    = cur_word[8:0];
    wire [10:0] rem_page = PAGE_WORDS[10:0] - {2'b0, col_w};
    wire [10:0] seg_w    = (rem_page < words_left) ? rem_page : words_left;

    assign req_wr   = 1'b1;
    assign req_addr = 25'(cur_word) << 1;
    assign req_len  = seg_w[9:0];
    assign wr_data  = linebuf[rd_ptr];
    assign busy     = (st != S_FILL) || (fill_cnt != 11'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            st           <= S_FILL;
            fill_cnt     <= 11'd0;
            cur_word     <= 19'd0;
            words_left   <= 11'd0;
            rd_ptr       <= 10'd0;
            beats        <= 10'd0;
            wf_write_row <= 9'd0;
            wf_base_row  <= 9'd0;
            req_valid    <= 1'b0;
            wr_valid     <= 1'b0;
        end else begin
            case (st)
                S_FILL: begin
                    req_valid <= 1'b0;
                    wr_valid  <= 1'b0;
                    if (mag_valid) begin
                        linebuf[fill_cnt[9:0]] <= palette(mag_in);
                        if (fill_cnt == ROW_WORDS[10:0] - 11'd1) begin
                            // row complete -> start the SDRAM write of line wf_write_row
                            fill_cnt   <= 11'd0;
                            cur_word   <= wf_write_row * ROW_WORDS[18:0] + FB_BASE_W[18:0];
                            words_left <= ROW_WORDS[10:0];
                            rd_ptr     <= 10'd0;
                            st         <= S_REQ;
                        end else begin
                            fill_cnt <= fill_cnt + 11'd1;
                        end
                    end
                end

                S_REQ: begin
                    req_valid <= 1'b1;
                    beats     <= 10'd0;
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0;
                        wr_valid  <= 1'b1;     // start presenting data
                        st        <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    wr_valid <= 1'b1;
                    if (wr_ready && wr_valid) begin
                        rd_ptr <= rd_ptr + 10'd1;
                        if (beats == seg_w[9:0] - 10'd1) begin
                            wr_valid   <= 1'b0;
                            cur_word   <= cur_word + 19'(seg_w);
                            words_left <= words_left - seg_w;
                            st         <= S_WAIT;
                        end else begin
                            beats <= beats + 10'd1;
                        end
                    end
                end

                S_WAIT: begin
                    if (done) begin
                        if (words_left == 11'd0) begin
                            // whole row written; advance the scroll pointer
                            wf_write_row <= (wf_write_row == NLINES[8:0]-9'd1) ? 9'd0 : wf_write_row + 9'd1;
                            wf_base_row  <= (wf_write_row == NLINES[8:0]-9'd1) ? 9'd0 : wf_write_row + 9'd1;
                            st           <= S_FILL;
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
