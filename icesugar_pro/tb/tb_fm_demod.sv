`timescale 1ns/1ps

module tb_fm_demod;

localparam CLK_PERIOD = 40;

logic clk, rst;
logic signed [15:0] i_in, q_in;
logic in_valid;
logic signed [7:0] audio_out;
logic audio_valid;

fm_demod dut (
    .clk (clk),
    .rst (rst),
    .i_in (i_in),
    .q_in (q_in),
    .in_valid (in_valid),
    .audio_out (audio_out),
    .audio_valid (audio_valid)
);

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

integer errors = 0;

task automatic drive_sample(input logic signed [15:0] i_val,
                            input logic signed [15:0] q_val);
    begin
        @(posedge clk);
        i_in <= i_val;
        q_in <= q_val;
        in_valid <= 1'b1;
    end
endtask

initial begin
    $dumpfile("build/fm_demod.vcd");
    $dumpvars(0, tb_fm_demod);

    rst = 1'b1;
    i_in = '0;
    q_in = '0;
    in_valid = 1'b0;

    repeat (4) @(posedge clk);
    rst <= 1'b0;

    drive_sample(16'sd1000, 16'sd0);
    drive_sample(16'sd0, 16'sd1000);
    drive_sample(-16'sd1000, 16'sd0);
    drive_sample(16'sd0, -16'sd1000);

    @(posedge clk);
    in_valid <= 1'b0;

    repeat (6) @(posedge clk);

    if (audio_out === 8'sbx) begin
        $display("FAIL audio_out is X");
        errors++;
    end else begin
        $display("PASS audio_out is known");
    end

    if (audio_valid === 1'bx) begin
        $display("FAIL audio_valid is X");
        errors++;
    end else begin
        $display("PASS audio_valid is known");
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

initial begin
    #10_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule

