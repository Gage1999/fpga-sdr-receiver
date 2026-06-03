`timescale 1ns/1ps

// tb_rds_group — drive four group-0A segments carrying the PS name "RADIO 99"
// and confirm the decoder assembles the name and recovers PI/PTY.

module tb_rds_group;

    localparam CLK_PERIOD = 40;

    logic clk = 0, rst;
    logic        group_valid;
    logic [15:0] pi_word, blk_b, blk_c, blk_d;
    logic        c_is_cprime;
    logic [3:0]  block_ok;

    logic [15:0]  pi;
    logic [4:0]   pty;
    logic         tp;
    logic [7:0]   ps_mask;
    logic         ps_valid;
    logic [63:0]  ps_name;
    logic [191:0] rds_line;

    rds_group dut (
        .clk(clk), .rst(rst),
        .group_valid(group_valid),
        .pi_word(pi_word), .blk_b(blk_b), .blk_c(blk_c), .blk_d(blk_d),
        .c_is_cprime(c_is_cprime), .block_ok(block_ok),
        .pi(pi), .pty(pty), .tp(tp),
        .ps_mask(ps_mask), .ps_valid(ps_valid), .ps_name(ps_name), .rds_line(rds_line)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    localparam logic [15:0] PI = 16'h3A5C;

    // Drive one group for a single cycle.
    task automatic send_group(input logic [15:0] a, b, c, d, input logic [3:0] ok);
        begin
            @(posedge clk);
            pi_word     <= a;
            blk_b       <= b;
            blk_c       <= c;
            blk_d       <= d;
            block_ok    <= ok;
            c_is_cprime <= 1'b0;
            group_valid <= 1'b1;
            @(posedge clk);
            group_valid <= 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    int errors = 0;

    // Block B for group 0A: type=0000, ver A, TP=1, PTY=5, TA=0, MS=1, DI=0, addr.
    function automatic logic [15:0] mk_b(input logic [1:0] addr);
        mk_b = 16'h04A8 | {14'd0, addr};
    endfunction

    // "RADIO 99"
    localparam logic [63:0] EXP_PS = {8'h39, 8'h39, 8'h20, 8'h4F, 8'h49, 8'h44, 8'h41, 8'h52};
    // ps_name[7:0]='R',[15:8]='A',... so char0 is LSB. Build little-endian above:
    // bits[7:0]=R(0x52) ... bits[63:56]=9(0x39).

    initial begin
        $dumpfile("build/rds_group.vcd");
        $dumpvars(0, tb_rds_group);

        rst = 1'b1;
        group_valid = 1'b0;
        pi_word = '0; blk_b = '0; blk_c = '0; blk_d = '0; block_ok = '0; c_is_cprime = 0;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // addr0: 'R','A'  addr1: 'D','I'  addr2: 'O',' '  addr3: '9','9'
        send_group(PI, mk_b(2'd0), 16'hABCD, 16'h5241, 4'b1111);
        send_group(PI, mk_b(2'd1), 16'hABCD, 16'h4449, 4'b1111);
        send_group(PI, mk_b(2'd2), 16'hABCD, 16'h4F20, 4'b1111);
        send_group(PI, mk_b(2'd3), 16'hABCD, 16'h3939, 4'b1111);

        repeat (4) @(posedge clk);

        if (pi !== PI)            begin $display("FAIL pi=%h exp %h", pi, PI); errors++; end
        if (pty !== 5'd5)         begin $display("FAIL pty=%0d exp 5", pty);   errors++; end
        if (tp  !== 1'b1)         begin $display("FAIL tp=%b exp 1", tp);      errors++; end
        if (!ps_valid)            begin $display("FAIL ps_valid not set");     errors++; end
        if (ps_mask !== 8'hFF)    begin $display("FAIL ps_mask=%b", ps_mask);  errors++; end
        if (ps_name !== EXP_PS)   begin $display("FAIL ps_name=%h exp %h", ps_name, EXP_PS); errors++; end
        if (rds_line[63:0] !== EXP_PS) begin $display("FAIL rds_line low=%h", rds_line[63:0]); errors++; end
        // columns 8..23 must be spaces
        if (rds_line[71:64] !== 8'h20) begin $display("FAIL rds_line col8 not space"); errors++; end

        // Print the recovered PS name as text.
        $write("PS name: \"");
        for (int k = 0; k < 8; k++) $write("%c", ps_name[8*k +: 8]);
        $display("\"");

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
