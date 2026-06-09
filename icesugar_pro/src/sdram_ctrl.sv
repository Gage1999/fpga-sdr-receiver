module sdram_ctrl #(
    parameter int TREF_PERIOD = 780,
    parameter int RD_LAT = 2,
    parameter int BURST_MODE = 0,
    parameter int RD_GUARD = 0,
    parameter int WR_GUARD = 0
) (
    input logic clk,
    input logic rst,

    input logic req_valid,
    input logic req_wr,
    input logic [24:0] req_addr,
    input logic [9:0] req_len,
    output logic req_ready,

    input logic [15:0] wr_data,
    input logic wr_valid,
    output logic wr_ready,

    output logic [15:0] rd_data,
    output logic rd_valid,

    output logic done,

    output logic sdram_clk,
    output logic sdram_cke,
    output logic sdram_cs_n,
    output logic sdram_ras_n,
    output logic sdram_cas_n,
    output logic sdram_we_n,
    output logic [1:0] sdram_ba,
    output logic [12:0] sdram_a,
    output logic [15:0] sdram_dq_out,
    output logic sdram_dq_oe,
    input logic [15:0] sdram_dq_in,
    output logic [1:0] sdram_dm
);

localparam INIT_WAIT = 20000;
localparam INIT_REF = 8;
localparam TRCD = 2;
localparam TCAS = 2;
localparam TRP = 2;
localparam TRFC = 7;

localparam [12:0] MODE_REG = (BURST_MODE != 0) ? 13'b000_0_00_010_0_011
                                               : 13'b000_0_00_010_0_111;

localparam [3:0] CMD_NOP = 4'b0111;
localparam [3:0] CMD_PRECHARGE = 4'b0010;
localparam [3:0] CMD_AUTOREF = 4'b0001;
localparam [3:0] CMD_LMR = 4'b0000;
localparam [3:0] CMD_ACTIVE = 4'b0011;
localparam [3:0] CMD_READ = 4'b0101;
localparam [3:0] CMD_WRITE = 4'b0100;

typedef enum logic [3:0] {
    S_INIT_WAIT,
    S_INIT_PRECH,
    S_INIT_REF,
    S_INIT_MRS,
    S_IDLE,
    S_REFRESH,
    S_RCD,
    S_READ_CMD,
    S_READ_CL,
    S_READ_DATA,
    S_WRITE_CMD,
    S_WRITE_DATA,
    S_PRECHARGE,
    S_DONE
} state_t;

state_t state;

logic [14:0] timer;
logic [3:0] ref_cnt;
logic [10:0] ref_timer;
logic [9:0] burst_cnt;
logic [9:0] req_len_r;
logic req_wr_r;
logic [24:0] req_addr_r;
logic [3:0] cl_cnt;

