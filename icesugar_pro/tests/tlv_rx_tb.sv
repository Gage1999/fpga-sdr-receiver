// Testbench for the full TLV receive chain:
//   spi_frame_rx -> async_fifo (byte CDC) -> tlv_demux -> tlv_iq_sink
// Mirrors the USE_TLV=1 wiring in top.sv. Sends one TLV_IQ packet of N samples
// over SPI and checks that the reconstructed {I,Q} words (including a negative
// value, to exercise sign) match what was transmitted, in order.

`timescale 1ns/1ps

module tlv_rx_tb;

    logic CLK = 0;
    logic spi_clk = 0, spi_cs_n = 1, spi_mosi = 0;
    logic sys_rst = 1, spi_rst = 1;

    always #4 CLK = ~CLK;

    // ---- DUT chain (same as top.sv g_tlv) ----
    logic       fr_valid, fr_sof;
    logic [7:0] fr_byte;

    spi_frame_rx u_fr (
        .spi_clk(spi_clk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .byte_valid(fr_valid), .byte_sof(fr_sof), .byte_data(fr_byte)
    );

    logic [8:0] brd;
    logic       bemp, bful, bpop, bpop_d;

    async_fifo #(.WIDTH(9), .DEPTH(32)) u_bf (
        .wclk(spi_clk), .wrst(spi_rst), .wdata({fr_sof, fr_byte}),
        .wpush(fr_valid & ~bful & ~spi_rst), .wfull(bful),
        .rclk(CLK), .rrst(sys_rst), .rdata(brd), .rpop(bpop), .rempty(bemp)
    );

    assign bpop = ~bemp;
    always_ff @(posedge CLK or posedge sys_rst) begin
        if (sys_rst) bpop_d <= 1'b0;
        else         bpop_d <= bpop;
    end

    logic       pl_valid, pl_sop, pl_eop;
    logic [7:0] pl_byte, pl_type;
    /* verilator lint_off PINCONNECTEMPTY */
    tlv_demux u_dm (
        .clk(CLK), .rst(sys_rst),
        .in_valid(bpop_d), .in_sof(brd[8]), .in_byte(brd[7:0]),
        .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
        .pl_byte(pl_byte), .pl_type(pl_type),
        .iq_pkt_count(), .img_pkt_count(), .obj_pkt_count(),
        .unknown_count(), .short_count(), .stray_count(), .last_type()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic signed [15:0] oi, oq;
    logic               ov;

    tlv_iq_sink u_sink (
        .clk(CLK), .rst(sys_rst),
        .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
        .pl_byte(pl_byte), .pl_type(pl_type),
        .i_data(oi), .q_data(oq), .iq_word_valid(ov)
    );

    // ---- Capture reconstructed samples ----
    localparam int N = 5;
    logic signed [15:0] exp_i [0:N-1];
    logic signed [15:0] exp_q [0:N-1];
    logic signed [15:0] rx_i  [0:N-1];
    logic signed [15:0] rx_q  [0:N-1];
    int rn = 0;

    always_ff @(posedge CLK) begin
        if (ov && rn < N) begin
            rx_i[rn] <= oi;
            rx_q[rn] <= oq;
            rn       <= rn + 1;
        end
    end

    int errors = 0;

    task automatic spi_byte(input [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            spi_mosi = b[i];
            #20 spi_clk = 1;
            #20 spi_clk = 0;
        end
    endtask

    task automatic spi_sample(input signed [15:0] iv, input signed [15:0] qv);
        spi_byte(iv[15:8]);
        spi_byte(iv[7:0]);
        spi_byte(qv[15:8]);
        spi_byte(qv[7:0]);
    endtask

    initial begin
        // Expected samples (one negative I and one negative Q to test sign).
        exp_i[0] = 16'sd4660;   exp_q[0] = 16'sd22136;   // 0x1234 / 0x5678
        exp_i[1] = -16'sd100;   exp_q[1] = 16'sd5000;
        exp_i[2] = 16'sd32000;  exp_q[2] = -16'sd32000;
        exp_i[3] = 16'sd1;      exp_q[3] = -16'sd1;
        exp_i[4] = 16'sd0;      exp_q[4] = 16'sd12345;

        repeat (6) @(posedge CLK);
        sys_rst <= 1'b0; spi_rst <= 1'b0;
        repeat (4) @(posedge CLK);

        // One TLV_IQ packet: TYPE=0x00, LEN = N*4 bytes.
        spi_cs_n = 0; #20;
        spi_byte(8'h00);                 // TYPE = TLV_IQ
        spi_byte(8'((N*4) >> 8));         // LEN hi
        spi_byte(8'((N*4) & 8'hFF));      // LEN lo
        for (int k = 0; k < N; k++)
            spi_sample(exp_i[k], exp_q[k]);
        spi_cs_n = 1;

        // Let the CLK-domain chain drain and emit.
        repeat (300) @(posedge CLK);

        if (rn != N) begin
            errors = errors + 1;
            $display("FAIL: expected %0d samples, got %0d", N, rn);
        end
        for (int k = 0; k < N && k < rn; k++) begin
            if (rx_i[k] !== exp_i[k] || rx_q[k] !== exp_q[k]) begin
                errors = errors + 1;
                $display("FAIL sample %0d: got I=%0d Q=%0d, exp I=%0d Q=%0d",
                         k, rx_i[k], rx_q[k], exp_i[k], exp_q[k]);
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
