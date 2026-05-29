// Functional testbench for sdram_ctrl in BL=8 chunked mode (BURST_MODE=1).
// Verifies the new S_READ_CMD/S_WRITE_CMD chunk-walking path reads/writes the
// correct data, including single-row bursts that reach the page-boundary column
// (col 511). This is a FUNCTIONAL check against an ideal model — it proves the
// FSM addresses/streams correctly; the analog page-boundary margin is a hardware
// property and is measured on-chip by top_sdram_cal, not here.
//
// DUT inputs are driven non-blocking to settle in the NBA region (keeps iverilog
// and Verilator in agreement; see sdram_ctrl_tb.sv).

`timescale 1ns/1ps

module sdram_ctrl_bl_tb;

logic        clk = 0;
logic        rst;
always #5 clk = ~clk;   // 100 MHz

logic        req_valid, req_wr, req_ready;
logic [24:0] req_addr;
logic [9:0]  req_len;
logic [15:0] wr_data;
logic        wr_valid, wr_ready;
logic [15:0] rd_data;
logic        rd_valid, done;

logic        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
logic [1:0]  sdram_ba, sdram_dm;
logic [12:0] sdram_a;
logic [15:0] sdram_dq_out, sdram_dq_in;
logic        sdram_dq_oe;

sdram_ctrl #(.RD_LAT(2), .BURST_MODE(1)) dut (
    .clk(clk), .rst(rst),
    .req_valid(req_valid), .req_wr(req_wr), .req_addr(req_addr), .req_len(req_len), .req_ready(req_ready),
    .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
    .rd_data(rd_data), .rd_valid(rd_valid), .done(done),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
    .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_in(sdram_dq_in), .sdram_dm(sdram_dm)
);

// ---- Behavioral SDRAM model (CL=2). Write captured on dq_oe; each WRITE/READ
//      command resets its column pointer, so BL=8 chunks land correctly. ----
logic [15:0] sdram_mem [0:4*8192*512-1];
logic [12:0] active_row [0:3];
logic [1:0]  wr_ba; logic [9:0] wr_col; int wr_burst; logic wr_active;
logic        rdp_v [0:2]; logic [1:0] rdp_ba [0:2]; logic [12:0] rdp_row [0:2]; logic [9:0] rdp_col [0:2]; int rdp_cnt [0:2];

wire [3:0] sdram_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};
function automatic int flat_addr(input logic [1:0] ba, input logic [12:0] row, input int col);
    flat_addr = (ba * 8192 + row) * 512 + col;
endfunction
function automatic logic [15:0] pat(input int word_idx);
    pat = 16'((word_idx * 7 + 3) ^ 16'hC3A5);
endfunction

integer mi;
initial begin
    wr_active = 0; wr_ba = 0; wr_col = 0; wr_burst = 0;
    for (mi = 0; mi < 3; mi++) begin rdp_v[mi]=0; rdp_ba[mi]=0; rdp_row[mi]=0; rdp_col[mi]=0; rdp_cnt[mi]=0; end
    for (mi = 0; mi < 4; mi++) active_row[mi]=0;
end

always @(posedge clk) begin
    case (sdram_cmd)
        4'b0011: active_row[sdram_ba] <= sdram_a[12:0];       // ACTIVE
        4'b0100: begin wr_ba<=sdram_ba; wr_col<=sdram_a[9:0]; wr_burst<=0; wr_active<=1; end // WRITE
        default: ;
    endcase
    if (wr_active && sdram_dq_oe) begin
        sdram_mem[flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq_out;
        wr_burst <= wr_burst + 1;
    end
end

always @(posedge clk) begin
    rdp_v[2]<=rdp_v[1]; rdp_ba[2]<=rdp_ba[1]; rdp_row[2]<=rdp_row[1]; rdp_col[2]<=rdp_col[1]; rdp_cnt[2]<=rdp_cnt[1];
    rdp_v[1]<=rdp_v[0]; rdp_ba[1]<=rdp_ba[0]; rdp_row[1]<=rdp_row[0]; rdp_col[1]<=rdp_col[0]; rdp_cnt[1]<=rdp_cnt[0];
    if (sdram_cmd == 4'b0101) begin // READ
        rdp_v[0]<=1; rdp_ba[0]<=sdram_ba; rdp_row[0]<=active_row[sdram_ba]; rdp_col[0]<=sdram_a[9:0]; rdp_cnt[0]<=0;
    end else if (rdp_v[0]) rdp_cnt[0]<=rdp_cnt[0]+1;
end
wire [22:0] rd_addr_w = flat_addr(rdp_ba[2], rdp_row[2], rdp_col[2] + rdp_cnt[2]);
assign sdram_dq_in = rdp_v[2] ? sdram_mem[rd_addr_w] : 16'h0000;

// ---- Stimulus ----
int errors = 0;
int wi, ri;

// Hold req_valid until the controller accepts (it may service a refresh first).
task automatic issue_req(input [24:0] addr, input [9:0] len, input bit is_wr);
    @(posedge clk);
    req_valid <= 1; req_wr <= is_wr; req_addr <= addr; req_len <= len;
    forever begin
        @(posedge clk);
        if (req_valid && req_ready) begin req_valid <= 0; break; end
    end
endtask

task automatic do_write(input [24:0] addr, input [9:0] len);
    int wbase; wbase = addr >> 1;
    issue_req(addr, len, 1'b1);
    // Producer: hold wr_valid + current word; advance only on an accepted beat
    // (wr_ready && wr_valid). The controller drops wr_ready in the inter-chunk gap.
    wr_valid <= 1'b1; wr_data <= pat(wbase + 0);
    wi = 0;
    while (wi < len) begin
        @(posedge clk);
        if (wr_ready && wr_valid) begin
            wi = wi + 1;
            if (wi < len) wr_data <= pat(wbase + wi);
        end
    end
    wr_valid <= 0;
    wait(done === 1'b1); @(posedge clk);
endtask

task automatic do_read_check(input [24:0] addr, input [9:0] len, input string name);
    int rbase; int local_err; logic [15:0] exp;
    rbase = addr >> 1; local_err = 0;
    issue_req(addr, len, 1'b0);
    ri = 0;
    while (ri < len) begin
        @(posedge clk);
        if (rd_valid) begin
            exp = pat(rbase + ri);
            if (rd_data !== exp) begin
                local_err = local_err + 1;
                if (local_err <= 5) $display("  %s MISMATCH word %0d: exp %04h got %04h", name, ri, exp, rd_data);
            end
            ri = ri + 1;
        end
    end
    wait(done === 1'b1); @(posedge clk);
    if (local_err == 0) $display("PASS %s (%0d words)", name, len);
    else                $display("FAIL %s: %0d/%0d mismatches", name, local_err, len);
    errors = errors + local_err;
endtask

initial begin
    req_valid=0; req_wr=0; req_addr=0; req_len=0; wr_data=0; wr_valid=0;
    rst = 1; repeat(4) @(posedge clk); rst = 0;
    wait(req_ready === 1'b1); @(posedge clk);

    // Scenario 1: small burst, mid-page (sanity).
    do_write(25'(20 << 1), 10'd20);
    do_read_check(25'(20 << 1), 10'd20, "len20@col20");

    // Scenario 2: full 512-word row (col 0..511) — reaches the page boundary.
    do_write(25'd0, 10'd512);
    do_read_check(25'd0, 10'd512, "len512@col0");

    // Scenario 3: 256 words starting at col 256 (cols 256..511) — ends exactly at boundary.
    do_write(25'(256 << 1), 10'd256);
    do_read_check(25'(256 << 1), 10'd256, "len256@col256");

    // Scenario 4: a length not a multiple of 8 (last chunk is short).
    do_write(25'((4*1024) + (100 << 1)), 10'd77);   // row 4, col 100
    do_read_check(25'((4*1024) + (100 << 1)), 10'd77, "len77@col100row4");

    repeat(10) @(posedge clk);
    if (errors == 0) $display("ALL BL=8 TESTS PASSED");
    else             $display("BL=8 TESTS FAILED: %0d total mismatches", errors);
    $finish;
end

initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule
