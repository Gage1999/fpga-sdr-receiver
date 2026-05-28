// SDRAM hardware display test
// 1. Writes a test pattern to the first 480 lines of SDRAM.
// 2. Uses scan_out and line_cache to fetch those lines.
// 3. Uses a simplified lcd_reader to display the cached lines on the screen.
// Expected output: A colorful gradient/test pattern on the LCD.

module sdram_display_top(
    input  logic CLK,
    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B,
    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    inout  logic [15:0] sdram_dq,
    output logic [1:0]  sdram_dm
);

// -----------------------------------------------------------------------
// Clocks and Reset
// -----------------------------------------------------------------------
logic clk_sdram, clk_pix, pll_locked, rst;
EHXPLLL #(.FEEDBK_PATH("CLKOP"), .CLKFB_DIV(4), .CLKI_DIV(1), .CLKOP_DIV(6), .CLKOS_DIV(20)) pll
    (.CLKI(CLK), .CLKFB(clk_sdram), .CLKOP(clk_sdram), .CLKOS(clk_pix), .LOCK(pll_locked), .STDBY(1'b0), .RST(1'b0),
     .PHASESEL0(1'b0), .PHASESEL1(1'b0),.PHASEDIR(1'b0), .PHASESTEP(1'b0), .PHASELOADREG(1'b0), .PLLWAKESYNC(1'b0),
     .ENCLKOP(1'b0), .ENCLKOS(1'b0));
always_ff @(posedge clk_sdram) rst <= ~pll_locked;

// -----------------------------------------------------------------------
// SDRAM Controller and Display Pipeline
// -----------------------------------------------------------------------
logic [24:0] ctrl_addr;
logic [15:0] ctrl_wr_data;
logic ctrl_wr_valid;
logic ctrl_req_valid, test_fsm_req_valid, scan_out_req_valid;
logic ctrl_req_wr, test_fsm_req_wr;
logic ctrl_req_ready;
logic done;

// Arbiter: Test FSM has priority to write pattern, then scan_out takes over
assign ctrl_req_valid = test_fsm_req_valid | scan_out_req_valid;
assign ctrl_req_wr = test_fsm_req_valid ? test_fsm_req_wr : 1'b0;
assign ctrl_addr = test_fsm_req_valid ? test_fsm_addr : scan_out_addr;
assign test_fsm_req_ready = ctrl_req_ready & test_fsm_req_valid;
assign scan_out_req_ready = ctrl_req_ready & ~test_fsm_req_valid;

logic [15:0] sdram_dq_out;
logic sdram_dq_oe;
logic [15:0] sdram_dq_in;
assign sdram_dq = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
assign sdram_dq_in = sdram_dq;

sdram_ctrl sdram (
    .clk(clk_sdram), .rst(rst),
    .req_valid(ctrl_req_valid), .req_wr(ctrl_req_wr), .req_addr(ctrl_addr), .req_len(test_fsm_req_valid ? 10'd1 : scan_out_req_len), .req_ready(ctrl_req_ready),
    .wr_data(ctrl_wr_data), .wr_valid(ctrl_wr_valid), .wr_ready(test_fsm_wr_ready),
    .rd_data(scan_out_rd_data), .rd_valid(scan_out_rd_valid), .done(done),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_in(sdram_dq_in), .sdram_dm(sdram_dm)
);

// Scan out and line cache
logic [9:0]  px_v_cnt;
logic        px_h_blank;
logic [24:0] scan_out_addr;
logic [15:0] scan_out_rd_data, lc_rd_data;
logic        scan_out_rd_valid;
logic [1:0]  lc_w_slot, lc_r_slot;
logic [9:0]  lc_w_col, lc_r_col;
logic [15:0] lc_w_data;
logic        lc_w_en;
logic [9:0]  scan_out_req_len;

scan_out so (.clk(clk_sdram), .rst(rst), .px_v_cnt(px_v_cnt), .px_h_blank(px_h_blank), .fb_base_addr(25'h0),
    .req_valid(scan_out_req_valid), .req_ready(scan_out_req_ready), .req_addr(scan_out_addr), .req_len(scan_out_req_len),
    .rd_data(scan_out_rd_data), .rd_valid(scan_out_rd_valid),
    .w_slot(lc_w_slot), .w_col(lc_w_col), .w_data(lc_w_data), .w_en(lc_w_en));

line_cache lc (.wclk(clk_sdram), .w_slot(lc_w_slot), .w_col(lc_w_col), .w_data(lc_w_data), .w_en(lc_w_en),
    .rclk(clk_pix), .r_slot(lc_r_slot), .r_col(lc_r_col), .r_data(lc_rd_data));

// -----------------------------------------------------------------------
// Test FSM to write pattern
// -----------------------------------------------------------------------
logic test_fsm_wr_ready;
logic [24:0] test_fsm_addr;
logic pattern_write_done = 0;
function automatic logic [15:0] test_pixel(input integer row, input integer col);
    return { (col[7:3] + row[7:3]), (col[5:3] + row[5:3]), (col[7:4] + row[7:4]) };
endfunction

always_ff @(posedge clk_sdram) begin
    if (rst || pattern_write_done) begin
        test_fsm_req_valid <= 0;
        ctrl_wr_valid <= 0;
    end else if (done) begin // After each write, request next
        test_fsm_addr <= test_fsm_addr + 25'd2;
        test_fsm_req_valid <= 1;
        ctrl_wr_valid <= 1;
        ctrl_wr_data <= test_pixel((test_fsm_addr + 25'd2)[19:11], (test_fsm_addr + 25'd2)[10:1]);
        if (test_fsm_addr >= 25'd983038) pattern_write_done <= 1; // 480*1024*2 - 2
    end else if (test_fsm_req_ready) begin
        test_fsm_req_valid <= 0; // Wait for done
    end else if (~test_fsm_req_valid) begin // Initial request
        test_fsm_addr <= 0;
        test_fsm_req_valid <= 1;
        test_fsm_req_wr <= 1;
        ctrl_wr_valid <= 1;
        ctrl_wr_data <= test_pixel(0, 0);
    end
end

// -----------------------------------------------------------------------
// LCD driver
// -----------------------------------------------------------------------
logic [9:0] H_CNT, V_CNT;
localparam H_TOTAL=928, V_TOTAL=525;
assign LCD_CLK = clk_pix;

always_ff @(posedge clk_pix) begin
    if (H_CNT < H_TOTAL-1) H_CNT <= H_CNT + 1;
    else begin H_CNT <= 0; if (V_CNT < V_TOTAL-1) V_CNT <= V_CNT + 1; else V_CNT <= 0; end
end
assign px_v_cnt = V_CNT;
assign px_h_blank = (H_CNT >= 800);
assign LCD_DEN = (H_CNT < 800) && (V_CNT < 480);
assign lc_r_col = H_CNT;
assign lc_r_slot = V_CNT[1:0] + 2'd1;

assign {LCD_R, LCD_G, LCD_B} = LCD_DEN ? lc_rd_data : 16'd0;

endmodule
