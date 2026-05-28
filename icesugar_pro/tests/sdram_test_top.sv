// SDRAM hardware test
// - Initializes SDRAM controller
// - Writes 8 words to address 0
// - Reads 8 words back
// - If data matches, LCD is green. If mismatch, LCD is red.

module sdram_test_top(
    input  logic CLK,
    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B,

    // SDRAM pins
    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    inout  logic [15:0] sdram_dq,
    output logic [1:0]  sdram_dm
);

// -----------------------------------------------------------------------
// PLL for 100 MHz SDRAM clock and 30 MHz pixel clock
// -----------------------------------------------------------------------
logic clk_sdram;
logic clk_pix;
logic pll_locked;

EHXPLLL #(
    .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
    .DPHASE_SOURCE("DISABLED"), .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
    .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
    .CLKI_DIV(1), .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(6), .CLKOP_CPHASE(5), .CLKOP_FPHASE(0),
    .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(20), .CLKOS_CPHASE(9), .CLKOS_FPHASE(0),
    .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(4)
) pll (
    .CLKI(CLK),
    .CLKFB(clk_sdram),
    .PHASESEL0(1'b0),
    .PHASESEL1(1'b0),
    .PHASEDIR(1'b0),
    .PHASESTEP(1'b0),
    .PHASELOADREG(1'b0),
    .STDBY(1'b0),
    .PLLWAKESYNC(1'b0),
    .RST(1'b0),
    .ENCLKOP(1'b0),
    .ENCLKOS(1'b0),
    .CLKOP(clk_sdram),
    .CLKOS(clk_pix),
    .LOCK(pll_locked)
);

// -----------------------------------------------------------------------
// Reset generation
// -----------------------------------------------------------------------
logic rst;
always_ff @(posedge clk_sdram)
    rst <= ~pll_locked;

// -----------------------------------------------------------------------
// SDRAM controller instantiation
// -----------------------------------------------------------------------
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

logic [15:0] sdram_dq_out;
logic        sdram_dq_oe;
logic [15:0] sdram_dq_in;

sdram_ctrl sdram (
    .clk        (clk_sdram),  .rst       (rst),
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

// DQ bus tristate buffers - inferred
assign sdram_dq = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
assign sdram_dq_in = sdram_dq;

// -----------------------------------------------------------------------
// Test state machine
// -----------------------------------------------------------------------
localparam [15:0] PAT0 = 16'hA5C3;
localparam [15:0] PAT1 = 16'h1234;
localparam [15:0] PAT2 = 16'hDEAD;
localparam [15:0] PAT3 = 16'hBEEF;
localparam [15:0] PAT4 = 16'hCAFE;
localparam [15:0] PAT5 = 16'hF00D;
localparam [15:0] PAT6 = 16'h5A5A;
localparam [15:0] PAT7 = 16'hC3C3;

logic [15:0] wr_pattern [0:7];
logic [15:0] rd_capture [0:7];
logic [2:0]  errors;

typedef enum logic [3:0] {
    S_WAIT_INIT, S_START_WRITE, S_WRITE_LOOP, S_WAIT_WRITE_DONE,
    S_START_READ, S_READ_LOOP, S_WAIT_READ_DONE,
    S_VERIFY, S_PASS, S_FAIL
} state_t;

state_t state;
logic [2:0] idx;

initial begin
    wr_pattern[0] = PAT0; wr_pattern[1] = PAT1;
    wr_pattern[2] = PAT2; wr_pattern[3] = PAT3;
    wr_pattern[4] = PAT4; wr_pattern[5] = PAT5;
    wr_pattern[6] = PAT6; wr_pattern[7] = PAT7;
end

always_ff @(posedge clk_sdram) begin
    if (rst) begin
        state     <= S_WAIT_INIT;
        req_valid <= 0;
        wr_valid  <= 0;
        errors    <= 0;
    end else begin
        // Defaults
        req_valid <= 0;
        wr_valid  <= 0;
        if (done) state <= state; // Hold state during done pulse

        case (state)
            S_WAIT_INIT: if (req_ready) state <= S_START_WRITE;
            S_START_WRITE: begin
                req_valid <= 1'b1;
                req_wr    <= 1'b1;
                req_addr  <= 25'h0;
                req_len   <= 6'd8;
                if (req_ready) begin
                    state <= S_WRITE_LOOP;
                    idx   <= 0;
                end
            end
            S_WRITE_LOOP: begin
                req_valid <= 1'b1;
                if (wr_ready) begin
                    wr_data <= wr_pattern[idx];
                    wr_valid <= 1'b1;
                    if (idx == 7) state <= S_WAIT_WRITE_DONE;
                    idx <= idx + 1;
                end
            end
            S_WAIT_WRITE_DONE: if (done) state <= S_START_READ;
            S_START_READ: begin
                req_valid <= 1'b1;
                req_wr    <= 1'b0;
                req_addr  <= 25'h0;
                req_len   <= 6'd8;
                if (req_ready) begin
                    state <= S_READ_LOOP;
                    idx   <= 0;
                end
            end
            S_READ_LOOP: begin
                if (rd_valid) begin
                    rd_capture[idx] <= rd_data;
                    if (idx == 7) state <= S_WAIT_READ_DONE;
                    idx <= idx + 1;
                end
            end
            S_WAIT_READ_DONE: if (done) state <= S_VERIFY;
            S_VERIFY: begin
                for (int i=0; i<8; i++)
                    if (rd_capture[i] != wr_pattern[i])
                        errors <= errors + 1;
                if (errors == 0) state <= S_PASS;
                else state <= S_FAIL;
            end
            S_PASS: ; // Stay here
            S_FAIL: ; // Stay here
        endcase
    end
end

// -----------------------------------------------------------------------
// LCD driver - solid color based on test state
// -----------------------------------------------------------------------
logic [9:0] H_CNT;
logic [9:0] V_CNT;
localparam H_DISPLAY = 800;
localparam H_FRONT   = 40;
localparam H_SYNC    = 48;
localparam H_BACK    = 40;
localparam H_TOTAL   = H_DISPLAY + H_FRONT + H_SYNC + H_BACK;
localparam V_DISPLAY = 480;
localparam V_FRONT   = 13;
localparam V_SYNC    = 3;
localparam V_BACK    = 33;
localparam V_TOTAL   = V_DISPLAY + V_FRONT + V_SYNC + V_BACK;

assign LCD_CLK = clk_pix;

always_ff @(posedge clk_pix) begin
    if (H_CNT < H_TOTAL-1) H_CNT <= H_CNT + 1;
    else begin
        H_CNT <= 0;
        if (V_CNT < V_TOTAL-1) V_CNT <= V_CNT + 1;
        else V_CNT <= 0;
    end
end

assign LCD_DEN = (H_CNT < H_DISPLAY) && (V_CNT < V_DISPLAY);

logic [4:0] r_out;
logic [5:0] g_out;
logic [4:0] b_out;

always_comb begin
    case (state)
        S_PASS:   {r_out, g_out, b_out} = {5'd0, 6'd63, 5'd0}; // Green
        S_FAIL:   {r_out, g_out, b_out} = {5'd31, 6'd0, 5'd0}; // Red
        default:  {r_out, g_out, b_out} = {5'd0, 6'd0, 5'd31}; // Blue
    endcase
end

assign LCD_R = LCD_DEN ? r_out : 5'd0;
assign LCD_G = LCD_DEN ? g_out : 6'd0;
assign LCD_B = LCD_DEN ? b_out : 5'd0;

endmodule
