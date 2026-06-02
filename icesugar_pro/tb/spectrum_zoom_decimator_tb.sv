`timescale 1ns/1ps

module spectrum_zoom_decimator_tb;
    logic clk = 1'b0;
    logic rst;
    logic signed [15:0] in_i;
    logic signed [15:0] in_q;
    logic in_valid;
    logic [15:0] span_hz_log2;
    logic signed [15:0] out_i;
    logic signed [15:0] out_q;
    logic out_valid;
    logic [2:0] decim_log2;
    integer errors = 0;

    always #20 clk = ~clk;

    spectrum_zoom_decimator dut (
        .clk(clk),
        .rst(rst),
        .in_i(in_i),
        .in_q(in_q),
        .in_valid(in_valid),
        .span_hz_log2(span_hz_log2),
        .out_i(out_i),
        .out_q(out_q),
        .out_valid(out_valid),
        .decim_log2(decim_log2)
    );

    task automatic reset_dut;
        begin
            rst = 1'b1;
            in_i = '0;
            in_q = '0;
            in_valid = 1'b0;
            span_hz_log2 = 16'd18;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic send_sample(input logic signed [15:0] si,
                               input logic signed [15:0] sq,
                               input logic expect_valid,
                               input logic signed [15:0] expect_i,
                               input logic signed [15:0] expect_q);
        begin
            @(negedge clk);
            in_i = si;
            in_q = sq;
            in_valid = 1'b1;
            @(posedge clk);
            #1;
            if (out_valid !== expect_valid) begin
                $display("FAIL valid: expected %0d got %0d", expect_valid, out_valid);
                errors++;
            end
            if (expect_valid && (out_i !== expect_i || out_q !== expect_q)) begin
                $display("FAIL sample: expected (%0d,%0d) got (%0d,%0d)",
                         expect_i, expect_q, out_i, out_q);
                errors++;
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    initial begin
        reset_dut();

        span_hz_log2 = 16'd18;
        repeat (2) @(posedge clk);
        if (decim_log2 !== 3'd0) begin
            $display("FAIL span18 decim_log2=%0d", decim_log2);
            errors++;
        end
        send_sample(16'sd1234, -16'sd567, 1'b1, 16'sd1234, -16'sd567);

        span_hz_log2 = 16'd16;
        repeat (2) @(posedge clk);
        if (decim_log2 !== 3'd2) begin
            $display("FAIL span16 decim_log2=%0d", decim_log2);
            errors++;
        end
        send_sample(16'sd10,  -16'sd10,  1'b0, 16'sd0, 16'sd0);
        send_sample(16'sd20,  -16'sd20,  1'b0, 16'sd0, 16'sd0);
        send_sample(16'sd30,  -16'sd30,  1'b0, 16'sd0, 16'sd0);
        send_sample(16'sd40,  -16'sd40,  1'b1, 16'sd25, -16'sd25);

        span_hz_log2 = 16'd13;
        repeat (2) @(posedge clk);
        if (decim_log2 !== 3'd5) begin
            $display("FAIL span13 decim_log2=%0d", decim_log2);
            errors++;
        end

        if (errors == 0)
            $display("PASS spectrum_zoom_decimator");
        else
            $display("FAILED spectrum_zoom_decimator: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
