`timescale 1ns/1ps

// tb_rds_sync - feed synthesized RDS groups (with valid checkwords) bit-by-bit
// and confirm the synchronizer locks and emits every group with the correct
// information words and block_ok == 4'b1111.

module tb_rds_sync;

    localparam CLK_PERIOD = 40;

    logic clk = 0, rst;
    logic bit_in, bit_valid;
    logic        group_valid;
    logic [15:0] pi_word, blk_b, blk_c, blk_d;
    logic        c_is_cprime;
    logic [3:0]  block_ok;
    logic        synced;

    rds_sync dut (
        .clk(clk), .rst(rst),
        .bit_in(bit_in), .bit_valid(bit_valid),
        .group_valid(group_valid),
        .pi_word(pi_word), .blk_b(blk_b), .blk_c(blk_c), .blk_d(blk_d),
        .c_is_cprime(c_is_cprime), .block_ok(block_ok), .synced(synced)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // RDS checkword generator (must match rds_sync.rds_crc).
    localparam logic [9:0] POLY   = 10'h1B9;
    localparam logic [9:0] OFF_A  = 10'h0FC;
    localparam logic [9:0] OFF_B  = 10'h198;
    localparam logic [9:0] OFF_C  = 10'h168;
    localparam logic [9:0] OFF_D  = 10'h1B4;

    function automatic logic [9:0] crc10(input logic [15:0] info);
        logic [9:0] s; logic fb; int i;
        begin
            s = 10'd0;
            for (i = 15; i >= 0; i--) begin
                fb = s[9] ^ info[i];
                s  = {s[8:0], 1'b0};
                if (fb) s = s ^ POLY;
            end
            crc10 = s;
        end
    endfunction

    // Test group contents (group version 0A). Values are arbitrary but fixed.
    localparam logic [15:0] PI = 16'h3A5C;
    localparam logic [15:0] BB = 16'h0408;
    localparam logic [15:0] CC = 16'hCDCD;
    localparam logic [15:0] DD = 16'h4142;

    // 26-bit block = {info16, crc(info)^offset}.
    function automatic logic [25:0] mk_block(input logic [15:0] info, input logic [9:0] off);
        mk_block = {info, crc10(info) ^ off};
    endfunction

    // Bit stream buffer.
    localparam int NBITS = 30 + 6*104;   // zero preamble + 6 groups
    logic [0:NBITS-1] stream;
    int               sp;

    task automatic push_block(input logic [25:0] blk);
        int b;
        begin
            for (b = 25; b >= 0; b--) begin   // MSB first
                stream[sp] = blk[b];
                sp++;
            end
        end
    endtask

    int errors = 0;
    int groups_seen = 0;

    // Check every emitted group.
    always @(posedge clk) begin
        if (!rst && group_valid) begin
            groups_seen++;
            if (pi_word !== PI)        begin $display("FAIL group %0d PI=%h exp %h",  groups_seen, pi_word, PI); errors++; end
            if (blk_b   !== BB)        begin $display("FAIL group %0d B=%h exp %h",   groups_seen, blk_b, BB);   errors++; end
            if (blk_c   !== CC)        begin $display("FAIL group %0d C=%h exp %h",   groups_seen, blk_c, CC);   errors++; end
            if (blk_d   !== DD)        begin $display("FAIL group %0d D=%h exp %h",   groups_seen, blk_d, DD);   errors++; end
            if (block_ok !== 4'b1111)  begin $display("FAIL group %0d block_ok=%b",   groups_seen, block_ok);   errors++; end
        end
    end

    int i;
    initial begin
        $dumpfile("build/rds_sync.vcd");
        $dumpvars(0, tb_rds_sync);

        rst = 1'b1;
        bit_in = 1'b0;
        bit_valid = 1'b0;

        // Build the bit stream: zero preamble then 6 identical 0A groups.
        sp = 0;
        for (i = 0; i < 30; i++) begin stream[sp] = 1'b0; sp++; end
        for (i = 0; i < 6; i++) begin
            push_block(mk_block(PI, OFF_A));
            push_block(mk_block(BB, OFF_B));
            push_block(mk_block(CC, OFF_C));
            push_block(mk_block(DD, OFF_D));
        end

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        for (i = 0; i < NBITS; i++) begin
            @(posedge clk);
            bit_in    <= stream[i];
            bit_valid <= 1'b1;
        end
        @(posedge clk);
        bit_valid <= 1'b0;

        repeat (10) @(posedge clk);

        if (!synced) begin $display("FAIL not synced at end"); errors++; end
        if (groups_seen < 4) begin $display("FAIL only %0d groups emitted (want >=4)", groups_seen); errors++; end

        if (errors == 0)
            $display("ALL TESTS PASSED (%0d groups decoded)", groups_seen);
        else
            $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
