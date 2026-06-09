// Testbench for audio_fifo.sv - regression for the `full`-always-true bug that
// kept the FIFO empty (silence). Checks it actually fills, drains, FWFT head is
// correct, full asserts only at DEPTH, and skip/repeat (rpop_n 0/2) behave.

`timescale 1ns/1ps

module audio_fifo_tb;

    localparam int DEPTH = 1024;

    logic clk = 0, rst = 1;
    logic [15:0] wdata;
    logic        wpush, full;
    logic [15:0] rdata;
    logic [1:0]  rpop_n;
    logic        empty;
    logic [$clog2(DEPTH):0] count;

    audio_fifo #(.WIDTH(16), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst),
        .wdata(wdata), .wpush(wpush), .full(full),
        .rdata(rdata), .rpop_n(rpop_n), .empty(empty), .count(count)
    );

    always #5 clk = ~clk;
    int errors = 0;

    task automatic check(input string name, input bit cond);
        if (!cond) begin errors++; $display("FAIL: %s", name); end
    endtask

    initial begin
        wpush = 0; wdata = 0; rpop_n = 0;
        repeat (3) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        check("empty.init", empty);
        check("notfull.init", !full);

        // Push 10 values 100..109.
        for (int i = 0; i < 10; i++) begin
            @(posedge clk); wpush <= 1; wdata <= 16'(100 + i);
        end
        @(posedge clk); wpush <= 0;
        @(posedge clk);

        check("filled", count == 10);          // the bug made this 0 forever
        check("notempty", !empty);
        check("notfull.10", !full);
        check("head.100", rdata == 16'd100);   // FWFT head

        // Pop 3 (advance 1 each).
        for (int i = 0; i < 3; i++) begin
            @(posedge clk); rpop_n <= 2'd1;
            @(posedge clk); rpop_n <= 2'd0;
        end
        @(posedge clk);
        check("count.7", count == 7);
        check("head.103", rdata == 16'd103);

        // Skip-one (rpop_n=2) drops a sample: head should jump 103 -> 105.
        @(posedge clk); rpop_n <= 2'd2;
        @(posedge clk); rpop_n <= 2'd0;
        @(posedge clk);
        check("count.5", count == 5);
        check("head.105", rdata == 16'd105);

        // Repeat (rpop_n=0) holds the head.
        @(posedge clk); rpop_n <= 2'd0;
        @(posedge clk);
        check("head.held", rdata == 16'd105 && count == 5);

        // Overfill: push 1100 -> should saturate at full, count == DEPTH.
        for (int i = 0; i < 1100; i++) begin
            @(posedge clk); wpush <= 1; wdata <= 16'(i);
        end
        @(posedge clk); wpush <= 0;
        @(posedge clk);
        check("full.atdepth", full);
        check("count.depth", count == DEPTH);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #1000000; $display("TIMEOUT"); $finish; end

endmodule
