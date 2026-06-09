// Testbench for sdram_arb.sv

`timescale 1ns/1ps

module mock_ctrl (
    input  logic        clk, rst,
    input  logic        req_valid, req_wr,
    input  logic [24:0] req_addr,
    input  logic [9:0]  req_len,
    output logic        req_ready,
    input  logic [15:0] wr_data,
    input  logic        wr_valid,
    output logic        wr_ready,
    output logic [15:0] rd_data,
    output logic        rd_valid,
    output logic        done
);
    typedef enum logic [1:0] { I, RD, WR, FIN } s_t;
    s_t state;
    logic [9:0]  cnt, len_r;
    logic [24:0] addr_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= I; req_ready <= 1'b1; rd_valid <= 1'b0; wr_ready <= 1'b0; done <= 1'b0; cnt <= 10'd0;
        end else begin
            done <= 1'b0; rd_valid <= 1'b0; wr_ready <= 1'b0; req_ready <= 1'b0;
            case (state)
                I: begin
                    req_ready <= 1'b1;
                    if (req_valid && req_ready) begin
                        addr_r <= req_addr; len_r <= req_len; cnt <= 10'd0;
                        req_ready <= 1'b0;
                        if (req_wr) state <= WR; else state <= RD;
                    end
                end
                RD: begin
                    rd_valid <= 1'b1;
                    rd_data  <= 16'(addr_r[15:0] + cnt);
                    cnt      <= cnt + 10'd1;
                    if (cnt == len_r - 10'd1) state <= FIN;
                end
                WR: begin
                    wr_ready <= 1'b1;
                    if (wr_valid) begin
                        cnt <= cnt + 10'd1;
                        if (cnt == len_r - 10'd1) begin wr_ready <= 1'b0; state <= FIN; end
                    end
                end
                FIN: begin done <= 1'b1; state <= I; end
                default: state <= I;
            endcase
        end
    end
endmodule

module sdram_arb_tb;
    localparam int N = 3;

    logic clk = 0, rst;
    always #5 clk = ~clk;

    logic [N-1:0]    c_req_valid, c_req_wr, c_req_ready;
    logic [N*25-1:0] c_req_addr;
    logic [N*10-1:0] c_req_len;
    logic [N*16-1:0] c_wr_data, c_rd_data;
    logic [N-1:0]    c_wr_valid, c_wr_ready, c_rd_valid, c_done;

    logic        m_req_valid, m_req_wr, m_req_ready, m_wr_valid, m_wr_ready, m_rd_valid, m_done;
    logic [24:0] m_req_addr;
    logic [9:0]  m_req_len;
    logic [15:0] m_wr_data, m_rd_data;
    logic        gnt_valid;
    logic [1:0]  gnt;

    sdram_arb #(.N(N)) dut (
        .clk(clk), .rst(rst),
        .c_req_valid(c_req_valid), .c_req_wr(c_req_wr), .c_req_addr(c_req_addr), .c_req_len(c_req_len),
        .c_req_ready(c_req_ready), .c_wr_data(c_wr_data), .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready),
        .c_rd_data(c_rd_data), .c_rd_valid(c_rd_valid), .c_done(c_done),
        .m_req_valid(m_req_valid), .m_req_wr(m_req_wr), .m_req_addr(m_req_addr), .m_req_len(m_req_len),
        .m_req_ready(m_req_ready), .m_wr_data(m_wr_data), .m_wr_valid(m_wr_valid), .m_wr_ready(m_wr_ready),
        .m_rd_data(m_rd_data), .m_rd_valid(m_rd_valid), .m_done(m_done),
        .gnt_valid(gnt_valid), .gnt(gnt)
    );

    mock_ctrl mc (
        .clk(clk), .rst(rst),
        .req_valid(m_req_valid), .req_wr(m_req_wr), .req_addr(m_req_addr), .req_len(m_req_len),
        .req_ready(m_req_ready), .wr_data(m_wr_data), .wr_valid(m_wr_valid), .wr_ready(m_wr_ready),
        .rd_data(m_rd_data), .rd_valid(m_rd_valid), .done(m_done)
    );

    int errors = 0;
    int order [$];
    logic [15:0] first_beat [N];
    logic        got_first  [N];

    function automatic logic [15:0] expect_addr(input int i);
        expect_addr = 16'(((i + 1) * 25'h1000) & 25'hFFFF);
    endfunction

    // Mutual exclusion + per-client capture
    always @(posedge clk) begin
        if (!rst) begin
            int active;
            active = 0;
            for (int i = 0; i < N; i++)
                if (c_req_ready[i] || c_rd_valid[i] || c_wr_ready[i]) active++;
            if (active > 1) begin
                $display("FAIL: %0d clients hold the bus simultaneously at %0t", active, $time);
                errors = errors + 1;
            end
            for (int i = 0; i < N; i++) begin
                if (c_rd_valid[i] && !got_first[i]) begin
                    first_beat[i] = c_rd_data[i*16 +: 16];
                    got_first[i]  = 1'b1;
                end
                if (c_done[i]) order.push_back(i);
            end
        end
    end

    initial begin
        c_req_valid = '0; c_req_wr = '0; c_req_addr = '0; c_req_len = '0;
        c_wr_data = '0; c_wr_valid = '0;
        for (int i = 0; i < N; i++) got_first[i] = 1'b0;

        rst = 1; repeat(4) @(posedge clk); rst = 0;
        @(posedge clk);

        // All three request reads at once, distinct addresses, len=4.
        for (int i = 0; i < N; i++) begin
            c_req_addr[i*25 +: 25] <= 25'((i+1) * 25'h1000);
            c_req_len [i*10 +: 10] <= 10'd4;
            c_req_wr  [i]          <= 1'b0;
            c_req_valid[i]         <= 1'b1;
        end

        // Drop each client's req_valid once it has completed
        fork
            begin : dropper
                int finished;
                finished = 0;
                while (finished < N) begin
                    @(posedge clk);
                    for (int i = 0; i < N; i++)
                        if (c_done[i]) begin c_req_valid[i] <= 1'b0; finished++; end
                end
            end
        join

        repeat (6) @(posedge clk);

        // checks.
        if (order.size() != N) begin
            $display("FAIL: %0d transactions completed, expected %0d", order.size(), N);
            errors = errors + 1;
        end else begin
            for (int k = 0; k < N; k++)
                if (order[k] != k) begin
                    $display("FAIL: service order[%0d] = %0d, expected %0d", k, order[k], k);
                    errors = errors + 1;
                end
        end
        for (int i = 0; i < N; i++)
            if (!got_first[i] || first_beat[i] !== expect_addr(i)) begin
                $display("FAIL: client %0d first beat = %04h (got=%0b), expected %04h",
                         i, first_beat[i], got_first[i], expect_addr(i));
                errors = errors + 1;
            end

        if (errors == 0) $display("ALL TESTS PASSED (order: %0d %0d %0d)", order[0], order[1], order[2]);
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
