// Elastic audio FIFO with variable read advance.
module audio_fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 1024
) (
    input  logic clk,
    input  logic rst,

    input  logic [WIDTH-1:0] wdata,
    input  logic wpush,
    output logic full,

    output logic [WIDTH-1:0] rdata,
    input  logic [1:0] rpop_n,
    output logic empty,
    output logic [$clog2(DEPTH):0] count
);

localparam int AW = $clog2(DEPTH);

logic [WIDTH-1:0] mem [0:DEPTH-1];
logic [AW:0] wptr, rptr;

assign count = wptr - rptr;
assign empty = (count == 0);
assign full  = (count >= DEPTH);

wire [1:0] adv = (count >= {{(AW-1){1'b0}}, rpop_n}) ? rpop_n : count[1:0];

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

// No async reset here so Yosys can infer EBR.
always_ff @(posedge clk) begin
    rdata <= mem[rptr[AW-1:0]];
end

endmodule
