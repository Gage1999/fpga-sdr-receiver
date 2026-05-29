// link_test_top — quantitative signal-integrity / link-error test for the
// PlutoSky -> iCESugar JP5 SPI link.
//
// The Pluto sends an incrementing 32-bit counter (icesugar_stream --mode
// link-test). Each received 32-bit word should be exactly prev+1. This receiver
// reconstructs the words, checks that invariant, and counts:
//   total_count : words received
//   err_count   : words that broke the +1 invariant (a bit flip, a dropped
//                 word, or a CS/clock glitch that slipped the bit alignment)
//
// err_count / total_count is the word-error-rate — the quantitative SI metric.
// Wiggle the wires and watch err_count: a clean link holds it at 0 (green
// screen); a marginal link makes it climb (screen latches red). The exact
// counts are shown as 32-bit binary fields so you can read them off the LCD.
//
// Word CDC uses the same async_fifo the real design uses (spi_clk -> CLK), so
// the check runs in the pixel-clock domain alongside the display — no unsafe
// multi-bit counter crossing.

module link_test_top (
    input  logic CLK,

    input  logic spi_clk,
    input  logic cs,
    input  logic mosi,

    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B
);

assign LCD_CLK = CLK;

// ---- Resets (one per clock domain) ----
logic [3:0] spi_rst_cnt = 4'd0;
logic       spi_rst = 1'b1;
always_ff @(posedge spi_clk) begin
    if (!spi_rst_cnt[3]) begin spi_rst_cnt <= spi_rst_cnt + 4'd1; spi_rst <= 1'b1; end
    else                   spi_rst <= 1'b0;
end

logic [3:0] sys_rst_cnt = 4'd0;
logic       sys_rst = 1'b1;
always_ff @(posedge CLK) begin
    if (!sys_rst_cnt[3]) begin sys_rst_cnt <= sys_rst_cnt + 4'd1; sys_rst <= 1'b1; end
    else                   sys_rst <= 1'b0;
end

// ---- Receive 32-bit words (spi_clk domain) ----
logic [15:0] spi_i, spi_q;
logic        spi_iq_valid;

spi_iq_slave u_spi_iq (
    .spi_clk (spi_clk),
    .spi_cs_n(cs),
    .spi_mosi(mosi),
    .i_data  (spi_i),
    .q_data  (spi_q),
    .iq_valid(spi_iq_valid)
);

// ---- Word CDC into the CLK domain ----
logic [31:0] fifo_rdata;
logic        fifo_empty, fifo_full, fifo_pop, fifo_pop_d;

async_fifo #(.WIDTH(32), .DEPTH(16)) u_fifo (
    .wclk  (spi_clk),
    .wrst  (spi_rst),
    .wdata ({spi_i, spi_q}),
    .wpush (spi_iq_valid & ~fifo_full & ~spi_rst),
    .wfull (fifo_full),
    .rclk  (CLK),
    .rrst  (sys_rst),
    .rdata (fifo_rdata),
    .rpop  (fifo_pop),
    .rempty(fifo_empty)
);

assign fifo_pop = ~fifo_empty;
always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) fifo_pop_d <= 1'b0;
    else         fifo_pop_d <= fifo_pop;
end

// ---- Check the +1 invariant (CLK domain) ----
logic [31:0] last_word;
logic        seeded;
logic [31:0] total_count;
logic [31:0] err_count;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        last_word   <= 32'd0;
        seeded      <= 1'b0;
        total_count <= 32'd0;
        err_count   <= 32'd0;
    end else if (fifo_pop_d) begin
        if (seeded && (fifo_rdata != (last_word + 32'd1)))
            err_count <= err_count + 32'd1;
        last_word   <= fifo_rdata;
        total_count <= total_count + 32'd1;
        seeded      <= 1'b1;
    end
end

// ---- Display (CLK domain; LCD_CLK = CLK) ----
logic [10:0] x = 11'd0;
logic [9:0]  y = 10'd0;
always_ff @(posedge CLK) begin
    if (x < 11'd1055) x <= x + 11'd1;
    else begin
        x <= 11'd0;
        y <= (y < 10'd524) ? y + 10'd1 : 10'd0;
    end
end

wire active  = (x < 11'd800) && (y < 10'd480);
wire in_bits = (x < 11'd512);             // 32 cells x 16 px
wire [4:0] bidx = x[8:4];                  // 0..31, MSB at the left

localparam logic [15:0] C_WHITE = 16'hFFFF;
localparam logic [15:0] C_GREEN = 16'h07E0;
localparam logic [15:0] C_RED   = 16'hF800;
localparam logic [15:0] C_BLUE  = 16'h001F;
localparam logic [15:0] C_DKR   = 16'h2000;
localparam logic [15:0] C_DKG   = 16'h0140;
localparam logic [15:0] C_DIM   = 16'h2104;

logic [15:0] color;
always_comb begin
    color = 16'h0000;
    if (active) begin
        if (y < 10'd100) begin
            // PASS/FAIL banner: blue = no data yet, green = clean, red = errors.
            if (!seeded)            color = C_BLUE;
            else if (err_count != 0) color = C_RED;
            else                     color = C_GREEN;
        end else if (y >= 10'd120 && y < 10'd170 && in_bits) begin
            // err_count, MSB-left. Lit = bit set.
            color = err_count[5'd31 - bidx] ? C_RED : C_DKR;
        end else if (y >= 10'd190 && y < 10'd240 && in_bits) begin
            // total_count, MSB-left.
            color = total_count[5'd31 - bidx] ? C_GREEN : C_DKG;
        end else if (y >= 10'd260 && y < 10'd270 && in_bits) begin
            // tick row: cell separators, to read the 32 bit positions easily.
            color = (x[3:0] == 4'd0) ? C_DIM : 16'h0000;
        end
    end
end

always_comb begin
    LCD_DEN = active;
    LCD_R   = active ? color[15:11] : 5'd0;
    LCD_G   = active ? color[10:5]  : 6'd0;
    LCD_B   = active ? color[4:0]   : 5'd0;
end

endmodule
