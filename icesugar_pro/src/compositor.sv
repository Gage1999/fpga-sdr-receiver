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
    parameter int FB_BASE_W  = 0,
    parameter int MAX_BURST  = 512,   // cap burst length; <512 avoids the marginal full-page access
    parameter bit HALF_PAGE  = 0,     // 1 = store 256 words per SDRAM row (cols 0..255 only) so no
                                      //     access touches the marginal page boundary. MUST match scan_out.
    parameter bit TEST_PATTERN = 0    // 1 = ignore mag_in; pixel value = a ramp of the fill column
                                      //     (fill_cnt). Row-aligned by construction (no dependence on
                                      //     the generator/CDC row phase) — isolates the SDRAM path.
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
    // Registered read of the line buffer. The buffer maps to block RAM (DP16KD), which has
    // NO asynchronous read on ECP5 — reading it combinationally works in behavioral sim but
    // returns stale data on silicon. So register the read explicitly and add a fetch cycle
    // (S_FETCH) so the FSM accounts for the 1-cycle latency; sim and hardware then match.
    logic [15:0] linebuf_q;
    logic [15:0] wr_pipe;

    typedef enum logic [2:0] { S_FILL, S_REQ, S_FETCH, S_WRITE, S_WAIT } state_e;
    state_e st;

    logic [10:0] fill_cnt;     // 0..ROW_WORDS
    logic [18:0] cur_word;     // global word index of current segment start
    logic [10:0] words_left;
    logic [9:0]  rd_ptr;       // read index into linebuf
    logic [9:0]  beats;        // wr beats accepted this segment
    logic [8:0]  wf_write_row; // line currently being written

    // Registered line-buffer read (1-cycle latency; S_FETCH compensates). See note above.
    always_ff @(posedge clk) linebuf_q <= linebuf[rd_ptr];

    // Words used per SDRAM row: 512 (contiguous) or 256 (half-page: cols 0..255 only).
    // Identical to scan_out so a written pixel and the scanned-out pixel resolve to the
    // same SDRAM address. byte addr = (row << 10) | (col << 1); row = cur_word/RW, col = cur_word%RW.
    localparam int RW = HALF_PAGE ? 256 : 512;
    wire [9:0]  col_w   = 10'(cur_word % RW);
    wire [10:0] rem_row = 11'(RW) - {1'b0, col_w};
    wire [10:0] seg_cap = (rem_row < words_left) ? rem_row : words_left;
    wire [10:0] seg_w   = (seg_cap < MAX_BURST[10:0]) ? seg_cap : MAX_BURST[10:0];
    // Register the segment length so the min()/subtract cone stays off the req_len/FSM
    // timing paths (cur_word is stable through a segment, so seg_r is valid when used).
    // Same fix scan_out uses; matters once the arbiter mux is in the request path.
    logic [10:0] seg_r;
    always_ff @(posedge clk) seg_r <= seg_w;

    assign req_wr   = 1'b1;
    assign req_addr = (25'(cur_word / RW) << 10) | (25'(col_w) << 1);
    assign req_len  = seg_r[9:0];
    assign wr_data  = wr_pipe;
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
            wr_pipe      <= 16'd0;
        end else begin
            case (st)
                S_FILL: begin
                    req_valid <= 1'b0;
                    wr_valid  <= 1'b0;
                    if (mag_valid) begin
                        // TEST_PATTERN: value from the fill column (fill_cnt), so every row is
                        // identical and column-aligned by construction (no dependence on the mag
                        // stream / CDC phase). Uses 4 DISTINCT vertical bars ({col[9:8],0}) =
                        // black / dim / mid / bright across the 4 quarters — visually unmistakable
                        // (so you can tell this build apart) and column order is obvious.
                        // mag_valid still paces the fill. Real mode uses mag_in.
                        linebuf[fill_cnt[9:0]] <= palette(TEST_PATTERN ? {fill_cnt[9:8], 6'd0} : mag_in);
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
                        // linebuf_q already holds linebuf[rd_ptr]. Save it as beat 0, then
                        // pre-address beat 1 during the controller's RCD/CAS delay. Once the
                        // SDRAM WRITE starts, data must be continuous; the chip cannot pause
                        // for the line-buffer read latency.
                        wr_pipe  <= linebuf_q;
                        rd_ptr   <= rd_ptr + 10'd1;
                        wr_valid  <= 1'b1;
                        st        <= S_WRITE;
                    end
                end

                // Re-prime linebuf_q for the next beat (registered read has 1-cycle latency).
                S_FETCH: begin
                    wr_valid <= 1'b0;
                    st       <= S_WRITE;
                end

                S_WRITE: begin
                    wr_valid <= 1'b1;
                    if (wr_ready && wr_valid) begin
                        if (beats == seg_r[9:0] - 10'd1) begin
                            wr_valid   <= 1'b0;
                            cur_word   <= cur_word + 19'(seg_r);
                            words_left <= words_left - seg_r;
                            st         <= S_WAIT;
                        end else begin
                            wr_pipe <= linebuf_q;
                            rd_ptr  <= rd_ptr + 10'd1;
                            beats   <= beats + 10'd1;
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
