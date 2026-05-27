`timescale 1ns/1ps

module tb_i2s_tx;

localparam CLK_PERIOD = 40;
localparam BCLK_DIV = 12;
localparam SLOT_BITS = 32;

localparam LEFT_VAL = 16'hA5C3;
localparam RIGHT_VAL = 16'h3CA5;

logic clk, rst;
logic [15:0] left_in, right_in;
logic sample_req;
logic bclk, lrclk, sdata;

i2s_tx #(.CLK_HZ(25_000_000), .BCLK_DIV(BCLK_DIV), .SLOT_BITS(SLOT_BITS)) dut (
    .clk (clk),
    .rst (rst),
    .left_in (left_in),
    .right_in (right_in),
    .sample_req (sample_req),
    .bclk (bclk),
    .lrclk (lrclk),
    .sdata (sdata)
);

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

logic [15:0] captured_left;
logic [15:0] captured_right;
logic [15:0] captured_left_pad;
logic [15:0] captured_right_pad;

logic [15:0] shift_cap;
int bit_pos;
logic capturing_left;

integer errors = 0;

task automatic wait_bclk_rise;
    @(posedge bclk);
    #1;
endtask

initial begin
    $dumpfile("build/i2s.vcd");
    $dumpvars(0, tb_i2s_tx);

    left_in = LEFT_VAL;
    right_in = RIGHT_VAL;
    rst = 1;
    #(4 * CLK_PERIOD);
    rst = 0;

    @(negedge lrclk);

    wait_bclk_rise();

    for (int k = 15; k >= 0; k--) begin
        wait_bclk_rise();
        captured_left[k] = sdata;
    end
    for (int k = 15; k >= 0; k--) begin
        wait_bclk_rise();
        captured_left_pad[k] = sdata;
    end

    @(posedge lrclk);

    wait_bclk_rise();

    for (int k = 15; k >= 0; k--) begin
        wait_bclk_rise();
        captured_right[k] = sdata;
    end
    for (int k = 15; k >= 0; k--) begin
        wait_bclk_rise();
        captured_right_pad[k] = sdata;
    end

    $display("TEST: I2S standard format");

    if (captured_left === LEFT_VAL)
        $display("  PASS left  = 0x%04X", captured_left);
    else begin
        $display("  FAIL left : expected 0x%04X got 0x%04X", LEFT_VAL, captured_left);
        errors++;
    end

    if (captured_right === RIGHT_VAL)
        $display("  PASS right = 0x%04X", captured_right);
    else begin
        $display("  FAIL right: expected 0x%04X got 0x%04X", RIGHT_VAL, captured_right);
        errors++;
    end

    if (captured_left_pad === 16'h0000 && captured_right_pad === 16'h0000)
        $display("  PASS 32-bit slots are zero padded");
    else begin
        $display("  FAIL slot padding: left 0x%04X right 0x%04X", captured_left_pad, captured_right_pad);
        errors++;
    end

    begin
        logic sdata_at_transition;
        logic sdata_at_msb;

        @(negedge lrclk);
        wait_bclk_rise();
        sdata_at_transition = sdata;
        wait_bclk_rise();
        sdata_at_msb = sdata;

        $display("TEST: LRCLK-to-data timing");
        if (sdata_at_msb === LEFT_VAL[15])
            $display("  PASS MSB of left appears one BCLK after LRCLK falls");
        else begin
            $display("  FAIL MSB timing: expected %b got %b", LEFT_VAL[15], sdata_at_msb);
            errors++;
        end
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

initial begin
    #50_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule

