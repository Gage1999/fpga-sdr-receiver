// Testbench for line_cache.sv

`timescale 1ns/1ps

module line_cache_tb;

    logic        wclk = 0, rclk = 0;
    logic [1:0]  w_slot, r_slot;
    logic [9:0]  w_col,  r_col;
    logic [15:0] w_data, r_data;
    logic        w_en;

    line_cache dut (
        .wclk (wclk), .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
        .rclk (rclk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data)
    );

    // Independent clocks: write 100 MHz, read ~37 MHz (intentionally unrelated)
    always #5    wclk = ~wclk;
    always #13.5 rclk = ~rclk;

    // Reference model
    function automatic logic [15:0] pat(input int slot, input int col);
        pat = 16'(((slot + 1) * 16'h1111) ^ (col * 16'h0007) ^ 16'h5A5A);
    endfunction

    int errors = 0;

    initial begin
        w_en = 0; w_slot = 0; w_col = 0; w_data = 0;

        // Fill every slot/column on the write clock.
        for (int s = 0; s < 4; s++) begin
            for (int c = 0; c < 800; c++) begin
                @(posedge wclk);
                w_slot <= 2'(s);
                w_col  <= 10'(c);
                w_data <= pat(s, c);
                w_en   <= 1'b1;
            end
        end
        @(posedge wclk);
        w_en <= 1'b0;

        // Let the last write land
        repeat (4) @(posedge wclk);

        // Read back on the read clock, verify.
        for (int s = 0; s < 4; s++) begin
            for (int c = 0; c < 800; c++) begin
                @(posedge rclk);
                r_slot <= 2'(s);
                r_col  <= 10'(c);
                @(posedge rclk);     // address registered, data out next edge
                @(posedge rclk);
                if (r_data !== pat(s, c)) begin
                    if (errors < 10)
                        $display("FAIL slot %0d col %0d: expected %04h got %04h",
                                 s, c, pat(s, c), r_data);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
