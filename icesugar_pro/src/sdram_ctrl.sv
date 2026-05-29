module sdram_ctrl #(
    parameter int TREF_PERIOD = 780,  // refresh interval in clk cycles (7.8 us). 780 @100 MHz
    parameter int RD_LAT      = 2     // read-capture latency (S_READ_CL count). 2 = TCAS.
                                      // Bump by 1 if read data is captured through an extra register.
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        req_valid,
    input  logic        req_wr,
    input  logic [24:0] req_addr,
    input  logic [9:0]  req_len,   // burst length in 16-bit words, up to a full 512-word page
    output logic        req_ready,

    input  logic [15:0] wr_data,
    input  logic        wr_valid,
    output logic        wr_ready,

    output logic [15:0] rd_data,
    output logic        rd_valid,

    output logic        done,

    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    output logic [15:0] sdram_dq_out,
    output logic        sdram_dq_oe,
    input  logic [15:0] sdram_dq_in,
    output logic [1:0]  sdram_dm
);

// IS42S16160B at 100 MHz
// CL=2, tRCD=2 cyc, tRP=2 cyc, tRFC=7 cyc
// Refresh every 780 cyc (64 ms / 8192 rows)
// Init: 20000 cyc power-on, PRECHARGE ALL, 8x AUTO-REFRESH, MODE REGISTER SET

localparam INIT_WAIT   = 20000;
localparam INIT_REF    = 8;
localparam TRCD        = 2;
localparam TCAS        = 2;
localparam TRP         = 2;
localparam TRFC        = 7;

// Mode register: CL=2, BL=Full Page, sequential, no write burst
// A[2:0]=111 (full page), A[3]=0 (sequential), A[6:4]=010 (CL=2), A[9:7]=000
// Full-page bursts cannot use auto-precharge; each burst is closed by an
// explicit PRECHARGE in S_PRECHARGE (close-row policy).
localparam [12:0] MODE_REG = 13'b000_0_00_010_0_111;

// {CS_n, RAS_n, CAS_n, WE_n}
localparam [3:0] CMD_NOP       = 4'b0111;
localparam [3:0] CMD_PRECHARGE = 4'b0010;
localparam [3:0] CMD_AUTOREF   = 4'b0001;
localparam [3:0] CMD_LMR       = 4'b0000;
localparam [3:0] CMD_ACTIVE    = 4'b0011;
localparam [3:0] CMD_READ      = 4'b0101;
localparam [3:0] CMD_WRITE     = 4'b0100;

typedef enum logic [3:0] {
    S_INIT_WAIT,
    S_INIT_PRECH,
    S_INIT_REF,
    S_INIT_MRS,
    S_IDLE,
    S_REFRESH,
    S_RCD,
    S_READ_CL,
    S_READ_DATA,
    S_WRITE_DATA,
    S_PRECHARGE,
    S_DONE
} state_t;

state_t state;

logic [14:0] timer;
logic [3:0]  ref_cnt;
logic [10:0] ref_timer;
logic [9:0]  burst_cnt;
logic [9:0]  req_len_r;
logic        req_wr_r;
logic [24:0] req_addr_r;
logic [3:0]  cl_cnt;

