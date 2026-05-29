// top_sdram_cal.sv
// SDRAM read-capture calibration. Writes a known 256-word pattern, then repeatedly
// reads it back while sampling the DQ bus at four clock phases (0/90/180/270 deg),
// counting read errors per phase. The LCD shows four vertical bands, one per phase,
// with a red bar from the top whose height is proportional to the error count (no red
// = 0 errors = clean). The shortest bar is the best capture phase.
//
// Because it compares against the *intended* pattern, it also separates read vs write
// problems: if some phase reaches zero the fix is read-capture phase; if every phase
// has errors (at the same words) the problem is on the write/storage side.
//
// Uses the same 3-output PLL as top_sdram_color (clk_sdram, clk_pix, clk90) — proven to
// lock. `define SIMULATION bypasses the PLL.

module top_sdram_cal #(
    parameter int WR_CLK_PHASE = 0,  // sdram_clk pin phase: 0/1/2/3 = 0/90/180/270 deg.
                                     // Shifts when the chip samples write data (write margin).
    parameter bit SPLIT        = 0,  // 0 = single TEST_LEN burst at TEST_COL (one row);
                                     // 1 = 600-word access split across a row boundary
                                     //     (512 in row 0 + 88 in row 1) like the framebuffer path.
    parameter int TEST_COL     = 0,  // (SPLIT=0) start column within the row
    parameter int TEST_LEN     = 256,// (SPLIT=0) burst length. col0/len256=clean baseline;
                                     // col0/len512=full page; col256/len256=ends at page edge.
    // ---- doc-preserving fix candidates (pass through to sdram_ctrl) ----
    parameter int BURST_MODE   = 0,  // 0 = full-page burst, 1 = fixed BL=8 chunks (no page wrap)
    parameter int RD_GUARD     = 0,  // extra NOP cycles before PRECHARGE after a read burst
    parameter int WR_GUARD     = 0,  // extra NOP cycles before PRECHARGE after a write burst
    // ---- PLL divisors (default = 100 MHz; override for the lower-frequency variant) ----
    parameter int CLKFB_DIV    = 4,  // f_sdram = 25 MHz * CLKFB_DIV  (4->100, 3->75)
    parameter int CLKOP_DIV    = 6,  // VCO = f_sdram * CLKOP_DIV must stay in 400-800 MHz
    parameter int CLKOS_DIV    = 20, // pixel clock divisor (VCO / CLKOS_DIV ~= 30 MHz)
    parameter int CLKOS2_DIV   = 6   // clk90 (= sdram, +90 deg) divisor; keep = CLKOP_DIV
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
    localparam int NW   = SPLIT ? 600 : TEST_LEN;   // total words in the access
    localparam int NSEG = SPLIT ? 2   : 1;          // number of row segments
    localparam int H_ACTIVE = 800, H_TOTAL = 928, V_ACTIVE = 480, V_TOTAL = 525;

    function automatic logic [15:0] pat(input logic [9:0] idx);
        pat = {idx[7:0], ~idx[7:0]} ^ 16'hC3A5;
    endfunction
    // SPLIT: seg0 (512 words) in row 0 + seg1 (88 words) in row 1, crossing the page boundary.
    // single (SPLIT=0): one burst of TEST_LEN words starting at column TEST_COL in row 0.
    function automatic logic [24:0] seg_addr(input logic s);
        seg_addr = SPLIT ? (s ? 25'd1024 : 25'd0) : (25'(TEST_COL) << 1);
    endfunction
    function automatic logic [9:0] seg_len(input logic s);
        seg_len = SPLIT ? (s ? 10'd88 : 10'd512) : 10'(TEST_LEN);
    endfunction

    // ---- Clocks: 0deg(sdram), 30MHz(pix), 90deg ----
    logic clk_sdram, clk_pix, clk90, pll_locked;
`ifdef SIMULATION
    assign clk_sdram=CLK; assign clk_pix=CLK; assign clk90=CLK; assign pll_locked=1'b1;
`else
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"), .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"),  .CLKOP_DIV(CLKOP_DIV),  .CLKOP_CPHASE(2), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"),  .CLKOS_DIV(CLKOS_DIV),  .CLKOS_CPHASE(2), .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(CLKOS2_DIV), .CLKOS2_CPHASE(3), .CLKOS2_FPHASE(4),
        .CLKOS3_ENABLE("DISABLED"), .CLKOS3_DIV(1), .CLKOS3_CPHASE(0), .CLKOS3_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(CLKFB_DIV)
    ) u_pll (
        .CLKI(CLK), .CLKFB(clk_sdram), .CLKOP(clk_sdram), .CLKOS(clk_pix), .CLKOS2(clk90), .CLKOS3(),
        .RST(1'b0), .STDBY(1'b0),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .LOCK(pll_locked)
    );
