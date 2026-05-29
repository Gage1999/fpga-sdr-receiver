// line_cache.sv
// 4-slot framebuffer line cache: the SDRAM<->pixel clock-domain crossing.
// True dual-port, independent clocks; registered read (1-cycle latency).
// {slot,col} addressing (1024-word stride) avoids an address multiplier on the
// 100 MHz write path; 4 x 1024 x 16b = 4 EBR blocks.

module line_cache #(
    parameter int SLOTS = 4
) (
    // Write side - SDRAM clock domain
    input  logic        wclk,
    input  logic [1:0]  w_slot,
    input  logic [9:0]  w_col,    // 0 .. 1023
    input  logic [15:0] w_data,
    input  logic        w_en,

    // Read side - pixel clock domain
    input  logic        rclk,
    input  logic [1:0]  r_slot,
    input  logic [9:0]  r_col,    // 0 .. 1023
    output logic [15:0] r_data
);

    logic [15:0] mem [0:SLOTS*1024-1];

    always_ff @(posedge wclk)
        if (w_en) mem[{w_slot, w_col}] <= w_data;

    always_ff @(posedge rclk)
        r_data <= mem[{r_slot, r_col}];

endmodule
