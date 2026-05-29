// scan_out.sv
// Framebuffer line prefetcher (SDRAM clock domain): on each H-blank, fetch the
// line PREFETCH ahead into a line_cache slot via sdram_ctrl.
// An 800-word line spans 2-3 of the 512-word SDRAM pages, so each line is split
// into page-aligned segments (no burst crosses a page). See arch doc §4.
// px_line/px_hblank come from the pixel domain through 2-FF synchronizers.

module scan_out #(
    parameter int LINE_WORDS = 800,
    parameter int PAGE_WORDS = 512,
    parameter int NLINES     = 480,
    parameter int PREFETCH   = 2,
    parameter int FB_BASE_W  = 0,     // framebuffer base, in 16-bit words
    parameter int MAX_BURST  = 512,   // cap burst length; <512 avoids the marginal full-page read
    parameter bit HALF_PAGE  = 0      // 1 = store 256 words per SDRAM row (cols 0..255 only) so no
                                      //     access ever touches the marginal page-boundary column
) (
    input  logic        clk,          // SDRAM clock (100 MHz)
    input  logic        rst,

    // From pixel clock domain (synchronized internally)
    input  logic [8:0]  px_line,      // active line currently being displayed
    input  logic        px_hblank,    // high during H-blank
    input  logic [8:0]  wf_base_row,  // waterfall scroll base (modulo NLINES)

    // To sdram_ctrl request port
    output logic        req_valid,
    output logic [24:0] req_addr,
    output logic [9:0]  req_len,
    input  logic        req_ready,
    input  logic [15:0] rd_data,
    input  logic        rd_valid,
    input  logic        done,

    // To line_cache write port
    output logic [1:0]  w_slot,
    output logic [9:0]  w_col,
    output logic [15:0] w_data,
    output logic        w_en,

    output logic        busy
);

    typedef enum logic [1:0] { S_IDLE, S_REQ, S_RX, S_WAIT } state_e;
    state_e st;

    logic [18:0] cur_word;     // global word index of the current segment start
    logic [10:0] words_left;   // words remaining in this line (0..800)
    logic [9:0]  w_col_ctr;    // destination column in the cache slot (0..799)
    logic [9:0]  beats;        // rd_valid beats seen in the current segment
    logic [1:0]  slot_r;

    // Current segment geometry. seg_w is registered (seg_r) so the min()/subtract
    // cone stays off the req_len and beat-compare timing paths; cur_word is stable
    // through a segment, so seg_r is valid when used.
    // Words used per SDRAM row: 512 (contiguous, original) or 256 (half-page: cols 0..255 only).
    localparam int RW = HALF_PAGE ? 256 : 512;
    wire [9:0]  col_w    = 10'(cur_word % RW);            // column within the row
    wire [10:0] rem_row  = 11'(RW) - {1'b0, col_w};
    wire [10:0] seg_cap  = (rem_row < words_left) ? rem_row : words_left;
    wire [10:0] seg_w    = (seg_cap < MAX_BURST[10:0]) ? seg_cap : MAX_BURST[10:0];
    logic [10:0] seg_r;
    always_ff @(posedge clk) seg_r <= seg_w;

    // byte address = (row << 10) | (col << 1); row = cur_word/RW, col = cur_word%RW
    assign req_addr = (25'(cur_word / RW) << 10) | (25'(col_w) << 1);
    assign req_len  = seg_r[9:0];

    // Cache write is driven straight from the read data beat
    assign w_en   = (st == S_RX) && rd_valid;
    assign w_slot = slot_r;
    assign w_col  = w_col_ctr;
    assign w_data = rd_data;
    assign busy   = (st != S_IDLE);

    // ---- CDC: synchronize H-blank (edge-detect) and line number ----
    logic hb1, hb2, hb3;
    logic [8:0] ln1, ln2;
    always_ff @(posedge clk) begin
        hb1 <= px_hblank; hb2 <= hb1; hb3 <= hb2;
        ln1 <= px_line;   ln2 <= ln1;
    end
    wire hb_rise = hb2 & ~hb3;

    // Effective line = (displayed + PREFETCH + waterfall base) mod NLINES.
    // Each term < NLINES, so two conditional subtractions suffice to wrap. The add and
    // each subtract are split across pipeline registers so neither the wrap chain nor the
    // following line*LINE_WORDS multiply is on a long combinational path. px_line and
    // wf_base_row are stable for hundreds of cycles before each H-blank, so the few-cycle
    // pipeline delay is harmless. (When wf_base_row is a live signal — the waterfall path —
    // the unpipelined chain was the 100 MHz critical path.)
    wire  [11:0] esum  = {3'b0, ln2} + PREFETCH[11:0] + {3'b0, wf_base_row};
    logic [11:0] esum_r;
    always_ff @(posedge clk) esum_r <= esum;
    wire  [11:0] ew1   = (esum_r >= 2*NLINES) ? (esum_r - 2*NLINES) : esum_r;
    logic [11:0] ew1_r;
    always_ff @(posedge clk) ew1_r <= ew1;
    wire  [11:0] ewrap = (ew1_r >= NLINES) ? (ew1_r - NLINES) : ew1_r;
    logic [8:0] eff_line_r;
    always_ff @(posedge clk) eff_line_r <= ewrap[8:0];

    // Cache slot is keyed to the DISPLAY line being prefetched (ln2 + PREFETCH), NOT the
    // scrolled FB row eff_line. The LCD reads the cache by display line (slot = y[1:0]); with a
    // non-zero waterfall base, eff_line[1:0] != display_line[1:0], so tagging by eff_line makes
    // the LCD read the wrong slot — and on some frames the very slot scan_out is mid-filling,
    // giving half-written lines. Pipelined to eff_line_r's depth so both are valid at hb_rise.
    wire  [9:0] disp_line = {1'b0, ln2} + PREFETCH[9:0];
    logic [1:0] dsl1, dsl2, dsl3;
    always_ff @(posedge clk) begin dsl1 <= disp_line[1:0]; dsl2 <= dsl1; dsl3 <= dsl2; end

    always_ff @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            req_valid  <= 1'b0;
            cur_word   <= 19'd0;
            words_left <= 11'd0;
            w_col_ctr  <= 10'd0;
            beats      <= 10'd0;
            slot_r     <= 2'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    req_valid <= 1'b0;
                    if (hb_rise) begin
                        cur_word   <= eff_line_r * LINE_WORDS[18:0] + FB_BASE_W[18:0];
                        words_left <= LINE_WORDS[10:0];
                        w_col_ctr  <= 10'd0;
                        slot_r     <= dsl3;          // display-line slot, not eff_line[1:0]
                        st         <= S_REQ;
                    end
                end

                S_REQ: begin
                    req_valid <= 1'b1;
                    beats     <= 10'd0;
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0;     // accepted
                        st        <= S_RX;
                    end
                end

                S_RX: begin
                    if (rd_valid) begin
                        w_col_ctr <= w_col_ctr + 10'd1;
                        if (beats == seg_r[9:0] - 10'd1) begin
                            cur_word   <= cur_word + 19'(seg_r);
                            words_left <= words_left - seg_r;
                            st         <= S_WAIT;
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
