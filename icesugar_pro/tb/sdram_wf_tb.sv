// Integration sim for top_sdram_wf (Phase 4+5): generator -> async_fifo -> compositor
// -> arbiter -> controller -> SDRAM model -> scan_out -> line_cache -> LCD.

// A behavioral SDRAM model captures the compositor's writes and serves scan_out's

`timescale 1ns/1ps

module sdram_wf_tb;

    localparam int H_ACTIVE = 800, V_ACTIVE = 480, LINE_WORDS = 800;

    logic CLK = 0;
    always #5 CLK = ~CLK;     // 100 MHz in sim (clk_sdram = CLK under SIMULATION)

    logic LCD_CLK, LCD_DEN;
    logic [4:0] LCD_R, LCD_B; logic [5:0] LCD_G;
    logic sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic [1:0] sdram_ba, sdram_dm; logic [12:0] sdram_a;
    wire  [15:0] sdram_dq;

    // GEN_DIV small so the throttled source still produces enough rows within sim time.
    top_sdram_wf #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .LINE_WORDS(LINE_WORDS), .GEN_DIV(16)) dut (
        .CLK(CLK), .LCD_CLK(LCD_CLK), .LCD_DEN(LCD_DEN), .LCD_R(LCD_R), .LCD_G(LCD_G), .LCD_B(LCD_B),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dm(sdram_dm), .sdram_dq(sdram_dq)
    );

    // Behavioral SDRAM model (bank 0). clk_sdram == CLK in sim.
    logic [15:0] sdram_mem [0:4*8192*512-1];
    logic [12:0] active_row [0:3];
    logic [1:0]  wr_ba; logic [9:0] wr_col; int wr_burst; logic wr_active;
    logic        rdp_v [0:2]; logic [1:0] rdp_ba [0:2]; logic [12:0] rdp_row [0:2]; logic [9:0] rdp_col [0:2]; int rdp_cnt [0:2];

    wire [3:0] cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};
    function automatic int flat_addr(input logic [1:0] ba, input logic [12:0] row, input int col);
        flat_addr = (ba * 8192 + row) * 512 + col;
    endfunction

    integer mi;
    initial begin
        wr_active=0; wr_ba=0; wr_col=0; wr_burst=0;
        for (mi=0; mi<3; mi++) begin rdp_v[mi]=0; rdp_ba[mi]=0; rdp_row[mi]=0; rdp_col[mi]=0; rdp_cnt[mi]=0; end
        for (mi=0; mi<4; mi++) active_row[mi]=0;
        // Pre-fill with a varying pattern whose R field != B field, so (a) scan_out always
        // reads real, varying data (LCD varies even before the waterfall scroll catches up),
        // and (b) compositor writes are distinguishable: the generator's palette is
        // {m[7:3],m[7:2],m[7:3]} -> R field == B field, which this pre-fill never produces.
        for (mi=0; mi < 1500*512; mi++) sdram_mem[mi] = {5'(mi), 6'(mi>>5), 5'((mi & 31) ^ 21)};
    end

    // command + write capture (dut.dq_oe / dut.dq_out probed hierarchically)
    always @(posedge CLK) begin
        case (cmd)
            4'b0011: active_row[sdram_ba] <= sdram_a[12:0];                       // ACTIVE
            4'b0100: begin wr_ba<=sdram_ba; wr_col<=sdram_a[9:0]; wr_burst<=0; wr_active<=1; end // WRITE
            default: ;
        endcase
        if (wr_active && dut.dq_oe) begin
            sdram_mem[flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst)] <= dut.dq_out;
            wr_burst <= wr_burst + 1;
        end
    end

    // read pipeline -> CL=2; drive the bus only while serving a read
    always @(posedge CLK) begin
        rdp_v[2]<=rdp_v[1]; rdp_ba[2]<=rdp_ba[1]; rdp_row[2]<=rdp_row[1]; rdp_col[2]<=rdp_col[1]; rdp_cnt[2]<=rdp_cnt[1];
        rdp_v[1]<=rdp_v[0]; rdp_ba[1]<=rdp_ba[0]; rdp_row[1]<=rdp_row[0]; rdp_col[1]<=rdp_col[0]; rdp_cnt[1]<=rdp_cnt[0];
        if (cmd == 4'b0101) begin // READ
            rdp_v[0]<=1; rdp_ba[0]<=sdram_ba; rdp_row[0]<=active_row[sdram_ba]; rdp_col[0]<=sdram_a[9:0]; rdp_cnt[0]<=0;
        end else if (rdp_v[0]) rdp_cnt[0]<=rdp_cnt[0]+1;
    end
    wire [22:0] rd_addr_w = flat_addr(rdp_ba[2], rdp_row[2], rdp_col[2] + rdp_cnt[2]);
    assign sdram_dq = rdp_v[2] ? sdram_mem[rd_addr_w] : 16'hzzzz;

    // liveness monitors.
    // Per-frame line-fill tracking: with the throttled (realistic) generator the compositor
    // barely touches the bus, so scan_out must keep up - every active display line should be
    // freshly fetched. We count distinct lines scan_out delivered (w_en) vs lines displayed.
    int    cache_writes = 0, comp_writes = 0, lcd_active = 0, lcd_xpix = 0;
    logic [15:0] lcd_min = 16'hFFFF, lcd_max = 16'h0000;
    // Measure only after the startup FB clear has finished and scan_out has filled the cache.
    logic measure = 0;
    initial begin #8000000; measure = 1; end
    always @(posedge CLK) begin
        if (measure && dut.w_en) cache_writes <= cache_writes + 1;                      // scan_out reads
        if (measure && dut.c_wr_valid[1] && dut.c_wr_ready[1]) comp_writes <= comp_writes + 1; // compositor write beats
    end
    always @(posedge LCD_CLK) begin
        if (measure && LCD_DEN) begin
            lcd_active <= lcd_active + 1;
            if (^{LCD_R,LCD_G,LCD_B} === 1'bx) lcd_xpix <= lcd_xpix + 1;   // undefined pixel = bad
            if ({LCD_R,LCD_G,LCD_B} < lcd_min) lcd_min <= {LCD_R,LCD_G,LCD_B};
            if ({LCD_R,LCD_G,LCD_B} > lcd_max) lcd_max <= {LCD_R,LCD_G,LCD_B};
        end
    end

    function automatic int fb_at(input int w);
        fb_at = sdram_mem[(w/256)*512 + (w%256)];
    endfunction

    logic fb_grad;
    initial begin
        #16000000;  // 16 ms: startup clear (~4 ms) + operation
        // Checks: the FB clear completed; scan_out keeps up (no starvation, cache_writes ~
        fb_grad = (fb_at(5*800+799) > fb_at(5*800+8)) && (fb_at(5*800+799) != 0);
        $display("clr_done=%0b cache_writes=%0d lcd_active=%0d comp_writes=%0d xpix=%0d  FBrow5[x8=%04h x799=%04h]",
                 dut.clr_done, cache_writes, lcd_active, comp_writes, lcd_xpix, fb_at(5*800+8), fb_at(5*800+799));
        if (dut.clr_done && cache_writes > (lcd_active*7)/10 && comp_writes > 100 && lcd_xpix == 0 && fb_grad)
            $display("PASS: clear works, scan_out keeps up, compositor's gradient lands correctly in SDRAM");
        else
            $display("FAIL: clr_done=%0b cache_writes=%0d lcd_active=%0d comp_writes=%0d xpix=%0d fb_grad=%0b",
                     dut.clr_done, cache_writes, lcd_active, comp_writes, lcd_xpix, fb_grad);
        $finish;
    end

    initial begin #24000000; $display("TIMEOUT"); $finish; end

endmodule
