// Testbench for the SDRAM scan-out pipeline.
// - Writes a test pattern to a behavioral SDRAM model.
// - Simulates LCD scan timing to drive the scan_out module.
// - Verifies that the scan_out module correctly fetches lines into the line_cache.
// - Verifies that the data read from the line_cache matches the original pattern.

`timescale 1ns/1ps

module sdram_display_tb;

// -----------------------------------------------------------------------
// Clocks and Reset
// -----------------------------------------------------------------------
logic clk_25mhz = 0;
always #20 clk_25mhz = ~clk_25mhz; // 25 MHz base clock

// PLL simulation
logic clk_sdram; // 100 MHz
logic clk_pix;   // 30 MHz
logic rst;
logic pll_locked = 1; // Assume locked

`ifdef SIMULATION
assign clk_sdram  = clk_25mhz; // In sim, run all clocks at same speed for simplicity
assign clk_pix    = clk_25mhz;
`else
// Placeholder for real hardware PLL
`endif

// -----------------------------------------------------------------------
// Behavioral SDRAM Model (from sdram_ctrl_tb)
// -----------------------------------------------------------------------
logic [15:0] sdram_mem [0:4*8192*512-1];
logic [12:0] active_row [0:3];
logic [1:0]  wr_ba;
logic [9:0]  wr_col;
integer      wr_burst;
logic        wr_active;
logic        rdp_v [0:2];
logic [1:0]  rdp_ba [0:2];
logic [12:0] rdp_row [0:2];
logic [9:0]  rdp_col [0:2];
integer      rdp_cnt [0:2];

// DUT Outputs
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
logic [1:0]  sdram_dm;
// DUT Inputs
logic [15:0] sdram_dq_in;

wire [3:0] sdram_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};

function automatic integer flat_addr(input logic [1:0] ba, input logic [12:0] row, input integer col);
    flat_addr = (ba * 8192 + row) * 512 + col;
endfunction

initial begin
    integer mi;
    for (mi = 0; mi < 4*8192*512; mi++) sdram_mem[mi] = 16'h0000;
    wr_active = 1'b0;
end

always @(posedge clk_sdram) begin
    case (sdram_cmd)
        4'b0011: active_row[sdram_ba] <= sdram_a[12:0];
        4'b0100: begin wr_ba <= sdram_ba; wr_col <= sdram_a[9:0]; wr_burst <= 0; wr_active <= 1'b1; end
        4'b0010: rdp_v[0] <= 1'b0; // PRECHARGE terminates read burst
    endcase
    if (wr_active && sdram_dq_oe) begin
        sdram_mem[flat_addr(wr_ba, active_row[wr_ba], wr_col + wr_burst)] <= sdram_dq_out;
        wr_burst <= wr_burst + 1;
    end
end

