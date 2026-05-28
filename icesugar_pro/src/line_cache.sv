// True dual-port RAM for caching framebuffer lines from SDRAM.
// Write side is on the 100 MHz SDRAM clock domain.
// Read side is on the ~30 MHz pixel clock domain.

module line_cache (
    // Write side (sdram clock domain)
    input  logic        wclk,
    input  logic [1:0]  w_slot,   // which of 4 slots to write
    input  logic [9:0]  w_col,    // 0..799
    input  logic [15:0] w_data,
    input  logic        w_en,

    // Read side (pixel clock domain)
    input  logic        rclk,
    input  logic [1:0]  r_slot,
    input  logic [9:0]  r_col,
    output logic [15:0] r_data
);

// 4-slot ring buffer, 800 words x 16 bits per slot.
// Use block RAM for this.
// Total size: 4 * 800 * 16 = 51200 bits = 6400 bytes.

logic [15:0] mem [0:3] [0:799];

// Write port
always_ff @(posedge wclk) begin
    if (w_en)
        mem[w_slot][w_col] <= w_data;
end

// Read port
always_ff @(posedge rclk) begin
    r_data <= mem[r_slot][r_col];
end

endmodule
