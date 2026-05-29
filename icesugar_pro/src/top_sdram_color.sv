// top_sdram_color.sv
// Phase 3 integration test: fill the SDRAM framebuffer with vertical colour bars
// at startup, then display it through scan_out + line_cache. Proves the whole
// read path (page-split fetch, CDC line cache, LCD read) on real hardware.
//
// At reset a fill writer writes colorbar(col) to every framebuffer word; once
// fill_done, scan_out owns the controller and prefetches each line into the
// 4-slot line_cache, which the pixel domain reads out to the LCD.
// `define SIMULATION bypasses the PLL (clk_sdram = clk_pix = CLK).

module top_sdram_color #(
    parameter int H_ACTIVE   = 800,
    parameter int H_TOTAL    = 928,
    parameter int V_ACTIVE   = 480,
    parameter int V_TOTAL    = 525,
    parameter int LINE_WORDS = 800,
    parameter bit DIAG       = 1'b0,  // 1 = 2D diagnostic pattern instead of colour bars
    // Clocking: defaults give clk_sdram=100 MHz, clk_pix=30 MHz, refresh=780 cyc.
    // CPHASE values are per ecppll (CLKOP_DIV/2) — required for a clean output clock.
    // The 75 MHz test build sets CLKFB_DIV=3, CLKOP_DIV=8, CPHASE=4, TREF=585.
    parameter int CLKFB_DIV    = 4,
    parameter int CLKOP_DIV    = 6,
    parameter int CLKOS_DIV    = 20,
    parameter int CLKOP_CPHASE = 2,
    parameter int CLKOS_CPHASE = 2,
    parameter int TREF         = 780,
    parameter bit SDRAM_CLK_INV = 1'b0,  // 1 = drive the SDRAM clock pin inverted (read-margin fix)
    parameter int CAP_PHASE    = 0       // read-capture phase: 0=0deg 1=90deg 2=180deg 3=270deg
) (
    input  logic        CLK,
    output logic        LCD_CLK,
    output logic        LCD_DEN,
    output logic [4:0]  LCD_R,
    output logic [5:0]  LCD_G,
    output logic [4:0]  LCD_B,
    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_dm,
    inout  wire  [15:0] sdram_dq
);

    // Vertical colour bars (red / green / blue / white), used by the fill writer
    function automatic logic [15:0] colorbar(input int col);
        int w; w = H_ACTIVE / 4;
        if      (col < w)     colorbar = 16'hF800;
        else if (col < 2*w)   colorbar = 16'h07E0;
        else if (col < 3*w)   colorbar = 16'h001F;
        else                  colorbar = 16'hFFFF;
    endfunction

    // ---- Clocks ----
    // clk90 is a second 100 MHz clock, 90 deg shifted, used to sample the SDRAM read
    // data closer to the centre of its valid window (read-capture calibration).
    logic clk_sdram, clk_pix, clk90, pll_locked;
