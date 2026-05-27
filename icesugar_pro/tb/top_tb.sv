`timescale 1ns/1ps

module top_tb;

localparam CLK_PERIOD = 40;
localparam SPI_HALF = 5 * CLK_PERIOD;

logic CLK;
logic spi_clk, cs, mosi;
logic spi_clk_pico, cs1, mosi_pico;
logic i2s_bclk, i2s_lrclk, i2s_sdata;
logic LCD_CLK, LCD_DEN;
logic [4:0] LCD_R;
logic [5:0] LCD_G;
logic [4:0] LCD_B;

top dut (
    .CLK (CLK),
    .spi_clk (spi_clk),
    .cs (cs),
    .mosi (mosi),
    .spi_clk_pico (spi_clk_pico),
    .cs1 (cs1),
    .mosi_pico (mosi_pico),
    .i2s_bclk (i2s_bclk),
    .i2s_lrclk (i2s_lrclk),
    .i2s_sdata (i2s_sdata),
    .LCD_CLK (LCD_CLK),
    .LCD_DEN (LCD_DEN),
    .LCD_R (LCD_R),
    .LCD_G (LCD_G),
    .LCD_B (LCD_B)
);

// Clock
initial CLK = 0;
always #(CLK_PERIOD/2) CLK = ~CLK;

initial begin
    spi_clk = 1;
    cs = 1;
    mosi = 0;
    spi_clk_pico = 1;
    cs1 = 1;
    mosi_pico = 0;
end

task automatic spi_send_iq(input logic [15:0] i_val, input logic [15:0] q_val);
    logic [31:0] data;
    int k;
    data = {i_val, q_val};
    cs = 0;
    #SPI_HALF;
    for (k = 31; k >= 0; k--) begin
        mosi = data[k];
        #SPI_HALF;
        spi_clk = 0;
        #SPI_HALF;
        spi_clk = 1;
    end
    mosi = 0;
    #SPI_HALF;
    cs = 1;
    #(4 * SPI_HALF);
endtask

task automatic spi_send_cmd(input logic [7:0] cmd, input logic [31:0] arg);
    logic [39:0] data;
    int k;
    data = {cmd, arg};
    cs1 = 0;
    #SPI_HALF;
    for (k = 39; k >= 0; k--) begin
        mosi_pico = data[k];
        #SPI_HALF;
        spi_clk_pico = 0;
        #SPI_HALF;
        spi_clk_pico = 1;
    end
    mosi_pico = 0;
    #SPI_HALF;
    cs1 = 1;
    #(4 * SPI_HALF);
endtask

integer errors = 0;

initial begin
    $dumpfile("build/top.vcd");
    $dumpvars(0, top_tb);

    #(20 * CLK_PERIOD);

    // SPI data path
    $display("TEST 1: SPI data path");

    spi_send_iq(16'h1234, 16'h5678);
    #(20 * CLK_PERIOD);

    if (dut.sys_i !== 16'h1234) begin
        $display("  FAIL sys_i: expected 0x1234 got 0x%04X", dut.sys_i);
        errors++;
    end else
        $display("  PASS sys_i = 0x1234");

    if (dut.sys_q !== 16'h5678) begin
        $display("  FAIL sys_q: expected 0x5678 got 0x%04X", dut.sys_q);
        errors++;
    end else
        $display("  PASS sys_q = 0x5678");

    spi_send_iq(16'hABCD, 16'hEF01);
    #(20 * CLK_PERIOD);

    if (dut.sys_i !== 16'hABCD) begin
        $display("  FAIL sys_i: expected 0xABCD got 0x%04X", dut.sys_i);
        errors++;
    end else
        $display("  PASS sys_i = 0xABCD");

    if (dut.sys_q !== 16'hEF01) begin
        $display("  FAIL sys_q: expected 0xEF01 got 0x%04X", dut.sys_q);
        errors++;
    end else
        $display("  PASS sys_q = 0xEF01");

    // Pico command path
    $display("TEST 2: Pico command path");

    spi_send_cmd(8'h02, 32'h0000_0040);
    #(20 * CLK_PERIOD);
    if (dut.volume !== 8'h40) begin
        $display("  FAIL volume: expected 0x40 got 0x%02X", dut.volume);
        errors++;
    end else
        $display("  PASS volume = 0x40");

    spi_send_cmd(8'h03, 32'd101_700_000);
    #(20 * CLK_PERIOD);
    if (dut.freq_hz !== 32'd101_700_000) begin
        $display("  FAIL freq_hz: expected 101700000 got %0d", dut.freq_hz);
        errors++;
    end else
        $display("  PASS freq_hz = 101700000");

    spi_send_cmd(8'h01, 32'h0000_0001);
    #(20 * CLK_PERIOD);
    if (dut.mode !== 3'd1) begin
        $display("  FAIL mode: expected 1 got %0d", dut.mode);
        errors++;
    end else
        $display("  PASS mode = 1");

    spi_send_cmd(8'h01, 32'h0000_0000);
    #(20 * CLK_PERIOD);

    // I2S pipeline
    $display("TEST 3: I2S pipeline");
    #(10 * CLK_PERIOD);

    if (i2s_bclk === 1'bx) begin
        $display("  FAIL i2s_bclk is X");
        errors++;
    end else
        $display("  PASS i2s_bclk active");

    if (i2s_lrclk === 1'bx) begin
        $display("  FAIL i2s_lrclk is X");
        errors++;
    end else
        $display("  PASS i2s_lrclk active");

    // LCD outputs
    $display("TEST 4: LCD outputs");
    #(100 * CLK_PERIOD);
    if (LCD_DEN === 1'bx) begin
        $display("  FAIL LCD_DEN is X");
        errors++;
    end else
        $display("  PASS LCD_DEN active");

    // Summary
    #(CLK_PERIOD);
    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

// Timeout
initial begin
    #(10_000_000);
    $display("TIMEOUT");
    $finish;
end

endmodule