// Address decode from registered request address
// 25-bit byte addr: [24:23]=bank, [22:10]=row(13b), [9:1]=col(9b), [0]=ignored
wire [1:0]  ba_r  = req_addr_r[24:23];
wire [9:0]  col_r = {1'b0, req_addr_r[9:1]};

assign sdram_clk = clk;
assign sdram_dm  = 2'b00;

always_ff @(posedge clk) begin
    if (rst) begin
        state       <= S_INIT_WAIT;
        timer       <= 15'(INIT_WAIT - 1);
        ref_cnt     <= 4'(INIT_REF);
        ref_timer   <= 11'(TREF_PERIOD - 1);
        burst_cnt   <= 10'd0;
        req_len_r   <= 10'd0;
        req_wr_r    <= 1'b0;
        req_addr_r  <= 25'd0;
        cl_cnt      <= 4'd0;
        sdram_cke   <= 1'b1;
        sdram_cs_n  <= 1'b1;
        sdram_ras_n <= 1'b1;
        sdram_cas_n <= 1'b1;
        sdram_we_n  <= 1'b1;
        sdram_ba    <= 2'd0;
        sdram_a     <= 13'd0;
        sdram_dq_out <= 16'd0;
        sdram_dq_oe  <= 1'b0;
        rd_data     <= 16'd0;
        rd_valid    <= 1'b0;
        req_ready   <= 1'b0;
        wr_ready    <= 1'b0;
        done        <= 1'b0;
    end else begin
        // Per-cycle defaults
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
        sdram_dq_oe <= 1'b0;
        rd_valid    <= 1'b0;
        req_ready   <= 1'b0;
        wr_ready    <= 1'b0;
        done        <= 1'b0;

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
                    sdram_a  <= 13'b0010000000000; // A10=1 all banks
                    timer    <= 15'(TRP - 1);
                    state    <= S_INIT_REF;
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_INIT_REF: begin
                if (timer == 15'd0) begin
                    if (ref_cnt == 4'd0) begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_LMR;
                        sdram_ba <= 2'b00;
                        sdram_a  <= MODE_REG;
                        timer    <= 15'(TRFC - 1);
                        state    <= S_INIT_MRS;
                    end else begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREF;
                        ref_cnt <= ref_cnt - 4'd1;
                        timer   <= 15'(TRFC - 1);
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
                req_ready <= 1'b1;
                if (ref_timer == 11'd0) begin
                    req_ready <= 1'b0;
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_AUTOREF;
                    timer <= 15'(TRFC - 1);
                    state <= S_REFRESH;
                end else if (req_valid) begin
                    req_ready  <= 1'b0;
                    req_wr_r   <= req_wr;
                    req_len_r  <= req_len;
                    req_addr_r <= req_addr;
                    // ACTIVATE
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
                    sdram_ba <= req_addr[24:23];
                    sdram_a  <= req_addr[22:10];
                    timer    <= 15'(TRCD - 1);
                    state    <= S_RCD;
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
                    if (req_wr_r) begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                        sdram_ba <= ba_r;
                        sdram_a  <= {3'b000, col_r}; // A10=0: no auto-precharge (closed explicitly in S_PRECHARGE)
                        state    <= S_WRITE_DATA;
                        wr_ready <= 1'b1;
                    end else begin
                        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                        sdram_ba <= ba_r;
                        sdram_a  <= {3'b000, col_r}; // A10=0: no auto-precharge (closed explicitly in S_PRECHARGE)
                        cl_cnt   <= 4'(RD_LAT);   // read-capture latency (TCAS, +1 if captured through an extra reg)
                        state    <= S_READ_CL;
                    end
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_WRITE_DATA: begin
                wr_ready <= 1'b1;
                if (wr_valid) begin
                    sdram_dq_out <= wr_data;
                    sdram_dq_oe  <= 1'b1;
                    burst_cnt    <= burst_cnt + 10'd1;
                    if (burst_cnt == req_len_r - 10'd1) begin
                        wr_ready <= 1'b0;
                        timer    <= 15'(TRP + 2); // +1 over read path defers PRECHARGE one cycle for tWR
                        state    <= S_PRECHARGE;
                    end
                end
            end

            S_READ_CL: begin
                if (cl_cnt == 4'd0) begin
                    burst_cnt <= 10'd0;
                    state     <= S_READ_DATA;
                end else begin
                    cl_cnt <= cl_cnt - 4'd1;
                end
            end

            S_READ_DATA: begin
                rd_data   <= sdram_dq_in;
                rd_valid  <= 1'b1;
                burst_cnt <= burst_cnt + 10'd1;
                if (burst_cnt == req_len_r - 10'd1) begin
                    // keep rd_valid asserted for this final beat; it drops via the
                    // per-cycle default once we leave S_READ_DATA
                    timer    <= 15'(TRP + 1);
                    state    <= S_PRECHARGE;
                end
            end

            S_PRECHARGE: begin
                // Close the active row. Reads enter with timer=TRP+1 so PRECHARGE
                // fires immediately; writes enter with timer=TRP+2 so it is deferred
                // one extra cycle to satisfy tWR (write recovery).
                if (timer == 15'(TRP + 1)) begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_a <= 13'b0010000000000; // A10=1: precharge all banks
                end
                if (timer == 15'd0) begin
                    done  <= 1'b1;
                    state <= S_DONE;
                end else begin
                    timer <= timer - 15'd1;
                end
            end

            S_DONE: begin
                done  <= 1'b0;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
