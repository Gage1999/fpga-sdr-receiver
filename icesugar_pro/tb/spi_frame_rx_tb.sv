// Testbench for spi_frame_rx.sv
// Drives MSB-first SPI bytes inside CS-framed windows and checks that each byte
// is deserialized correctly, that byte_sof marks only the first byte of a frame,
// and crucially that the LAST byte of a frame is captured on its own clock edge
// (CS deasserts immediately after, with no trailing clock).

`timescale 1ns/1ps

module spi_frame_rx_tb;

    logic spi_clk = 0;
    logic spi_cs_n = 1;
    logic spi_mosi = 0;

    logic       byte_valid, byte_sof;
    logic [7:0] byte_data;

    spi_frame_rx dut (
        .spi_clk(spi_clk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .byte_valid(byte_valid), .byte_sof(byte_sof), .byte_data(byte_data)
    );

    int errors = 0;

    // Capture every byte the DUT flags valid (combinational valid sampled at the
    // 8th-bit rising edge).
    logic [7:0] cap_data [0:63];
    logic       cap_sof  [0:63];
    int         cap_n = 0;

    always @(posedge spi_clk) begin
        if (byte_valid) begin
            cap_data[cap_n] = byte_data;
            cap_sof[cap_n]  = byte_sof;
            cap_n = cap_n + 1;
        end
    end

    // Shift one MSB-first byte; DUT samples on the rising edge.
    task automatic spi_byte(input [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            spi_mosi = b[i];
            #20 spi_clk = 1;
            #20 spi_clk = 0;
        end
    endtask

    task automatic check(input string name, input bit cond);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %s", name);
        end
    endtask

    initial begin
        #100;

        // ---- Frame 1: three bytes, CS deasserts right after the last bit ----
        spi_cs_n = 0; #20;
        spi_byte(8'hC3);
        spi_byte(8'h01);
        spi_byte(8'h08);
        spi_cs_n = 1; #40;     // no trailing clock before CS rises

        check("f1.count", cap_n == 3);
        check("f1.b0",    cap_data[0] == 8'hC3);
        check("f1.b1",    cap_data[1] == 8'h01);
        check("f1.b2",    cap_data[2] == 8'h08);   // last byte captured despite immediate CS
        check("f1.sof0",  cap_sof[0] == 1'b1);
        check("f1.sof1",  cap_sof[1] == 1'b0);
        check("f1.sof2",  cap_sof[2] == 1'b0);

        // ---- Frame 2: SOF must re-arm after CS went high ----
        cap_n = 0;
        spi_cs_n = 0; #20;
        spi_byte(8'hAA);
        spi_byte(8'h55);
        spi_cs_n = 1; #40;

        check("f2.count", cap_n == 2);
        check("f2.b0",    cap_data[0] == 8'hAA);
        check("f2.b1",    cap_data[1] == 8'h55);
        check("f2.sof0",  cap_sof[0] == 1'b1);   // first byte of the new frame
        check("f2.sof1",  cap_sof[1] == 1'b0);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