logic [10:0] chunk_left;
logic [9:0] chunk_col;
logic [3:0] chunk_n;
wire [1:0] ba_r = req_addr_r[24:23];
wire [9:0] col_r = {1'b0, req_addr_r[9:1]};

assign sdram_clk = clk;
assign sdram_dm = 2'b00;
assign req_ready = (state == S_IDLE) && (ref_timer != 11'd0);

always_ff @(posedge clk) begin
    if (rst) begin
        state <= S_INIT_WAIT;
        timer <= 15'(INIT_WAIT - 1);
        ref_cnt <= 4'(INIT_REF);
        ref_timer <= 11'(TREF_PERIOD - 1);
        burst_cnt <= 10'd0;
        req_len_r <= 10'd0;
        req_wr_r <= 1'b0;
        req_addr_r <= 25'd0;
        cl_cnt <= 4'd0;
        chunk_left <= 11'd0;
        chunk_col <= 10'd0;
        chunk_n <= 4'd0;
        sdram_cke <= 1'b1;
        sdram_cs_n <= 1'b1;
        sdram_ras_n <= 1'b1;
        sdram_cas_n <= 1'b1;
        sdram_we_n <= 1'b1;
        sdram_ba <= 2'd0;
        sdram_a <= 13'd0;
        sdram_dq_out <= 16'd0;
        sdram_dq_oe <= 1'b0;
        rd_data <= 16'd0;
        rd_valid <= 1'b0;
        wr_ready <= 1'b0;
        done <= 1'b0;
    end else begin
        // Per-cycle defaults
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
        sdram_dq_oe <= 1'b0;
        rd_valid <= 1'b0;
        wr_ready <= 1'b0;
        done <= 1'b0;

        // Refresh countdown
        if (ref_timer == 11'd0)
            ref_timer <= 11'(TREF_PERIOD - 1);
        else
            ref_timer <= ref_timer - 11'd1;

        case (state)

            S_INIT_WAIT: begin
                sdram_cke <= 1'b1;
                if (timer == 15'd0) begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_ba <= 2'b00;
                    sdram_a <= 13'b0010000000000;
                    timer <= 15'(TRP - 1);
                    state <= S_INIT_REF;
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_INIT_REF: begin
                if (timer == 15'd0) begin
                    if (ref_cnt == 4'd0) begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_LMR;
                        sdram_ba <= 2'b00;
                        sdram_a <= MODE_REG;
                        timer <= 15'(TRFC - 1);
                        state <= S_INIT_MRS;
                    end else begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREF;
                        ref_cnt <= ref_cnt - 4'd1;
                        timer <= 15'(TRFC - 1);
                    end
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_INIT_MRS: begin
                if (timer == 15'd0)
                    state <= S_IDLE;
                else
                    timer <= timer - 15'd1;
            end

            S_IDLE: begin
                if (ref_timer == 11'd0) begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREF;
                    timer <= 15'(TRFC - 1);
                    state <= S_REFRESH;
                end else if (req_valid) begin
                    req_wr_r <= req_wr;
                    req_len_r <= req_len;
                    req_addr_r <= req_addr;
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
                    sdram_ba <= req_addr[24:23];
                    sdram_a <= req_addr[22:10];
                    timer <= 15'(TRCD - 1);
                    state <= S_RCD;
                end
            end

            S_REFRESH: begin
                if (timer == 15'd0)
                    state <= S_IDLE;
                else
                    timer <= timer - 15'd1;
            end

            S_RCD: begin
                if (timer == 15'd0) begin
                    burst_cnt <= 10'd0;
                    if (BURST_MODE != 0) begin
                        chunk_col <= col_r;
                        chunk_left <= {1'b0, req_len_r};
                        if (req_wr_r) state <= S_WRITE_CMD;
                        else          state <= S_READ_CMD;
                    end else if (req_wr_r) begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                        sdram_ba <= ba_r;
                        sdram_a <= {3'b000, col_r};
                        state <= S_WRITE_DATA;
                        wr_ready <= 1'b1;
                    end else begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                        sdram_ba <= ba_r;
                        sdram_a <= {3'b000, col_r};
                        cl_cnt <= 4'(RD_LAT);
                        state <= S_READ_CL;
                    end
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_READ_CMD: begin
                {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                sdram_ba <= ba_r;
                sdram_a <= {3'b000, chunk_col};
                chunk_n <= (chunk_left < 11'd8) ? chunk_left[3:0] : 4'd8;
                cl_cnt <= 4'(RD_LAT);
                burst_cnt <= 10'd0;
                state <= S_READ_CL;
            end

            S_WRITE_CMD: begin
                {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                sdram_ba <= ba_r;
                sdram_a <= {3'b000, chunk_col};
                chunk_n <= (chunk_left < 11'd8) ? chunk_left[3:0] : 4'd8;
                burst_cnt <= 10'd0;
                wr_ready <= 1'b1;
                state <= S_WRITE_DATA;
            end

            S_WRITE_DATA: begin
                wr_ready <= 1'b1;
                if (wr_valid) begin
                    sdram_dq_out <= wr_data;
                    sdram_dq_oe <= 1'b1;
                    burst_cnt <= burst_cnt + 10'd1;
                    if (BURST_MODE != 0) begin
                        if (burst_cnt == {6'd0, chunk_n} - 10'd1) begin
                            wr_ready <= 1'b0;
                            chunk_left <= chunk_left - {7'd0, chunk_n};
                            chunk_col <= chunk_col + 10'd8;
                            if (chunk_left <= {7'd0, chunk_n}) begin
                                timer <= 15'(TRP + 2 + WR_GUARD);
                                state <= S_PRECHARGE;
                            end else begin
                                state <= S_WRITE_CMD;
                            end
                        end
                    end else if (burst_cnt == req_len_r - 10'd1) begin
                        wr_ready <= 1'b0;
                        timer <= 15'(TRP + 2 + WR_GUARD);
                        state <= S_PRECHARGE;
                    end
                end
            end

            S_READ_CL: begin
                if (cl_cnt == 4'd0) begin
                    burst_cnt <= 10'd0;
                    state <= S_READ_DATA;
                end else begin
                    cl_cnt <= cl_cnt - 4'd1;
                end
            end

            S_READ_DATA: begin
                rd_data <= sdram_dq_in;
                rd_valid <= 1'b1;
                burst_cnt <= burst_cnt + 10'd1;
                if (BURST_MODE != 0) begin
                    if (burst_cnt == {6'd0, chunk_n} - 10'd1) begin
                        chunk_left <= chunk_left - {7'd0, chunk_n};
                        chunk_col <= chunk_col + 10'd8;
                        if (chunk_left <= {7'd0, chunk_n}) begin
                            timer <= 15'(TRP + 1 + RD_GUARD);
                            state <= S_PRECHARGE;
                        end else begin
                            state <= S_READ_CMD;
                        end
                    end
                end else if (burst_cnt == req_len_r - 10'd1) begin
                    timer <= 15'(TRP + 1 + RD_GUARD);
                    state <= S_PRECHARGE;
                end
            end

            S_PRECHARGE: begin
                if (timer == 15'(TRP + 1)) begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_a <= 13'b0010000000000;
                end
                if (timer == 15'd0) begin
                    done <= 1'b1;
                    state <= S_DONE;
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_DONE: begin
                done <= 1'b0;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
