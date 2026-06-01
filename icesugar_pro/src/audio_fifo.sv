// audio_fifo — single-clock elastic FIFO between fm_demod and i2s_tx.
//
// fm_demod produces audio samples at ~IQ_rate/FM_CIC_R, which is bursty (the IQ
// link delivers in packets, and the FFT/CIC gobble the FIFO then idle), and that
// average rate doesn't exactly match the fixed I2S playback rate. Without a
// buffer the DAC just latches whatever the demod last produced → distortion.
//
// This FIFO decouples the two. The consumer (top.sv) reads one sample per I2S
// frame, and uses a variable read advance to absorb the rate mismatch:
//   rpop_n = 1  normal
//   rpop_n = 0  buffer running low  -> repeat the head (hold) until it refills
//   rpop_n = 2  buffer running high -> skip one sample to catch up
// A single skip/repeat is an inaudible blip vs. the gross aliasing you get from a
// 50% sample-rate mismatch. `count` lets the consumer pick rpop_n from the fill
// level. FWFT: rdata always shows the head (valid when !empty).

module audio_fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 1024
) (
    input  logic clk,
    input  logic rst,

    input  logic [WIDTH-1:0] wdata,
    input  logic             wpush,
    output logic             full,

    output logic [WIDTH-1:0] rdata,      // head (FWFT, valid when !empty)
    input  logic [1:0]       rpop_n,     // advance read pointer by 0/1/2 (clamped to fill)
    output logic             empty,
    output logic [$clog2(DEPTH):0] count
);

localparam int AW = $clog2(DEPTH);

logic [WIDTH-1:0] mem [0:DEPTH-1];
logic [AW:0] wptr, rptr;

assign count = wptr - rptr;
assign empty = (count == 0);
assign full  = (count >= DEPTH);         // count (AW+1 bits) widened to compare vs DEPTH

// Clamp the advance to what's actually buffered (rpop_n max is 2).
wire [1:0] adv = (count >= {{(AW-1){1'b0}}, rpop_n}) ? rpop_n : count[1:0];

// Control and write: async reset on pointers only.
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        wptr <= '0;
        rptr <= '0;
    end else begin
        if (wpush && !full) begin
            mem[wptr[AW-1:0]] <= wdata;
            wptr <= wptr + 1'b1;
        end
        rptr <= rptr + adv;
    end
end

// Read: no async reset so Yosys can infer EBR.
// rdata is undefined after reset but consumer checks empty before using it.
always_ff @(posedge clk) begin
    rdata <= mem[rptr[AW-1:0]];
end

endmodule
