module async_fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 16
)(
    input logic wclk,
    input logic wrst,
    input logic [WIDTH-1:0] wdata,
    input logic wpush,
    output logic wfull,

    input logic rclk,
    input logic rrst,
    output logic [WIDTH-1:0] rdata,
    input logic rpop,
    output logic rempty
);

localparam ADDR_W = $clog2(DEPTH);

logic [WIDTH-1:0] mem [0:DEPTH-1];

logic [ADDR_W:0] wptr_bin = '0;
logic [ADDR_W:0] wptr_gray = '0;

logic [ADDR_W:0] rptr_bin = '0;
logic [ADDR_W:0] rptr_gray = '0;

logic [ADDR_W:0] rptr_gray_s1 = '0, rptr_gray_s2 = '0;
logic [ADDR_W:0] wptr_gray_s1 = '0, wptr_gray_s2 = '0;

// Write side
always_ff @(posedge wclk or posedge wrst) begin
    if (wrst) begin
        wptr_bin <= '0;
        wptr_gray <= '0;
    end else if (wpush && !wfull) begin
        mem[wptr_bin[ADDR_W-1:0]] <= wdata;
        wptr_bin <= wptr_bin + 1'b1;
        wptr_gray <= (wptr_bin + 1'b1) ^ ((wptr_bin + 1'b1) >> 1);
    end
end

always_ff @(posedge wclk or posedge wrst) begin
    if (wrst) begin
        rptr_gray_s1 <= '0;
        rptr_gray_s2 <= '0;
    end else begin
        rptr_gray_s1 <= rptr_gray;
        rptr_gray_s2 <= rptr_gray_s1;
    end
end

assign wfull = (wptr_gray == {~rptr_gray_s2[ADDR_W:ADDR_W-1],
                                rptr_gray_s2[ADDR_W-2:0]});

// Read side
always_ff @(posedge rclk or posedge rrst) begin
    if (rrst) begin
        rptr_bin <= '0;
        rptr_gray <= '0;
    end else if (rpop && !rempty) begin
        rdata <= mem[rptr_bin[ADDR_W-1:0]];
        rptr_bin <= rptr_bin + 1'b1;
        rptr_gray <= (rptr_bin + 1'b1) ^ ((rptr_bin + 1'b1) >> 1);
    end
end

always_ff @(posedge rclk or posedge rrst) begin
    if (rrst) begin
        wptr_gray_s1 <= '0;
        wptr_gray_s2 <= '0;
    end else begin
        wptr_gray_s1 <= wptr_gray;
        wptr_gray_s2 <= wptr_gray_s1;
    end
end

assign rempty = (rptr_gray == wptr_gray_s2);

endmodule

