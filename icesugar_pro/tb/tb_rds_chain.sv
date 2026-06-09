`timescale 1ns/1ps

// tb_rds_chain - full RDS receive chain end to end.

module tb_rds_chain;

    localparam real PI_C = 3.14159265358979323846;
    localparam real FS   = 260417.0;
    localparam real FP   = 19000.0;
    localparam real SPB  = FS / 1187.5;

    localparam int  NG    = 14;            // RDS groups transmitted
    localparam int  NBITS = NG * 104;
    localparam int  NSAMP = 320000;

    localparam CLK_PERIOD = 40;

    logic clk = 0, rst;
    logic signed [15:0] mpx_in;
    logic               mpx_valid;

    // demod -> sync
    logic demod_bit, demod_bit_valid, pll_locked;
    // sync -> group
    logic        group_valid;
    logic [15:0] pi_word, blk_b, blk_c, blk_d;
    logic        c_is_cprime;
    logic [3:0]  block_ok;
    logic        synced;
    // group outputs
    logic [15:0]  pi;
    logic [4:0]   pty;
    logic         tp;
    logic [7:0]   ps_mask;
    logic         ps_valid;
    logic [63:0]  ps_name;
    logic [191:0] rds_line;

    rds_demod u_demod (
        .clk(clk), .rst(rst), .mpx_in(mpx_in), .mpx_valid(mpx_valid),
        .bit_out(demod_bit), .bit_valid(demod_bit_valid), .pll_locked(pll_locked)
    );
    rds_sync u_sync (
        .clk(clk), .rst(rst), .bit_in(demod_bit), .bit_valid(demod_bit_valid),
        .group_valid(group_valid), .pi_word(pi_word), .blk_b(blk_b), .blk_c(blk_c),
        .blk_d(blk_d), .c_is_cprime(c_is_cprime), .block_ok(block_ok), .synced(synced)
    );
    rds_group u_group (
        .clk(clk), .rst(rst), .group_valid(group_valid),
        .pi_word(pi_word), .blk_b(blk_b), .blk_c(blk_c), .blk_d(blk_d),
        .c_is_cprime(c_is_cprime), .block_ok(block_ok),
        .pi(pi), .pty(pty), .tp(tp), .ps_mask(ps_mask),
        .ps_valid(ps_valid), .ps_name(ps_name), .rds_line(rds_line)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // RDS framing.
    localparam logic [9:0] POLY  = 10'h1B9;
    localparam logic [9:0] OFF_A = 10'h0FC, OFF_B = 10'h198, OFF_C = 10'h168, OFF_D = 10'h1B4;
    localparam logic [15:0] PI_CODE = 16'h3A5C;

    function automatic logic [9:0] crc10(input logic [15:0] info);
        logic [9:0] s; logic fb; int i;
        begin s = 0; for (i = 15; i >= 0; i--) begin fb = s[9]^info[i]; s = {s[8:0],1'b0}; if (fb) s = s^POLY; end crc10 = s; end
    endfunction
    function automatic logic [25:0] mk_block(input logic [15:0] info, input logic [9:0] off);
        mk_block = {info, crc10(info) ^ off};
    endfunction
    function automatic logic [15:0] mk_b(input logic [1:0] addr);  // group 0A, TP=1, PTY=5
        mk_b = 16'h04A8 | {14'd0, addr};
    endfunction

    // PS "RADIO 99" segments by address.
    function automatic logic [15:0] ps_seg(input logic [1:0] addr);
        case (addr)
            2'd0: ps_seg = 16'h5241;  // 'R','A'
            2'd1: ps_seg = 16'h4449;  // 'D','I'
            2'd2: ps_seg = 16'h4F20;  // 'O',' '
            default: ps_seg = 16'h3939; // '9','9'
        endcase
    endfunction
    localparam logic [63:0] EXP_PS = {8'h39,8'h39,8'h20,8'h4F,8'h49,8'h44,8'h41,8'h52};

    bit rds_bits [0:NBITS-1];   // payload bits, MSB-first
    bit tx_t     [0:NBITS-1];   // differentially encoded
    int sp;

    task automatic push_block(input logic [25:0] blk);
        int b; begin for (b = 25; b >= 0; b--) begin rds_bits[sp] = blk[b]; sp++; end end
    endtask

    function automatic real mpx_sample(input int n);
        real theta_p, pos, frac, t; int k, half, sym; real bp, pilot, rds, audio, stereo;
        begin
            theta_p = 2.0*PI_C*FP*n/FS;
            t = n/FS;
            pos = n/SPB; k = $rtoi(pos); if (k > NBITS-1) k = NBITS-1;
            frac = pos - k; half = (frac >= 0.5) ? 1 : 0;
            sym = tx_t[k] ? 1 : -1; bp = sym * (half==0 ? 1.0 : -1.0);
            pilot  = 6000.0*$sin(theta_p);
            rds    = 3500.0*bp*$cos(3.0*theta_p);
            audio  = 8000.0*(0.6*$sin(2.0*PI_C*1500.0*t) + 0.4*$sin(2.0*PI_C*6000.0*t));
            stereo = 4000.0*$sin(2.0*PI_C*900.0*t)*$sin(2.0*theta_p);
            mpx_sample = pilot + rds + audio + stereo;
        end
    endfunction

    int i, n, errors = 0;

    initial begin
        $dumpfile("build/rds_chain.vcd");
        $dumpvars(0, tb_rds_chain);

        // Build the RDS bitstream: NG repeating 0A groups, PS segment = group%4.
        sp = 0;
        for (i = 0; i < NG; i++) begin
            push_block(mk_block(PI_CODE,           OFF_A));
            push_block(mk_block(mk_b(i[1:0]),      OFF_B));
            push_block(mk_block(16'hE0CD,          OFF_C));
            push_block(mk_block(ps_seg(i[1:0]),    OFF_D));
        end
        // Differential encoding for biphase transmission.
        tx_t[0] = rds_bits[0];
        for (i = 1; i < NBITS; i++) tx_t[i] = tx_t[i-1] ^ rds_bits[i];

        rst = 1'b1; mpx_in = '0; mpx_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst <= 1'b0; @(posedge clk);

        for (n = 0; n < NSAMP; n++) begin
            @(posedge clk);
            mpx_in    <= $rtoi(mpx_sample(n));
            mpx_valid <= 1'b1;
        end
        @(posedge clk); mpx_valid <= 1'b0;
        repeat (20) @(posedge clk);

        $display("pll_locked=%b synced=%b pi=%h pty=%0d ps_valid=%b ps_mask=%b",
                 pll_locked, synced, pi, pty, ps_valid, ps_mask);
        $write("PS name: \""); for (i = 0; i < 8; i++) $write("%c", ps_name[8*i +: 8]); $display("\"");

        if (!synced)              begin $display("FAIL not synced");           errors++; end
        if (!ps_valid)            begin $display("FAIL ps_valid not set");     errors++; end
        if (pi !== PI_CODE)       begin $display("FAIL pi=%h exp %h", pi, PI_CODE); errors++; end
        if (pty !== 5'd5)         begin $display("FAIL pty=%0d exp 5", pty);   errors++; end
        if (ps_name !== EXP_PS)   begin $display("FAIL ps_name=%h exp %h", ps_name, EXP_PS); errors++; end
        if (rds_line[63:0] !== EXP_PS) begin $display("FAIL rds_line=%h", rds_line[63:0]); errors++; end

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
