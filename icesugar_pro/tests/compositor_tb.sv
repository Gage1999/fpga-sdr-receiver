// Closed-loop testbench for compositor.sv + sdram_ctrl.sv
//
// Feeds two rows of magnitudes; the compositor maps them to RGB565 and writes
// them into the framebuffer (line 0 then line 1) through sdram_ctrl. The
// behavioral SDRAM model captures the writes; we then read its memory back and
// confirm each pixel landed at the correct contiguous-framebuffer address with
// the right palette value. Row 0 -> 2-segment write (start col 0); row 1 ->
// 3-segment write (start col 288).

`timescale 1ns/1ps

module compositor_tb;

    localparam int ROW_WORDS = 800;

    logic clk = 0, rst;
    always #5 clk = ~clk;

    logic [7:0]  mag_in = 8'd0;
    logic        mag_valid = 1'b0;
    logic [8:0]  wf_base_row;
    logic        comp_busy;

    logic        req_valid, req_wr, req_ready, wr_valid, wr_ready, done;
    logic [24:0] req_addr;
    logic [9:0]  req_len;
    logic [15:0] wr_data;
    // controller read port unused
    logic [15:0] rd_data;
    logic        rd_valid;

    logic        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic [1:0]  sdram_ba, sdram_dm;
    logic [12:0] sdram_a;
    logic [15:0] sdram_dq_out, sdram_dq_in;
    logic        sdram_dq_oe;

    compositor #(.ROW_WORDS(ROW_WORDS)) dut_comp (
        .clk(clk), .rst(rst),
        .mag_in(mag_in), .mag_valid(mag_valid), .wf_base_row(wf_base_row),
        .req_valid(req_valid), .req_wr(req_wr), .req_addr(req_addr), .req_len(req_len),
        .req_ready(req_ready), .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .done(done), .busy(comp_busy)
    );

    sdram_ctrl dut_ctrl (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_wr(req_wr), .req_addr(req_addr), .req_len(req_len),
        .req_ready(req_ready),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_in(sdram_dq_in),
        .sdram_dm(sdram_dm)
    );

    // ---- Behavioral SDRAM write model (bank 0) ----
    logic [15:0] sdram_mem [0:4*8192*512-1];
    logic [12:0] active_row [0:3];
    logic [1:0]  wr_ba;
    logic [9:0]  wr_col;
    int          wr_burst;
    logic        wr_active;

    wire [3:0] sdram_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};

    function automatic int flat_addr(input logic [1:0] ba, input logic [12:0] row, input int col);
        flat_addr = (ba * 8192 + row) * 512 + col;
    endfunction

    integer mi;
    initial begin
        wr_active = 0; wr_ba = 0; wr_col = 0; wr_burst = 0;
        for (mi = 0; mi < 4; mi++) active_row[mi] = 0;
        for (mi = 0; mi < ROW_WORDS*4; mi++) sdram_mem[mi] = 16'hFFFF; // sentinel
    end

    always @(posedge clk) begin
        case (sdram_cmd)
            4'b0011: active_row[sdram_ba] <= sdram_a[12:0];          // ACTIVE
            4'b0100: begin wr_ba <= sdram_ba; wr_col <= sdram_a[9:0]; // WRITE
                           wr_burst <= 0; wr_active <= 1'b1; end
            default: ;
        endcase
        if (wr_active && sdram_dq_oe) begin
            sdram_mem[flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq_out;
            wr_burst <= wr_burst + 1;
        end
    end
    assign sdram_dq_in = 16'h0000;

    // ---- Reference ----
    function automatic logic [7:0]  mag_of (input int row, input int c); mag_of  = 8'((c*3 + row*7) & 8'hFF); endfunction
    function automatic logic [15:0] pal_of (input logic [7:0] m); pal_of = {m[7:3], m[7:2], m[7:3]}; endfunction

    int errors = 0;

    task automatic feed_row(input int row);
        int c;
        begin
            for (c = 0; c < ROW_WORDS; c++) begin
                @(posedge clk);
                mag_in    <= mag_of(row, c);
                mag_valid <= 1'b1;
            end
            @(posedge clk);
            mag_valid <= 1'b0;
            // wait for the write to finish
            wait (comp_busy === 1'b0);
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic check_row(input int line, input int row);
        int c; logic [15:0] got, exp;
        begin
            for (c = 0; c < ROW_WORDS; c++) begin
                got = sdram_mem[line*ROW_WORDS + c];
                exp = pal_of(mag_of(row, c));
                if (got !== exp) begin
                    if (errors < 12)
                        $display("FAIL line %0d col %0d (word %0d): expected %04h got %04h",
                                 line, c, line*ROW_WORDS+c, exp, got);
                    errors = errors + 1;
                end
            end
            $display("line %0d verified (start col %0d)", line, (line*ROW_WORDS) % 512);
        end
    endtask

    initial begin
        rst = 1; repeat(4) @(posedge clk); rst = 0;
        $display("Waiting for SDRAM init...");
        wait (req_ready === 1'b1);
        @(posedge clk);
        $display("Init done at %0t ns", $time);

        feed_row(0);   // -> line 0 (2 segments)
        feed_row(1);   // -> line 1 (3 segments, start col 288)

        check_row(0, 0);
        check_row(1, 1);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end

endmodule
