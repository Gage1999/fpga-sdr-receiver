module butterfly (
    input logic clk,

    input logic signed [15:0] ar, ai,
    input logic signed [15:0] br, bi,
    input logic signed [15:0] wr, wi,
    input logic in_valid,

    output logic signed [15:0] pr, pi,
    output logic signed [15:0] qr, qi,
    output logic out_valid
);

// Multiply
logic signed [31:0] m0, m1, m2, m3;
logic signed [16:0] wb_r, wb_i;
logic signed [15:0] ar1, ai1;
logic v1;

always_ff @(posedge clk) begin
    m0 <= wr * br;
    m1 <= wi * bi;
    m2 <= wr * bi;
    m3 <= wi * br;
    ar1 <= ar;
    ai1 <= ai;
    v1 <= in_valid;
end

// Add/subtract
always_ff @(posedge clk) begin
    wb_r <= (m0 - m1) >>> 15;
    wb_i <= (m2 + m3) >>> 15;

    pr <= ar1 + wb_r[15:0];
    pi <= ai1 + wb_i[15:0];
    qr <= ar1 - wb_r[15:0];
    qi <= ai1 - wb_i[15:0];

    out_valid <= v1;
end

endmodule