`endif

    // resets
    logic [7:0] srst_cnt = 8'd0; logic sys_rst = 1'b1;
    always_ff @(posedge clk_sdram) begin
        if (!pll_locked) begin srst_cnt<=0; sys_rst<=1; end
        else if (!srst_cnt[7]) begin srst_cnt<=srst_cnt+8'd1; sys_rst<=1; end else sys_rst<=0;
    end
    logic [7:0] prst_cnt = 8'd0; logic pix_rst = 1'b1;
    always_ff @(posedge clk_pix) begin
        if (!pll_locked) begin prst_cnt<=0; pix_rst<=1; end
        else if (!prst_cnt[7]) begin prst_cnt<=prst_cnt+8'd1; pix_rst<=1; end else pix_rst<=0;
    end

    // ---- four-phase DQ capture ----
    logic [15:0] cap [0:3];
    always_ff @(posedge clk_sdram) cap[0] <= sdram_dq;  // 0
    always_ff @(posedge clk90)     cap[1] <= sdram_dq;  // 90
    always_ff @(negedge clk_sdram) cap[2] <= sdram_dq;  // 180
    always_ff @(negedge clk90)     cap[3] <= sdram_dq;  // 270

    logic [1:0]  cur_phase;
    logic [15:0] dq_in;
    always_comb dq_in = cap[cur_phase];

    // ---- controller ----
    logic        req_valid, req_wr, req_ready, wr_valid, wr_ready, rd_valid, done;
    logic [24:0] req_addr;
    logic [9:0]  req_len;
    logic [15:0] wr_data, rd_data, dq_out;
    logic        dq_oe;

    sdram_ctrl #(.RD_LAT(3), .BURST_MODE(BURST_MODE), .RD_GUARD(RD_GUARD), .WR_GUARD(WR_GUARD)) u_ctrl (
        .clk(clk_sdram), .rst(sys_rst),
        .req_valid(req_valid), .req_wr(req_wr), .req_addr(req_addr), .req_len(req_len), .req_ready(req_ready),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
        .sdram_clk(/* pin driven below at WR_CLK_PHASE */),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in), .sdram_dm(sdram_dm)
    );
    assign sdram_dq = dq_oe ? dq_out : 16'hzzzz;
    // Clock to the SDRAM chip, phase-shifted to centre the chip's write-data sampling.
    // WR_CLK_PHASE is a compile-time constant so this is a plain clock mux, not a glitch.
    assign sdram_clk = (WR_CLK_PHASE == 0) ? clk_sdram :
                       (WR_CLK_PHASE == 1) ? clk90     :
                       (WR_CLK_PHASE == 2) ? ~clk_sdram : ~clk90;

    // ---- calibration FSM (segment-aware: NSEG row segments per access) ----
    typedef enum logic [2:0] { S_INIT, S_WREQ, S_WDATA, S_WWAIT, S_RREQ, S_RDATA, S_RWAIT } st_e;
    st_e st;
    logic [9:0] widx, ridx;          // global word index across segments
    logic [9:0] seg_cnt;             // words done in the current segment
    logic       cur_seg;             // 0..NSEG-1
    logic [9:0] errcnt;
    logic [9:0] err [0:3];           // per-phase error count (0..NW), live
    assign wr_data = pat(widx);

    integer k;
    always_ff @(posedge clk_sdram) begin
        if (sys_rst) begin
            st<=S_INIT; req_valid<=0; req_wr<=0; req_addr<=0; req_len<=0; wr_valid<=0;
            widx<=0; ridx<=0; seg_cnt<=0; cur_seg<=0; errcnt<=0; cur_phase<=0;
            for (k=0;k<4;k++) err[k] <= 10'(NW);
        end else begin
            case (st)
                S_INIT: if (req_ready) begin cur_seg<=0; widx<=0; st<=S_WREQ; end
                S_WREQ: begin
                    req_valid<=1; req_wr<=1; req_addr<=seg_addr(cur_seg); req_len<=seg_len(cur_seg);
                    if (req_valid && req_ready) begin req_valid<=0; seg_cnt<=0; wr_valid<=1; st<=S_WDATA; end
                end
                S_WDATA: begin
                    wr_valid<=1;
                    if (wr_ready && wr_valid) begin
                        widx<=widx+10'd1; seg_cnt<=seg_cnt+10'd1;
                        if (seg_cnt==seg_len(cur_seg)-10'd1) begin wr_valid<=0; st<=S_WWAIT; end
                    end
                end
                S_WWAIT: if (done) begin
                    if (cur_seg < (NSEG-1)) begin cur_seg<=cur_seg+1'b1; st<=S_WREQ; end
                    else begin cur_seg<=0; cur_phase<=0; ridx<=0; errcnt<=0; st<=S_RREQ; end
                end
                S_RREQ: begin
                    req_valid<=1; req_wr<=0; req_addr<=seg_addr(cur_seg); req_len<=seg_len(cur_seg);
                    if (req_valid && req_ready) begin req_valid<=0; seg_cnt<=0; st<=S_RDATA; end
                end
                S_RDATA: if (rd_valid) begin
                    if (rd_data !== pat(ridx)) errcnt <= errcnt + 10'd1;
                    ridx<=ridx+10'd1; seg_cnt<=seg_cnt+10'd1;
                    if (seg_cnt==seg_len(cur_seg)-10'd1) st<=S_RWAIT;
                end
                S_RWAIT: if (done) begin
                    if (cur_seg < (NSEG-1)) begin cur_seg<=cur_seg+1'b1; st<=S_RREQ; end
                    else begin                               // finished all segments for this phase
                        err[cur_phase] <= errcnt;
                        cur_phase <= cur_phase + 2'd1;       // next phase, sweep forever
                        cur_seg<=0; ridx<=0; errcnt<=0; st<=S_RREQ;
                    end
                end
                default: st <= S_INIT;
            endcase
        end
    end

    // ---- LCD: 4 vertical bands, red bar height = err[band] (px from top) ----
    logic [10:0] x; logic [9:0] y; logic de, de_d;
    scan_timing #(.H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE), .V_TOTAL(V_TOTAL))
        u_t (.pclk(clk_pix), .rst(pix_rst), .x(x), .y(y), .de(de));
    assign LCD_CLK = clk_pix;
    always_ff @(posedge clk_pix) de_d <= de;
    assign LCD_DEN = de_d;

    wire [1:0] band = (x < 11'd200) ? 2'd0 : (x < 11'd400) ? 2'd1 : (x < 11'd600) ? 2'd2 : 2'd3;
    wire       red  = (y < err[band]);
    always_comb begin
        LCD_R = 5'd0; LCD_G = 6'd0; LCD_B = 5'd0;
        if (de_d) begin
            if (err[band] == 10'd0) LCD_G = 6'd63;   // clean phase -> green band
            else if (red)          LCD_R = 5'd31;   // error bar (taller = worse)
            else                   LCD_B = 5'd8;     // dim background below the bar
        end
    end

endmodule
