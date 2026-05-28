`timescale 1ns/1ps

module tb_lcd;

localparam CLK_PERIOD = 40;

logic pclk, rst;
logic [7:0] wf_magnitude;
logic [7:0] wf_bin;
logic [8:0] wf_row_age;
logic LCD_DE;
logic [4:0] LCD_R;
logic [5:0] LCD_G;
logic [4:0] LCD_B;

lcd dut (
    .rst (rst),
    .pclk (pclk),
    .mode (3'd0),
    .volume (8'hff),
    .mute (1'b0),
    .dbg_rx_count (8'd0),
    .dbg_bin_count (8'd0),
    .dbg_last_mag (8'd0),
    .rx_sps_bcd (32'h00390625),
    .wf_magnitude (wf_magnitude),
    .wf_bin (wf_bin),
    .wf_row_age (wf_row_age),
    .LCD_DE (LCD_DE),
    .LCD_R (LCD_R),
    .LCD_G (LCD_G),
    .LCD_B (LCD_B)
);

initial pclk = 0;
always #(CLK_PERIOD/2) pclk = ~pclk;

integer errors = 0;

initial begin
    $dumpfile("build/lcd.vcd");
    $dumpvars(0, tb_lcd);

    rst = 1'b1;
    wf_magnitude = 8'd128;

    repeat (4) @(posedge pclk);
    rst = 1'b0;

    wait (dut.x == 11'd383 && dut.y == 10'd0);
    #1;

    if (wf_bin !== 8'd255) begin
        $display("FAIL x=383 bin: expected 255 got %0d", wf_bin);
        errors++;
    end else begin
        $display("PASS x=383 bin = 255");
    end

    wait (dut.x == 11'd384 && dut.y == 10'd0);
    #1;

    if (wf_bin !== 8'd0) begin
        $display("FAIL x=384 bin: expected 0 got %0d", wf_bin);
        errors++;
    end else begin
        $display("PASS x=384 bin = 0");
    end

    wait (dut.x == 11'd767 && dut.y == 10'd0);
    #1;

    if (wf_bin !== 8'd127) begin
        $display("FAIL x=767 bin: expected 127 got %0d", wf_bin);
        errors++;
    end else begin
        $display("PASS x=767 bin = 127");
    end

    wait (dut.x == 11'd768 && dut.y == 10'd0);
    #1;

    if (wf_bin !== 8'd0) begin
        $display("FAIL x=768 bin: expected 0 got %0d", wf_bin);
        errors++;
    end else begin
        $display("PASS x=768 outside waterfall");
    end

    wait (dut.x == 11'd664 && dut.y == 10'd464);
    #1;

    if ({LCD_R, LCD_G, LCD_B} !== 16'hffff) begin
        $display("FAIL status text pixel: expected white got 0x%h", {LCD_R, LCD_G, LCD_B});
        errors++;
    end else begin
        $display("PASS status text pixel is white");
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

initial begin
    #25_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule
