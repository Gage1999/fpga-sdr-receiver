`timescale 1ns/1ps

module tb_fft256;

localparam CLK_PERIOD = 40;

logic clk, rst;
logic signed [15:0] i_in, q_in;
logic in_valid;
logic [7:0] bin_magnitude;
logic [7:0] bin_index;
logic bin_valid;

fft256 dut (
    .clk (clk),
    .rst (rst),
    .i_in (i_in),
    .q_in (q_in),
    .in_valid (in_valid),
    .bin_magnitude (bin_magnitude),
    .bin_index (bin_index),
    .bin_valid (bin_valid)
);

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

integer errors = 0;
integer valid_count = 0;
integer dc_count = 0;

task automatic send_sample(input logic signed [15:0] i_val,
                           input logic signed [15:0] q_val);
    begin
        i_in = i_val;
        q_in = q_val;
        in_valid = 1'b1;
        @(posedge clk);
    end
endtask

initial begin
    $dumpfile("build/fft256.vcd");
    $dumpvars(0, tb_fft256);

    rst = 1'b1;
    i_in = '0;
    q_in = '0;
    in_valid = 1'b0;
    dc_count = 0;

    repeat (4) @(posedge clk);
    rst <= 1'b0;

    for (int n = 0; n < 512; n++) begin
        send_sample(16'sd4096, 16'sd0);
    end

    i_in = '0;
    q_in = '0;
    in_valid = 1'b0;
    @(posedge clk);

    repeat (24000) begin
        @(posedge clk);
        if (bin_valid) begin
            valid_count++;
            if (bin_index == 8'd0 && bin_magnitude != 8'd0)
                dc_count++;
            if (bin_index != ((valid_count - 1) & 8'hff)) begin
                $display("FAIL bin index: expected %0d got %0d", (valid_count - 1) & 8'hff, bin_index);
                errors++;
            end
        end
    end

    if (valid_count != 512) begin
        $display("FAIL valid_count: expected 512 got %0d", valid_count);
        errors++;
    end else begin
        $display("PASS emitted 512 bins");
    end

    if (dc_count != 2) begin
        $display("FAIL DC bins: expected 2 got %0d", dc_count);
        errors++;
    end else begin
        $display("PASS DC bins are nonzero");
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule

