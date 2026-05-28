// Testbench for sdram_ctrl.sv
// Writes 8 words to bank 0 row 0 col 0, reads them back, verifies values.

`timescale 1ns/1ps

module sdram_ctrl_tb;

logic        clk = 0;
logic        rst;

logic        req_valid;
logic        req_wr;
logic [24:0] req_addr;
logic [9:0]  req_len;
logic        req_ready;

logic [15:0] wr_data;
logic        wr_valid;
logic        wr_ready;

logic [15:0] rd_data;
logic        rd_valid;
logic        done;

logic        sdram_clk;
logic        sdram_cke;
logic        sdram_cs_n;
logic        sdram_ras_n;
logic        sdram_cas_n;
logic        sdram_we_n;
logic [1:0]  sdram_ba;
logic [12:0] sdram_a;
logic [15:0] sdram_dq_out;
logic        sdram_dq_oe;
logic [15:0] sdram_dq_in;
logic [1:0]  sdram_dm;

sdram_ctrl dut (
    .clk        (clk),        .rst       (rst),
    .req_valid  (req_valid),  .req_wr    (req_wr),
    .req_addr   (req_addr),   .req_len   (req_len),
    .req_ready  (req_ready),
    .wr_data    (wr_data),    .wr_valid  (wr_valid),
    .wr_ready   (wr_ready),
    .rd_data    (rd_data),    .rd_valid  (rd_valid),
    .done       (done),
    .sdram_clk  (sdram_clk),  .sdram_cke (sdram_cke),
    .sdram_cs_n (sdram_cs_n), .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),.sdram_we_n(sdram_we_n),
    .sdram_ba   (sdram_ba),   .sdram_a   (sdram_a),
    .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe),
    .sdram_dq_in(sdram_dq_in),   .sdram_dm  (sdram_dm)
);

// 100 MHz
always #5 clk = ~clk;

// -----------------------------------------------------------------------
// Behavioral SDRAM model
// IS42S16160B: 4 banks x 8192 rows x 512 cols x 16-bit
// Write: data captured each cycle sdram_dq_oe=1 (behavioral, no strict CWL check)
// Read:  data appears CL=2 cycles after CMD_READ
// -----------------------------------------------------------------------
logic [15:0] sdram_mem [0:4*8192*512-1];

// Active row per bank
logic [12:0] active_row [0:3];

// Write tracking
logic [1:0]  wr_ba;
logic [9:0]  wr_col;
integer          wr_burst;
logic        wr_active;

// Read pipeline: CL=2 requires 3 stages (cmd at stage0, valid data at stage2 two cycles later)
logic        rdp_v [0:2];
logic [1:0]  rdp_ba [0:2];
logic [12:0] rdp_row [0:2];
logic [9:0]  rdp_col [0:2];
integer          rdp_cnt [0:2];

wire [3:0] sdram_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};

// Flat address helper
function automatic integer flat_addr(input logic [1:0] ba, input logic [12:0] row, input integer col);
    flat_addr = (ba * 8192 + row) * 512 + col;
endfunction

// Initialize memory
integer mi;
initial begin
    for (mi = 0; mi < 4*8192*512; mi++)
        sdram_mem[mi] = 16'h0000;
    wr_active = 1'b0;
    wr_ba     = 2'd0;
    wr_col    = 10'd0;
    wr_burst  = 0;
    for (mi = 0; mi < 3; mi++) begin
        rdp_v[mi]   = 1'b0;
        rdp_ba[mi]  = 2'd0;
        rdp_row[mi] = 13'd0;
        rdp_col[mi] = 10'd0;
        rdp_cnt[mi] = 0;
    end
    for (mi = 0; mi < 4; mi++)
        active_row[mi] = 13'd0;
end

// Command and write data capture
always @(posedge clk) begin
    case (sdram_cmd)
        4'b0011: // ACTIVE
            active_row[sdram_ba] <= sdram_a[12:0];
        4'b0100: begin // WRITE
            wr_ba     <= sdram_ba;
            wr_col    <= sdram_a[9:0];
            wr_burst  <= 0;
            wr_active <= 1'b1;
        end
        4'b0010: rdp_v[0] <= 1'b0; // PRECHARGE terminates read burst
        4'b0101: // READ handled below
            ;
        default: ;
    endcase

    // Capture write data
    if (wr_active && sdram_dq_oe) begin
        $display("MODEL WR: mem[%0d] <= %04h at %0t ns", flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst), sdram_dq_out, $time);
        sdram_mem[flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq_out;
        wr_burst <= wr_burst + 1;
    end
end

// Read pipeline: 3-stage shift register gives CL=2
// stage0 set on CMD_READ and incremented each cycle thereafter
// stage2 has valid data 2 cycles after CMD_READ
always @(posedge clk) begin
    // Stage 2 <- stage 1
    rdp_v[2]   <= rdp_v[1];
    rdp_ba[2]  <= rdp_ba[1];
    rdp_row[2] <= rdp_row[1];
    rdp_col[2] <= rdp_col[1];
    rdp_cnt[2] <= rdp_cnt[1];

    // Stage 1 <- stage 0
    rdp_v[1]   <= rdp_v[0];
    rdp_ba[1]  <= rdp_ba[0];
    rdp_row[1] <= rdp_row[0];
    rdp_col[1] <= rdp_col[0];
    rdp_cnt[1] <= rdp_cnt[0];

    // Stage 0 <- new command or increment
    if (sdram_cmd == 4'b0101) begin // READ
        rdp_v[0]   <= 1'b1;
        rdp_ba[0]  <= sdram_ba;
        rdp_row[0] <= active_row[sdram_ba];
        rdp_col[0] <= sdram_a[9:0];
        rdp_cnt[0] <= 0;
    end else if (rdp_v[0]) begin
        rdp_cnt[0] <= rdp_cnt[0] + 1;
    end else begin
        rdp_v[0] <= 1'b0;
    end
end

// Drive sdram_dq_in from stage2 (appears 2 cycles after CMD_READ = CL=2)
wire [22:0] rd_addr_w = flat_addr(rdp_ba[2], rdp_row[2], rdp_col[2] + rdp_cnt[2]);
assign sdram_dq_in = rdp_v[2] ? sdram_mem[rd_addr_w] : 16'hzzzz;

// Trace read output
always @(posedge clk) begin
    if (rdp_v[2])
        $display("MODEL RD: mem[%0d]=%04h (cnt=%0d) at %0t ns", rd_addr_w, sdram_mem[rd_addr_w], rdp_cnt[2], $time);
end

// -----------------------------------------------------------------------
// Stimulus
// -----------------------------------------------------------------------
localparam [15:0] PAT0 = 16'hA5C3;
localparam [15:0] PAT1 = 16'h1234;
localparam [15:0] PAT2 = 16'hDEAD;
localparam [15:0] PAT3 = 16'hBEEF;
localparam [15:0] PAT4 = 16'h0001;
localparam [15:0] PAT5 = 16'hFFFE;
localparam [15:0] PAT6 = 16'h5A5A;
localparam [15:0] PAT7 = 16'hC3C3;

logic [15:0] wr_pattern [0:7];
logic [15:0] rd_capture [0:7];
integer rd_idx, errors;

initial begin
    wr_pattern[0] = PAT0; wr_pattern[1] = PAT1;
    wr_pattern[2] = PAT2; wr_pattern[3] = PAT3;
    wr_pattern[4] = PAT4; wr_pattern[5] = PAT5;
    wr_pattern[6] = PAT6; wr_pattern[7] = PAT7;

    errors    = 0;
    rd_idx    = 0;
    req_valid <= 0; req_wr <= 0; req_addr <= 0; req_len <= 0;
    wr_data   <= 0; wr_valid <= 0;

    rst <= 1;
    repeat(4) @(posedge clk);
    rst <= 0;

    $display("Waiting for SDRAM init...");
    wait(req_ready === 1'b1);
    @(posedge clk);
    $display("Init done at time %0t ns", $time);

    // ---- WRITE ----
    req_valid <= 1'b1;
    req_wr    <= 1'b1;
    req_addr  <= 25'h000000;
    req_len   <= 10'd8;

    begin : wr_loop
        integer wi = 0;
        while (wi < 8) begin
            @(posedge clk);
            if (wr_ready) begin
                wr_data  <= wr_pattern[wi];
                wr_valid <= 1'b1;
                wi = wi + 1;
            end else begin
                wr_valid <= 1'b0;
            end
        end
        @(posedge clk);
        wr_valid  <= 1'b0;
        req_valid <= 1'b0;
    end

    wait(done === 1'b1);
    @(posedge clk);
    $display("Write done at %0t ns", $time);

    // ---- READ ----
    req_valid <= 1'b1;
    req_wr    <= 1'b0;
    req_addr  <= 25'h000000;
    req_len   <= 10'd8;

    begin : rd_loop
        while (rd_idx < 8) begin
            @(posedge clk);
            if (rd_valid) begin
                rd_capture[rd_idx] = rd_data;
                rd_idx = rd_idx + 1;
            end
        end
    end

    wait(done === 1'b1);
    req_valid <= 1'b0;
    @(posedge clk);
    $display("Read done at %0t ns", $time);

    // Verify
    for (integer i = 0; i < 8; i++) begin
        if (rd_capture[i] !== wr_pattern[i]) begin
            $display("FAIL word[%0d]: expected %04h got %04h", i, wr_pattern[i], rd_capture[i]);
            errors = errors + 1;
        end
    end

    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d errors", errors);

    $finish;
end

// Watchdog
initial begin
    #5000000;
    $display("TIMEOUT");
    $finish;
end

endmodule