always @(posedge clk_sdram) begin
    rdp_v[2] <= rdp_v[1]; rdp_ba[2] <= rdp_ba[1]; rdp_row[2] <= rdp_row[1]; rdp_col[2] <= rdp_col[1]; rdp_cnt[2] <= rdp_cnt[1];
    rdp_v[1] <= rdp_v[0]; rdp_ba[1] <= rdp_ba[0]; rdp_row[1] <= rdp_row[0]; rdp_col[1] <= rdp_col[0]; rdp_cnt[1] <= rdp_cnt[0];
    if (sdram_cmd == 4'b0101) begin
        rdp_v[0] <= 1'b1; rdp_ba[0] <= sdram_ba; rdp_row[0] <= active_row[sdram_ba]; rdp_col[0] <= sdram_a[9:0]; rdp_cnt[0] <= 0;
    end else if (rdp_v[0]) begin
        rdp_cnt[0] <= rdp_cnt[0] + 1;
    end else begin
        rdp_v[0] <= 1'b0;
    end
end
assign sdram_dq_in = rdp_v[2] ? sdram_mem[flat_addr(rdp_ba[2], rdp_row[2], rdp_col[2] + rdp_cnt[2])] : 16'hzzzz;

// -----------------------------------------------------------------------
// DUTs
// -----------------------------------------------------------------------
logic ctrl_req_valid, scan_req_valid;
logic ctrl_req_ready, scan_req_ready;
logic [24:0] ctrl_req_addr, scan_req_addr;
logic [9:0] ctrl_req_len, scan_req_len;
logic ctrl_rd_valid, scan_rd_valid;
logic [15:0] ctrl_rd_data, scan_rd_data;
logic ctrl_done, test_write_done;

// Test FSM writes a pattern, then scan_out takes over SDRAM control
assign ctrl_req_valid = test_write_done ? scan_req_valid : 1'b0;
assign scan_req_ready = test_write_done ? ctrl_req_ready : 1'b0;

sdram_ctrl sdram (
    .clk(clk_sdram), .rst(rst),
    .req_valid(ctrl_req_valid), .req_wr(1'b0), .req_addr(scan_req_addr), .req_len(scan_req_len), .req_ready(ctrl_req_ready),
    .wr_data(16'd0), .wr_valid(1'b0), .wr_ready(),
    .rd_data(ctrl_rd_data), .rd_valid(ctrl_rd_valid), .done(ctrl_done),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_in(sdram_dq_in), .sdram_dm(sdram_dm)
);
assign scan_rd_data = ctrl_rd_data;
assign scan_rd_valid = ctrl_rd_valid;

// Scan out and line cache
logic [9:0]  px_v_cnt;
logic        px_h_blank;
logic [24:0] fb_base_addr = 25'h0;
logic [1:0]  w_slot;
logic [9:0]  w_col;
logic [15:0] w_data;
logic        w_en;
logic [1:0]  r_slot;
logic [9:0]  r_col;
logic [15:0] r_data;

scan_out so (
    .clk(clk_sdram), .rst(rst),
    .px_v_cnt(px_v_cnt), .px_h_blank(px_h_blank),
    .fb_base_addr(fb_base_addr),
    .req_valid(scan_req_valid), .req_ready(scan_req_ready), .req_addr(scan_req_addr), .req_len(scan_req_len),
    .rd_data(scan_rd_data), .rd_valid(scan_rd_valid),
    .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en)
);

line_cache lc (
    .wclk(clk_sdram), .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
    .rclk(clk_pix), .r_slot(r_slot), .r_col(r_col), .r_data(r_data)
);

// -----------------------------------------------------------------------
// Stimulus and Verification
// -----------------------------------------------------------------------
localparam H_DISPLAY=800, H_FRONT=40, H_SYNC=48, H_BACK=40, H_TOTAL=H_DISPLAY+H_FRONT+H_SYNC+H_BACK;
localparam V_DISPLAY=480, V_FRONT=13, V_SYNC=3, V_BACK=33, V_TOTAL=V_DISPLAY+V_FRONT+V_SYNC+V_BACK;
integer errors = 0;

logic [9:0] H_CNT;
logic [9:0] V_CNT;

// Test pattern: vertical bars
function automatic logic [15:0] test_pixel(input integer row, input integer col);
    return { (col[7:3] + row[7:3]), (col[5:3] + row[5:3]), (col[7:4] + row[7:4]) };
endfunction

initial begin
    rst <= 1;
    test_write_done <= 0;
    H_CNT <= 0;
    V_CNT <= 0;
    px_h_blank <= 1'b1;
    px_v_cnt <= 0;
    #100;
    rst <= 0;
    wait(pll_locked);
    #1000;

    $display("Writing test pattern to behavioral SDRAM...");
    for (integer row=0; row < V_DISPLAY; row++) begin
        for (integer col=0; col < H_DISPLAY; col++) begin
            sdram_mem[1024 * row + col] = test_pixel(row, col);
        end
    end
    $display("Write complete.");
    test_write_done <= 1;

    // Run simulation for 3 full frames
    #((H_TOTAL * V_TOTAL * 3) * 40);

    $display("Verification complete. Errors: %0d", errors);
    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("FAILED with %0d errors", errors);
    $finish;
end

// Master LCD Timing Generation (single driver for all timing signals)
always @(posedge clk_pix) begin
    if (rst) begin
        H_CNT <= 0;
        V_CNT <= 0;
        px_h_blank <= 1'b1;
        px_v_cnt <= 0;
    end else begin
        if (H_CNT < H_TOTAL - 1) begin
            H_CNT <= H_CNT + 1;
        end else begin
            H_CNT <= 0;
            if (V_CNT < V_TOTAL - 1) begin
                V_CNT <= V_CNT + 1;
            end else begin
                V_CNT <= 0;
            end
        end
        // Synchronize DUT inputs to the master counters
        px_h_blank <= (H_CNT >= H_DISPLAY);
        px_v_cnt <= V_CNT;
    end
end

integer frame_count = 0;
always @(posedge clk_pix) begin
    if (rst) frame_count <= 0;
    else if (H_CNT == 0 && V_CNT == 0) frame_count <= frame_count + 1;
end

// Checker Process (monitors signals, verifies data)
always @(posedge clk_pix) begin
    if (test_write_done && !rst && frame_count >= 2) begin
        // Set the read address for the line cache based on the master timing signals
        r_col <= H_CNT;
        r_slot <= V_CNT[1:0] + 2'd1;

        // Data from BRAM has a 1-cycle read latency.
        // So, the data available at the output 'r_data' on THIS cycle
        // is the data from the address we requested on the PREVIOUS cycle.
        // We must compare r_data to the test pattern for the previous pixel coordinates.
        if (H_CNT > 0 && H_CNT <= H_DISPLAY && V_CNT < V_DISPLAY) begin
            if (r_data !== test_pixel(V_CNT, H_CNT - 1)) begin
                $display("MISMATCH at pix(%0d, %0d): expected %h, got %h", H_CNT - 1, V_CNT, test_pixel(V_CNT, H_CNT - 1), r_data);
                errors = errors + 1;
            end
        end
    end
end

endmodule
