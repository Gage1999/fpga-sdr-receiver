module sdram_arb #(
    parameter int N = 3
) (
    input logic clk,
    input logic rst,

    // Client side
    input logic [N-1:0] c_req_valid,
    input logic [N-1:0] c_req_wr,
    input logic [N*25-1:0] c_req_addr,
    input logic [N*10-1:0] c_req_len,
    output logic [N-1:0] c_req_ready,
    input logic [N*16-1:0] c_wr_data,
    input logic [N-1:0] c_wr_valid,
    output logic [N-1:0] c_wr_ready,
    output logic [N*16-1:0] c_rd_data,
    output logic [N-1:0] c_rd_valid,
    output logic [N-1:0] c_done,

    // Controller side
    output logic m_req_valid,
    output logic m_req_wr,
    output logic [24:0] m_req_addr,
    output logic [9:0] m_req_len,
    input logic m_req_ready,
    output logic [15:0] m_wr_data,
    output logic m_wr_valid,
    input logic m_wr_ready,
    input logic [15:0] m_rd_data,
    input logic m_rd_valid,
    input logic m_done,

    output logic gnt_valid,
    output logic [1:0] gnt
);

    logic pick_valid;
    logic [1:0] pick;
    always_comb begin
        pick_valid = 1'b0;
        pick = 2'd0;
        for (int i = N-1; i >= 0; i--)
            if (c_req_valid[i]) begin
                pick = 2'(i);
                pick_valid = 1'b1;
            end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            gnt_valid <= 1'b0;
            gnt <= 2'd0;
        end else if (!gnt_valid) begin
            if (pick_valid) begin
                gnt <= pick;
                gnt_valid <= 1'b1;
            end
        end else if (m_done) begin
            gnt_valid <= 1'b0;
        end
    end

    always_comb begin
        m_req_valid = 1'b0;
        m_req_wr = 1'b0;
        m_req_addr = 25'd0;
        m_req_len = 10'd0;
        m_wr_data = 16'd0;
        m_wr_valid = 1'b0;
        c_req_ready = '0;
        c_wr_ready = '0;
        c_rd_valid = '0;
        c_done = '0;
        for (int i = 0; i < N; i++)
            c_rd_data[i*16 +: 16] = m_rd_data;
        if (gnt_valid) begin
            m_req_valid = c_req_valid[gnt];
            m_req_wr = c_req_wr[gnt];
            m_req_addr = c_req_addr[gnt*25 +: 25];
            m_req_len = c_req_len[gnt*10 +: 10];
            m_wr_data = c_wr_data[gnt*16 +: 16];
            m_wr_valid = c_wr_valid[gnt];
            c_req_ready[gnt] = m_req_ready;
            c_wr_ready[gnt] = m_wr_ready;
            c_rd_valid[gnt] = m_rd_valid;
            c_done[gnt] = m_done;
        end
    end

endmodule
