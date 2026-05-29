// Simulation of sdram_test_top.sv (compile with -DSIMULATION so the PLL is bypassed).
// A behavioral IS42S16160B model sits on the bidirectional DQ bus and loops the
// written pattern back on read. The test passes if the DUT's FSM reaches
// test_done with test_fail == 0.  (iverilog: models the tri-state DQ bus.)

`timescale 1ns/1ps

module sdram_test_top_tb;

    logic CLK = 0;
    always #5 CLK = ~CLK;   // 100 MHz in SIMULATION (clk_sdram = CLK)

    logic        LCD_CLK, LCD_DEN;
    logic [4:0]  LCD_R, LCD_B;
    logic [5:0]  LCD_G;

    logic        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic [1:0]  sdram_ba, sdram_dm;
    logic [12:0] sdram_a;
    wire  [15:0] sdram_dq;

    sdram_test_top dut (
        .CLK(CLK),
        .LCD_CLK(LCD_CLK), .LCD_DEN(LCD_DEN), .LCD_R(LCD_R), .LCD_G(LCD_G), .LCD_B(LCD_B),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dm(sdram_dm), .sdram_dq(sdram_dq)
    );

    // ---- Behavioral SDRAM on the shared DQ bus ----
    logic [15:0] mem [0:8192*512-1];   // bank 0
    logic [12:0] active_row [0:3];
    logic [1:0]  wr_ba; logic [9:0] wr_col; int wr_burst; logic wr_active;
    logic        rdp_v [0:2]; logic [1:0] rdp_ba [0:2]; logic [12:0] rdp_row [0:2];
    logic [9:0]  rdp_col [0:2]; int rdp_cnt [0:2];

    wire [3:0] cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};
    localparam CMD_ACTIVE=4'b0011, CMD_READ=4'b0101, CMD_WRITE=4'b0100, CMD_PRECH=4'b0010;

    function automatic int faddr(input logic [12:0] row, input int col); faddr = row*512 + col; endfunction

    integer i;
    initial begin
        wr_active=0; wr_ba=0; wr_col=0; wr_burst=0;
        for (i=0;i<3;i++) begin rdp_v[i]=0; rdp_ba[i]=0; rdp_row[i]=0; rdp_col[i]=0; rdp_cnt[i]=0; end
        for (i=0;i<4;i++) active_row[i]=0;
        for (i=0;i<256;i++) mem[i]=16'h0;
    end

    // command + write capture
    always @(posedge sdram_clk) begin
        case (cmd)
            CMD_ACTIVE: active_row[sdram_ba] <= sdram_a[12:0];
            CMD_WRITE:  begin wr_ba<=sdram_ba; wr_col<=sdram_a[9:0]; wr_burst<=0; wr_active<=1'b1; end
            CMD_PRECH:  wr_active <= 1'b0;
            default: ;
        endcase
        if (wr_active && (sdram_dq !== 16'hzzzz)) begin
            mem[faddr(active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq;
            wr_burst <= wr_burst + 1;
        end
    end

    // read pipeline (CL=2), cleared on PRECHARGE
    always @(posedge sdram_clk) begin
        rdp_v[2]<=rdp_v[1]; rdp_ba[2]<=rdp_ba[1]; rdp_row[2]<=rdp_row[1]; rdp_col[2]<=rdp_col[1]; rdp_cnt[2]<=rdp_cnt[1];
        rdp_v[1]<=rdp_v[0]; rdp_ba[1]<=rdp_ba[0]; rdp_row[1]<=rdp_row[0]; rdp_col[1]<=rdp_col[0]; rdp_cnt[1]<=rdp_cnt[0];
        if (cmd == CMD_READ) begin
            rdp_v[0]<=1; rdp_ba[0]<=sdram_ba; rdp_row[0]<=active_row[sdram_ba]; rdp_col[0]<=sdram_a[9:0]; rdp_cnt[0]<=0;
        end else if (cmd == CMD_PRECH) begin
            rdp_v[0]<=0;
        end else if (rdp_v[0]) begin
            rdp_cnt[0]<=rdp_cnt[0]+1;
        end
    end

    assign sdram_dq = rdp_v[2] ? mem[faddr(rdp_row[2], rdp_col[2] + rdp_cnt[2])] : 16'hzzzz;

    // ---- Checker ----
    initial begin
        wait (dut.test_done === 1'b1);
        @(posedge CLK);
        if (dut.test_fail === 1'b0) $display("ALL TESTS PASSED");
        else                        $display("FAILED: pattern mismatch");
        $finish;
    end

    initial begin #3000000; $display("TIMEOUT"); $finish; end

endmodule
