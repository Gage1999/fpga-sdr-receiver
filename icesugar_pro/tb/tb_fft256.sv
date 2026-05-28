`timescale 1ns/1ps

module tb_fft256;

localparam CLK_PERIOD = 40;
localparam real PI = 3.14159265358979323846;

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
integer mags [0:255];

task automatic reset_dut;
    begin
        rst = 1'b1;
        i_in = '0;
        q_in = '0;
        in_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);
    end
endtask

task automatic send_sample(input logic signed [15:0] i_val,
                           input logic signed [15:0] q_val);
    begin
        i_in = i_val;
        q_in = q_val;
        in_valid = 1'b1;
        @(posedge clk);
    end
endtask

task automatic stop_input;
    begin
        i_in = '0;
        q_in = '0;
        in_valid = 1'b0;
        @(posedge clk);
    end
endtask

task automatic clear_mags;
    begin
        for (int n = 0; n < 256; n++)
            mags[n] = 0;
    end
endtask

task automatic collect_frame;
    integer count;
    integer wait_count;
    begin
        count = 0;
        wait_count = 0;

        while (count < 256 && wait_count < 30000) begin
            @(posedge clk);
            wait_count++;
            if (bin_valid) begin
                if (bin_index !== count[7:0]) begin
                    $display("FAIL bin index: expected %0d got %0d", count, bin_index);
                    errors++;
                end
                mags[bin_index] = bin_magnitude;
                count++;
            end
        end

        if (count != 256) begin
            $display("FAIL frame output: expected 256 bins got %0d", count);
            errors++;
        end
    end
endtask

task automatic send_dc_frame;
    begin
        for (int n = 0; n < 256; n++)
            send_sample(16'sd4096, 16'sd0);
        stop_input();
    end
endtask

task automatic send_tone_frame(input int tone_bin);
    real phase;
    integer i_val;
    integer q_val;
    begin
        for (int n = 0; n < 256; n++) begin
            phase = 2.0 * PI * tone_bin * n / 256.0;
            i_val = $rtoi(12000.0 * $cos(phase));
            q_val = $rtoi(12000.0 * $sin(phase));
            send_sample(i_val[15:0], q_val[15:0]);
        end
        stop_input();
    end
endtask

task automatic check_dc;
    integer max_other;
    begin
        max_other = 0;
        for (int n = 1; n < 256; n++) begin
            if (mags[n] > max_other)
                max_other = mags[n];
        end

        if (mags[0] == 0) begin
            $display("FAIL DC: bin 0 is zero");
            errors++;
        end else if (max_other > (mags[0] >> 2)) begin
            $display("FAIL DC: leakage too high, bin0=%0d max_other=%0d", mags[0], max_other);
            errors++;
        end else begin
            $display("PASS DC peak bin0=%0d max_other=%0d", mags[0], max_other);
        end
    end
endtask

task automatic check_tone(input int tone_bin);
    integer max_other;
    integer peak_bin;
    begin
        max_other = 0;
        peak_bin = 0;

        for (int n = 0; n < 256; n++) begin
            if (mags[n] > mags[peak_bin])
                peak_bin = n;
            if (n != tone_bin && mags[n] > max_other)
                max_other = mags[n];
        end

        if (peak_bin != tone_bin) begin
            $display("FAIL tone: expected peak bin %0d got %0d", tone_bin, peak_bin);
            errors++;
        end else if (max_other > (mags[tone_bin] >> 2)) begin
            $display("FAIL tone: leakage too high, peak=%0d max_other=%0d", mags[tone_bin], max_other);
            errors++;
        end else begin
            $display("PASS tone bin%0d=%0d max_other=%0d", tone_bin, mags[tone_bin], max_other);
        end
    end
endtask

initial begin
    $dumpfile("build/fft256.vcd");
    $dumpvars(0, tb_fft256);

    clear_mags();
    reset_dut();
    send_dc_frame();
    collect_frame();
    check_dc();

    clear_mags();
    reset_dut();
    send_tone_frame(32);
    collect_frame();
    check_tone(32);

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

initial begin
    #30_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule
