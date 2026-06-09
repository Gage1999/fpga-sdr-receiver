// Closed-loop testbench for scan_out.sv + sdram_ctrl.sv + line_cache.sv

// A behavioral IS42S16160B read model is preloaded with a known framebuffer
// pattern. scan_out is triggered to prefetch several display lines; each fetched
// line is read back out of the line_cache and compared against the framebuffer.
// Test lines are chosen so their start columns force 2- and 3-segment splits.

`timescale 1ns/1ps

module scan_out_tb;

    localparam int LINE_WORDS = 800;

    logic clk = 0, rst;
    always #5 clk = ~clk;   // 100 MHz

    // scan_out <-> sdram_ctrl
    logic        req_valid, req_wr, req_ready, rd_valid, done;
    logic [24:0] req_addr;
    logic [9:0]  req_len;
    logic [15:0] rd_data;
    // unused write port of the controller
    logic [15:0] wr_data = 16'd0;
    logic        wr_valid = 1'b0, wr_ready;

    // scan_out <-> line_cache
    logic [1:0]  w_slot;
    logic [9:0]  w_col;
    logic [15:0] w_data;
    logic        w_en;
    logic        scan_busy;

    // pixel-domain stimulus
    logic [8:0]  px_line = 9'd0;
    logic        px_hblank = 1'b0;

    // SDRAM pins
    logic        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic [1:0]  sdram_ba, sdram_dm;
    logic [12:0] sdram_a;
    logic [15:0] sdram_dq_out, sdram_dq_in;
    logic        sdram_dq_oe;

    // line_cache read port (TB-driven, same clock for the check)
    logic [1:0]  r_slot;
    logic [9:0]  r_col;
    logic [15:0] r_data;

    // scan_out drives req_wr=0 implicitly (read only); tie it off
    assign req_wr = 1'b0;

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

    scan_out dut_scan (
        .clk(clk), .rst(rst),
        .px_line(px_line), .px_hblank(px_hblank), .wf_base_row(9'd0),
        .req_valid(req_valid), .req_addr(req_addr), .req_len(req_len),
        .req_ready(req_ready), .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
        .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
        .busy(scan_busy)
    );

    line_cache dut_cache (
        .wclk(clk), .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
        .rclk(clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data)
    );

    // Behavioral SDRAM read model (CL=2, full-page streaming). Bank 0 only.
    logic [15:0] sdram_mem [0:4*8192*512-1];
    logic [12:0] active_row [0:3];

    logic        rdp_v   [0:2];
    logic [1:0]  rdp_ba  [0:2];
    logic [12:0] rdp_row [0:2];
    logic [9:0]  rdp_col [0:2];
    int          rdp_cnt [0:2];

    wire [3:0] sdram_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};

    function automatic int flat_addr(input logic [1:0] ba, input logic [12:0] row, input int col);
        flat_addr = (ba * 8192 + row) * 512 + col;
    endfunction

    function automatic logic [15:0] fb_pattern(input int word_idx);
        fb_pattern = 16'(word_idx ^ 16'hBEEF);
    endfunction

    integer mi;
    initial begin
        for (mi = 0; mi < 3; mi++) begin
            rdp_v[mi]=0; rdp_ba[mi]=0; rdp_row[mi]=0; rdp_col[mi]=0; rdp_cnt[mi]=0;
        end
        for (mi = 0; mi < 4; mi++) active_row[mi]=0;
        // Preload framebuffer: bank-0 word W holds fb_pattern(W); contiguous, so
        // display line L word c lives at W = L*800 + c.
        for (mi = 0; mi < LINE_WORDS*480; mi++)
            sdram_mem[mi] = fb_pattern(mi);
    end

    always @(posedge clk) begin
        case (sdram_cmd)
            4'b0011: active_row[sdram_ba] <= sdram_a[12:0]; // ACTIVE
            default: ;
        endcase
    end

    // 3-stage read pipeline -> CL=2 latency
    always @(posedge clk) begin
        rdp_v[2]<=rdp_v[1]; rdp_ba[2]<=rdp_ba[1]; rdp_row[2]<=rdp_row[1]; rdp_col[2]<=rdp_col[1]; rdp_cnt[2]<=rdp_cnt[1];
        rdp_v[1]<=rdp_v[0]; rdp_ba[1]<=rdp_ba[0]; rdp_row[1]<=rdp_row[0]; rdp_col[1]<=rdp_col[0]; rdp_cnt[1]<=rdp_cnt[0];
        if (sdram_cmd == 4'b0101) begin // READ
            rdp_v[0]<=1'b1; rdp_ba[0]<=sdram_ba; rdp_row[0]<=active_row[sdram_ba]; rdp_col[0]<=sdram_a[9:0]; rdp_cnt[0]<=0;
        end else if (rdp_v[0]) begin
            rdp_cnt[0]<=rdp_cnt[0]+1;
        end
    end

    wire [22:0] rd_addr_w = flat_addr(rdp_ba[2], rdp_row[2], rdp_col[2] + rdp_cnt[2]);
    assign sdram_dq_in = rdp_v[2] ? sdram_mem[rd_addr_w] : 16'h0000;

    // Stimulus
    int errors = 0;

    // Fetch the line that will land as display line L (px_line = L - PREFETCH),
    // wait for the fetch to complete, then verify the cache slot.
    task automatic fetch_and_check(input int L);
        int slot, base, c;
        begin
            // px_line is stable for a whole line before its H-blank (as on real
            // hardware), so set it first and let the input pipeline settle.
            @(posedge clk);
            px_line <= 9'(L - 2);      // PREFETCH = 2
            repeat (6) @(posedge clk);
            px_hblank <= 1'b1;
            repeat (4) @(posedge clk);
            px_hblank <= 1'b0;

            // wait for the fetch to start and finish
            wait (scan_busy === 1'b1);
            wait (scan_busy === 1'b0);
            repeat (2) @(posedge clk);

            slot = L % 4;
            base = L * LINE_WORDS;
            for (c = 0; c < LINE_WORDS; c++) begin
                @(posedge clk);
                r_slot <= 2'(slot);
                r_col  <= 10'(c);
                @(posedge clk);
                @(posedge clk);
                if (r_data !== fb_pattern(base + c)) begin
                    if (errors < 12)
                        $display("FAIL line %0d col %0d (slot %0d): expected %04h got %04h",
                                 L, c, slot, fb_pattern(base + c), r_data);
                    errors = errors + 1;
                end
            end
            $display("line %0d checked (slot %0d, start col %0d)", L, slot, base % 512);
        end
    endtask

    initial begin
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        $display("Waiting for SDRAM init...");
        wait (req_ready === 1'b1);
        @(posedge clk);
        $display("Init done at %0t ns", $time);

        // Lines chosen for varied start columns / segment counts:
        // L=2 -> col 64 (2 seg), L=3 -> col 352 (3 seg), L=5 -> col 416 (3 seg),
        // L=4 -> col 128 (2 seg), L=10 -> col 320 (3 seg), L=17 -> col 288 (2 seg)
        fetch_and_check(2);
        fetch_and_check(3);
        fetch_and_check(4);
        fetch_and_check(5);
        fetch_and_check(10);
        fetch_and_check(17);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
