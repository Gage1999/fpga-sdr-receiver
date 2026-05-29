// sdram_test_top.sv
// Standalone SDRAM bring-up test: PLL + sdram_ctrl, an FSM writes a 256-word
// pattern to FB address 0 and reads it back, and the LCD fills solid to report:
// blue = running, green = pass, red = mismatch.
// `define SIMULATION bypasses the PLL (clk_sdram = clk_pix = CLK) for iverilog.

module sdram_test_top (
    input  logic        CLK,           // 25 MHz

    // LCD (used as a pass/fail indicator)
    output logic        LCD_CLK,
    output logic        LCD_DEN,
    output logic [4:0]  LCD_R,
    output logic [5:0]  LCD_G,
    output logic [4:0]  LCD_B,

    // SDRAM (IS42S16160B)
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

    localparam int N = 256;            // words to write/read (single page, col 0)

    // ---- Clocks ----
    logic clk_sdram, clk_pix, pll_locked;
`ifdef SIMULATION
    assign clk_sdram  = CLK;
    assign clk_pix    = CLK;
    assign pll_locked = 1'b1;
`else
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(6), .CLKOP_CPHASE(0), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(20), .CLKOS_CPHASE(0), .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("DISABLED"), .CLKOS2_DIV(1), .CLKOS2_CPHASE(0), .CLKOS2_FPHASE(0),
        .CLKOS3_ENABLE("DISABLED"), .CLKOS3_DIV(1), .CLKOS3_CPHASE(0), .CLKOS3_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(4)
    ) u_pll (
        .CLKI(CLK), .CLKFB(clk_sdram), .CLKOP(clk_sdram), .CLKOS(clk_pix),
        .CLKOS2(), .CLKOS3(),
        .RST(1'b0), .STDBY(1'b0),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b0), .PHASESTEP(1'b0), .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .ENCLKOS(1'b0), .ENCLKOS2(1'b0), .ENCLKOS3(1'b0),
        .LOCK(pll_locked)
    );
`endif

    // ---- Reset (clk_sdram domain) ----
    logic [7:0] rst_cnt = 8'd0;
    logic       sys_rst = 1'b1;
    always_ff @(posedge clk_sdram) begin
        if (!pll_locked) begin rst_cnt <= 8'd0; sys_rst <= 1'b1; end
        else if (!rst_cnt[7]) begin rst_cnt <= rst_cnt + 8'd1; sys_rst <= 1'b1; end
        else sys_rst <= 1'b0;
    end

    // ---- Controller ----
    logic        req_valid, req_wr, req_ready, wr_valid, wr_ready, rd_valid, done;
    logic [24:0] req_addr;
    logic [9:0]  req_len;
    logic [15:0] wr_data, rd_data;
    logic [15:0] dq_out, dq_in;
    logic        dq_oe;

    sdram_ctrl u_ctrl (
        .clk(clk_sdram), .rst(sys_rst),
        .req_valid(req_valid), .req_wr(req_wr), .req_addr(req_addr), .req_len(req_len),
        .req_ready(req_ready),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in),
        .sdram_dm(sdram_dm)
    );

    // Bidirectional DQ bus (yosys infers an ECP5 BB from inout + tristate)
    assign sdram_dq = dq_oe ? dq_out : 16'hzzzz;
    assign dq_in    = sdram_dq;

    // Deterministic test pattern (distinct per index for idx < 256)
    function automatic logic [15:0] pat(input logic [9:0] idx);
        pat = {idx[7:0], idx[7:0]} ^ 16'hA5C3;
    endfunction

    // ---- Test FSM (clk_sdram domain) ----
    typedef enum logic [2:0] {
        ST_INIT, ST_WREQ, ST_WDATA, ST_WWAIT, ST_RREQ, ST_RDATA, ST_RWAIT, ST_DONE
    } st_e;
    st_e st;
    logic [9:0] widx, ridx;
    logic       test_done, test_fail;

    assign wr_data = pat(widx);

    always_ff @(posedge clk_sdram) begin
        if (sys_rst) begin
            st <= ST_INIT; req_valid <= 1'b0; req_wr <= 1'b0; req_addr <= 25'd0; req_len <= 10'd0;
            wr_valid <= 1'b0; widx <= 10'd0; ridx <= 10'd0; test_done <= 1'b0; test_fail <= 1'b0;
        end else begin
            case (st)
                // req_valid is asserted *inside* each REQ state (not in the preceding
                // state) so the controller gets an idle cycle to raise req_ready before we
                // sample (req_valid && req_ready) — same convention scan_out/compositor use.
                ST_INIT: if (req_ready) st <= ST_WREQ;
                ST_WREQ: begin
                    req_valid <= 1'b1; req_wr <= 1'b1; req_addr <= 25'd0; req_len <= 10'(N);
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0; widx <= 10'd0; wr_valid <= 1'b1; st <= ST_WDATA;
                    end
                end
                ST_WDATA: begin
                    wr_valid <= 1'b1;
                    if (wr_ready && wr_valid) begin
                        widx <= widx + 10'd1;
                        if (widx == 10'(N-1)) begin wr_valid <= 1'b0; st <= ST_WWAIT; end
                    end
                end
                ST_WWAIT: if (done) st <= ST_RREQ;
                ST_RREQ: begin
                    req_valid <= 1'b1; req_wr <= 1'b0; req_addr <= 25'd0; req_len <= 10'(N);
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0; ridx <= 10'd0; st <= ST_RDATA;
                    end
                end
                ST_RDATA: if (rd_valid) begin
                    if (rd_data !== pat(ridx)) test_fail <= 1'b1;
                    ridx <= ridx + 10'd1;
                    if (ridx == 10'(N-1)) st <= ST_RWAIT;
                end
                ST_RWAIT: if (done) st <= ST_DONE;
                ST_DONE:  test_done <= 1'b1;
                default:  st <= ST_INIT;
            endcase
        end
    end

    // ---- Result -> pixel domain (2-FF sync) ----
    logic done_s1, done_s2, fail_s1, fail_s2;
    always_ff @(posedge clk_pix) begin
        done_s1 <= test_done; done_s2 <= done_s1;
        fail_s1 <= test_fail; fail_s2 <= fail_s1;
    end

    // ---- LCD solid-fill indicator (clk_pix domain, 800x480 @ 928x525) ----
    logic [10:0] x = 11'd0;
    logic [9:0]  y = 10'd0;
    always_ff @(posedge clk_pix) begin
        if (x < 11'd927) x <= x + 11'd1;
        else begin
            x <= 11'd0;
            y <= (y < 10'd524) ? y + 10'd1 : 10'd0;
        end
    end
    assign LCD_CLK = clk_pix;

    always_comb begin
        LCD_R = 5'd0; LCD_G = 6'd0; LCD_B = 5'd0;
        LCD_DEN = (x < 11'd800) && (y < 10'd480);
        if (LCD_DEN) begin
            if (!done_s2)      begin LCD_B = 5'd31;          end // testing  -> blue
            else if (fail_s2)  begin LCD_R = 5'd31;          end // mismatch -> red
            else               begin LCD_G = 6'd63;          end // pass     -> green
        end
    end

endmodule
