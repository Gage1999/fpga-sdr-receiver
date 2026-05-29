// Sim for top_sdram_color.sv (compile with -DSIMULATION; PLL bypassed).
// Reduced height (V_ACTIVE=4) for speed, full 800-wide lines so the page-split
// fetch is still exercised. A behavioral SDRAM model loops fill writes back on
// read; once the pipeline has settled, the LCD output is scraped and each active
// pixel is checked against the expected colour bar.

`timescale 1ns/1ps

module sdram_color_tb;

    localparam int H_ACTIVE = 800, H_TOTAL = 928, V_ACTIVE = 4, V_TOTAL = 12, LINE_WORDS = 800;

    logic CLK = 0;
    always #5 CLK = ~CLK;

    logic        LCD_CLK, LCD_DEN;
    logic [4:0]  LCD_R, LCD_B;
    logic [5:0]  LCD_G;
    logic        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic [1:0]  sdram_ba, sdram_dm;
    logic [12:0] sdram_a;
    wire  [15:0] sdram_dq;

    top_sdram_color #(.H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE),
                      .V_TOTAL(V_TOTAL), .LINE_WORDS(LINE_WORDS)) dut (
        .CLK(CLK), .LCD_CLK(LCD_CLK), .LCD_DEN(LCD_DEN), .LCD_R(LCD_R), .LCD_G(LCD_G), .LCD_B(LCD_B),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dm(sdram_dm), .sdram_dq(sdram_dq)
    );

    // ---- Behavioral SDRAM (bank 0): write capture + CL=2 read, on the shared bus ----
    logic [15:0] mem [0:8192*512-1];
    logic [12:0] active_row [0:3];
    logic [1:0]  wr_ba; logic [9:0] wr_col; int wr_burst; logic wr_active;
    logic        rdp_v [0:2]; logic [12:0] rdp_row [0:2]; logic [9:0] rdp_col [0:2]; int rdp_cnt [0:2];

    wire [3:0] cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};
    localparam ACT=4'b0011, RD=4'b0101, WR=4'b0100, PRE=4'b0010;
    function automatic int faddr(input logic [12:0] row, input int col); faddr = row*512 + col; endfunction

    integer i;
    initial begin
        wr_active=0; wr_ba=0; wr_col=0; wr_burst=0;
        for (i=0;i<3;i++) begin rdp_v[i]=0; rdp_row[i]=0; rdp_col[i]=0; rdp_cnt[i]=0; end
        for (i=0;i<4;i++) active_row[i]=0;
        for (i=0;i<V_ACTIVE*LINE_WORDS;i++) mem[i]=16'h0;
    end

    always @(posedge sdram_clk) begin
        case (cmd)
            ACT: active_row[sdram_ba] <= sdram_a[12:0];
            WR:  begin wr_ba<=sdram_ba; wr_col<=sdram_a[9:0]; wr_burst<=0; wr_active<=1; end
            PRE: wr_active <= 0;
            default: ;
        endcase
        if (wr_active && (sdram_dq !== 16'hzzzz)) begin
            mem[faddr(active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq;
            wr_burst <= wr_burst + 1;
        end
    end
    always @(posedge sdram_clk) begin
        rdp_v[2]<=rdp_v[1]; rdp_row[2]<=rdp_row[1]; rdp_col[2]<=rdp_col[1]; rdp_cnt[2]<=rdp_cnt[1];
        rdp_v[1]<=rdp_v[0]; rdp_row[1]<=rdp_row[0]; rdp_col[1]<=rdp_col[0]; rdp_cnt[1]<=rdp_cnt[0];
        if (cmd == RD) begin
            rdp_v[0]<=1; rdp_row[0]<=active_row[sdram_ba]; rdp_col[0]<=sdram_a[9:0]; rdp_cnt[0]<=0;
        end else if (cmd == PRE) rdp_v[0]<=0;
        else if (rdp_v[0]) rdp_cnt[0]<=rdp_cnt[0]+1;
    end
    assign sdram_dq = rdp_v[2] ? mem[faddr(rdp_row[2], rdp_col[2] + rdp_cnt[2])] : 16'hzzzz;

    // ---- Reference + LCD scraper ----
    function automatic logic [15:0] colorbar(input int col);
        int w; w = H_ACTIVE/4;
        if      (col < w)   colorbar = 16'hF800;
        else if (col < 2*w) colorbar = 16'h07E0;
        else if (col < 3*w) colorbar = 16'h001F;
        else                colorbar = 16'hFFFF;
    endfunction

    int  col_ctr = 0, errors = 0, checked = 0;
    logic checking = 0;

    // Sample the LCD on its own clock (LCD_CLK = clk_pix) — one pixel per cycle.
    always @(posedge LCD_CLK) begin
        if (LCD_DEN) begin
            if (checking) begin
                logic [15:0] got, exp;
                got = {LCD_R, LCD_G, LCD_B};
                exp = colorbar(col_ctr);
                if (got !== exp) begin
                    if (errors < 12) $display("FAIL col %0d: expected %04h got %04h", col_ctr, exp, got);
                    errors = errors + 1;
                end
                checked = checked + 1;
            end
            col_ctr <= col_ctr + 1;
        end else begin
            col_ctr <= 0;
        end
    end

    initial begin
        $display("Waiting for framebuffer fill...");
        wait (dut.fill_done === 1'b1);
        $display("Fill done at %0t ns; letting the prefetch pipeline settle...", $time);
        // Settle / check counted in pixel-clock cycles (LCD_CLK).
        repeat (2*V_TOTAL*H_TOTAL) @(posedge LCD_CLK);
        checking = 1'b1;
        repeat (3*V_TOTAL*H_TOTAL) @(posedge LCD_CLK);
        checking = 1'b0;

        if (checked == 0)            $display("FAILED: no active pixels checked");
        else if (errors == 0)        $display("ALL TESTS PASSED (%0d pixels checked)", checked);
        else                         $display("FAILED: %0d errors (of %0d checked)", errors, checked);
        $finish;
    end

    initial begin #20000000; $display("TIMEOUT"); $finish; end

endmodule