`ifdef SIMULATION
    // Model the real rate ratio: SDRAM clock = CLK (100 MHz), pixel clock = CLK/4
    // (so scan_out gets ~4x the cycles per line, as on hardware). Equal clocks would
    // starve the prefetch and is not representative.
    assign clk_sdram = CLK;
    logic [1:0] pdiv = 2'd0;
    always_ff @(posedge CLK) pdiv <= pdiv + 2'd1;
    assign clk_pix = pdiv[1];
    assign clk90   = CLK;     // phase doesn't matter in the single-clock sim
    assign pll_locked = 1'b1;
`else
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(CLKOP_DIV), .CLKOP_CPHASE(CLKOP_CPHASE), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(CLKOS_DIV), .CLKOS_CPHASE(CLKOS_CPHASE), .CLKOS_FPHASE(0),
        // CLKOS2 = 100 MHz at 90 deg (ecppll: DIV=6, CPHASE=3, FPHASE=4) -> clk90
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(6), .CLKOS2_CPHASE(3), .CLKOS2_FPHASE(4),
        .CLKOS3_ENABLE("DISABLED"), .CLKOS3_DIV(1), .CLKOS3_CPHASE(0), .CLKOS3_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(CLKFB_DIV)
    ) u_pll (
        .CLKI(CLK), .CLKFB(clk_sdram), .CLKOP(clk_sdram), .CLKOS(clk_pix),
        .CLKOS2(clk90), .CLKOS3(), .RST(1'b0), .STDBY(1'b0),
        // PHASEDIR/STEP/LOADREG tied high per ecppll so the static CPHASE actually loads
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .ENCLKOS(1'b0), .ENCLKOS2(1'b0), .ENCLKOS3(1'b0), .LOCK(pll_locked)
    );
`endif

    // ---- Resets ----
    logic [7:0] srst_cnt = 8'd0; logic sys_rst = 1'b1;     // clk_sdram domain
    always_ff @(posedge clk_sdram) begin
        if (!pll_locked) begin srst_cnt <= 8'd0; sys_rst <= 1'b1; end
        else if (!srst_cnt[7]) begin srst_cnt <= srst_cnt + 8'd1; sys_rst <= 1'b1; end
        else sys_rst <= 1'b0;
    end
    logic [7:0] prst_cnt = 8'd0; logic pix_rst = 1'b1;     // clk_pix domain
    always_ff @(posedge clk_pix) begin
        if (!pll_locked) begin prst_cnt <= 8'd0; pix_rst <= 1'b1; end
        else if (!prst_cnt[7]) begin prst_cnt <= prst_cnt + 8'd1; pix_rst <= 1'b1; end
        else pix_rst <= 1'b0;
    end

    // ---- SDRAM controller ----
    logic        c_req_valid, c_req_wr, c_req_ready, c_wr_valid, c_wr_ready, c_rd_valid, c_done;
    logic [24:0] c_req_addr;
    logic [9:0]  c_req_len;
    logic [15:0] c_wr_data, c_rd_data;
    logic [15:0] dq_out, dq_in; logic dq_oe;

    sdram_ctrl #(.TREF_PERIOD(TREF), .RD_LAT(3)) u_ctrl (   // +1 for the read-capture register below
        .clk(clk_sdram), .rst(sys_rst),
        .req_valid(c_req_valid), .req_wr(c_req_wr), .req_addr(c_req_addr), .req_len(c_req_len),
        .req_ready(c_req_ready),
        .wr_data(c_wr_data), .wr_valid(c_wr_valid), .wr_ready(c_wr_ready),
        .rd_data(c_rd_data), .rd_valid(c_rd_valid), .done(c_done),
        .sdram_clk(/* driven below, optionally phase-inverted */),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in), .sdram_dm(sdram_dm)
    );
    assign sdram_dq = dq_oe ? dq_out : 16'hzzzz;
    // Read-capture calibration: sample the DQ bus on one of four phases and feed that to
    // the controller (which uses RD_LAT=3 to absorb this extra register). Sweep CAP_PHASE
    // across builds to find the phase that samples the data eye cleanly.
    logic [15:0] cap0, cap1, cap2, cap3;
    always_ff @(posedge clk_sdram) cap0 <= sdram_dq;   // 0 deg
    always_ff @(posedge clk90)     cap1 <= sdram_dq;   // 90 deg
    always_ff @(negedge clk_sdram) cap2 <= sdram_dq;   // 180 deg
    always_ff @(negedge clk90)     cap3 <= sdram_dq;   // 270 deg
    always_comb begin
        case (CAP_PHASE)
            0:       dq_in = cap0;
            1:       dq_in = cap1;
            2:       dq_in = cap2;
            default: dq_in = cap3;
        endcase
    end
    // Clock to the SDRAM chip. Inverting it (180 deg) gives the read data half a clock
    // more to make the round trip before it is captured — a read-margin fix.
    assign sdram_clk = SDRAM_CLK_INV ? ~clk_sdram : clk_sdram;

    // ---- Startup fill writer: colorbar(col) to every framebuffer word ----
    typedef enum logic [2:0] { F_INIT, F_REQ, F_WRITE, F_WAIT, F_DONE } fstate_e;
    fstate_e fst;
    logic [18:0] f_word;       // global framebuffer word index
    logic [9:0]  f_col;        // column within the current line (0..LINE_WORDS-1)
    logic [8:0]  f_line;
    logic [10:0] f_left;       // words left in the current line
    logic [9:0]  f_beats;
    logic        fill_done;
    logic        fw_req_valid, fw_wr_valid;

    // Half-page layout: 256 words per SDRAM row (cols 0..255), so writes never touch the
    // marginal page-boundary column either. Segments are <=256 within one row.
    wire [9:0]  f_pcol  = 10'(f_word % 256);
    wire [10:0] f_rem   = 11'd256 - {1'b0, f_pcol};
    wire [10:0] f_seg   = (f_rem < f_left) ? f_rem : f_left;
    logic [10:0] f_seg_r;   // registered segment length (keeps it off the req_len/FSM paths)

    always_ff @(posedge clk_sdram) begin
        if (sys_rst) begin
            fst <= F_INIT; f_word <= 19'd0; f_col <= 10'd0; f_line <= 9'd0;
            f_left <= LINE_WORDS[10:0]; f_beats <= 10'd0; fill_done <= 1'b0;
            fw_req_valid <= 1'b0; fw_wr_valid <= 1'b0; f_seg_r <= 11'd0;
        end else begin
            f_seg_r <= f_seg;   // f_word is stable except at segment end, so f_seg_r is valid in F_REQ/F_WRITE
            case (fst)
                // wait until the controller is idle (req_ready high) before the first
                // request, so we never assert req_valid as it enters IDLE
                F_INIT: if (c_req_ready) fst <= F_REQ;
                F_REQ: begin
                    fw_req_valid <= 1'b1;
                    f_beats <= 10'd0;
                    if (fw_req_valid && c_req_ready) begin
                        fw_req_valid <= 1'b0; fw_wr_valid <= 1'b1; fst <= F_WRITE;
                    end
                end
                F_WRITE: begin
                    // f_word (segment start) stays fixed here so f_seg is stable; only
                    // f_col advances per beat (for colorbar). f_word jumps by f_seg at the end.
                    fw_wr_valid <= 1'b1;
                    if (c_wr_ready && fw_wr_valid) begin
                        f_col <= f_col + 10'd1;
                        if (f_beats == f_seg_r[9:0] - 10'd1) begin
                            fw_wr_valid <= 1'b0;
                            f_word <= f_word + 19'(f_seg_r);
                            f_left <= f_left - f_seg_r;
                            fst <= F_WAIT;
                        end else f_beats <= f_beats + 10'd1;
                    end
                end
                F_WAIT: if (c_done) begin
                    if (f_left != 11'd0) fst <= F_REQ;        // more segments in this line
                    else if (f_line == V_ACTIVE[8:0] - 9'd1) fst <= F_DONE;
                    else begin                                // next line
                        f_line <= f_line + 9'd1;
                        f_col  <= 10'd0;
                        f_left <= LINE_WORDS[10:0];
                        fst    <= F_REQ;
                    end
                end
                F_DONE: fill_done <= 1'b1;
                default: fst <= F_REQ;
            endcase
        end
    end

    // ---- scan_out (runs once the fill is done) ----
    logic        so_req_valid, so_req_ready, so_rd_valid, so_done;
    logic [24:0] so_req_addr;
    logic [9:0]  so_req_len;
    logic [1:0]  w_slot; logic [9:0] w_col; logic [15:0] w_data; logic w_en;

    logic [10:0] x; logic [9:0] y; logic de;

    scan_out #(.LINE_WORDS(LINE_WORDS), .NLINES(V_ACTIVE), .MAX_BURST(256), .HALF_PAGE(1)) u_scan (
        .clk(clk_sdram), .rst(sys_rst | ~fill_done),
        // only fetch during active lines: prefetches all V_ACTIVE lines exactly once
        // (no vblank over-fetch, which would corrupt a real per-line framebuffer)
        .px_line(y[8:0]), .px_hblank((x >= H_ACTIVE[10:0]) && (y < V_ACTIVE[9:0])), .wf_base_row(9'd0),
        .req_valid(so_req_valid), .req_addr(so_req_addr), .req_len(so_req_len),
        .req_ready(so_req_ready), .rd_data(c_rd_data), .rd_valid(so_rd_valid), .done(so_done),
        .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en), .busy()
    );

    // Controller request mux: fill writer until fill_done, then scan_out (read-only)
    assign c_req_valid = fill_done ? so_req_valid : fw_req_valid;
    assign c_req_wr    = fill_done ? 1'b0         : 1'b1;
    assign c_req_addr  = fill_done ? so_req_addr  : (25'(f_word / 256) << 10) | (25'(f_word % 256) << 1);
    assign c_req_len   = fill_done ? so_req_len   : f_seg_r[9:0];
    // colour bars (R/B encode nothing, vary by column) OR a 2D diagnostic: R/B ramp by
    // LINE, G ramps by COLUMN -> a wrong-line read shows a wrong R/B tint, a wrong-column
    // (page-split) read shows a G discontinuity.
    assign c_wr_data   = DIAG ? {f_line[8:4], f_col[9:4], f_line[8:4]} : colorbar(int'(f_col));
    assign c_wr_valid  = fill_done ? 1'b0         : fw_wr_valid;
    assign so_req_ready = fill_done & c_req_ready;
    assign so_rd_valid  = fill_done & c_rd_valid;
    assign so_done      = fill_done & c_done;

    // ---- line cache ----
    logic [15:0] px_data;
    line_cache u_cache (
        .wclk(clk_sdram), .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
        .rclk(clk_pix),   .r_slot(y[1:0]), .r_col((x < H_ACTIVE[10:0]) ? x[9:0] : 10'd0),
        .r_data(px_data)
    );

    // ---- display ----
    scan_timing #(.H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE), .V_TOTAL(V_TOTAL))
    u_timing (.pclk(clk_pix), .rst(pix_rst), .x(x), .y(y), .de(de));

    assign LCD_CLK = clk_pix;
    logic de_d;
    always_ff @(posedge clk_pix) de_d <= de;   // align DE with the 1-cycle cache read
    assign LCD_DEN = de_d;
    assign LCD_R = de_d ? px_data[15:11] : 5'd0;
    assign LCD_G = de_d ? px_data[10:5]  : 6'd0;
    assign LCD_B = de_d ? px_data[4:0]   : 5'd0;

endmodule
