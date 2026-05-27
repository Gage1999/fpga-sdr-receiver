module cic_decimate #(
    parameter IN_W = 16,
    parameter R = 25,
    parameter STAGES = 3
)(
    input logic clk,
    input logic rst,
    input logic signed [IN_W-1:0] in_i,
    input logic signed [IN_W-1:0] in_q,
    input logic in_valid,

    output logic signed [IN_W-1:0] out_i,
    output logic signed [IN_W-1:0] out_q,
    output logic out_valid
);

localparam IW = IN_W + STAGES * 5;

logic signed [IW-1:0] integ_i [0:STAGES-1];
logic signed [IW-1:0] integ_q [0:STAGES-1];

logic signed [IW-1:0] comb_i [0:STAGES-1];
logic signed [IW-1:0] comb_q [0:STAGES-1];
logic signed [IW-1:0] prev_i [0:STAGES-1];
logic signed [IW-1:0] prev_q [0:STAGES-1];
logic signed [IW-1:0] dec_i, dec_q;

logic [$clog2(R)-1:0] cnt;
logic strobe;

// Integrators
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        for (int i = 0; i < STAGES; i++) begin
            integ_i[i] <= '0;
            integ_q[i] <= '0;
        end
    end else if (in_valid) begin
        integ_i[0] <= integ_i[0] + IW'(in_i);
        integ_q[0] <= integ_q[0] + IW'(in_q);
        for (int i = 1; i < STAGES; i++) begin
            integ_i[i] <= integ_i[i] + integ_i[i-1];
            integ_q[i] <= integ_q[i] + integ_q[i-1];
        end
    end
end

// Decimation counter
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        cnt <= '0;
        strobe <= 1'b0;
        dec_i <= '0;
        dec_q <= '0;
    end else if (in_valid) begin
        if (cnt == R - 1) begin
            cnt <= '0;
            strobe <= 1'b1;
            dec_i <= integ_i[STAGES-1];
            dec_q <= integ_q[STAGES-1];
        end else begin
            cnt <= cnt + 1'b1;
            strobe <= 1'b0;
        end
    end else begin
        strobe <= 1'b0;
    end
end

// Combs
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        for (int i = 0; i < STAGES; i++) begin
            comb_i[i] <= '0;
            comb_q[i] <= '0;
            prev_i[i] <= '0;
            prev_q[i] <= '0;
        end
        out_i <= '0;
        out_q <= '0;
        out_valid <= 1'b0;
    end else begin
        out_valid <= 1'b0;
        if (strobe) begin
            comb_i[0] <= dec_i - prev_i[0];
            comb_q[0] <= dec_q - prev_q[0];
            prev_i[0] <= dec_i;
            prev_q[0] <= dec_q;
            for (int i = 1; i < STAGES; i++) begin
                comb_i[i] <= comb_i[i-1] - prev_i[i];
                comb_q[i] <= comb_q[i-1] - prev_q[i];
                prev_i[i] <= comb_i[i-1];
                prev_q[i] <= comb_q[i-1];
            end
            out_i <= comb_i[STAGES-1][IW-1 : IW-IN_W];
            out_q <= comb_q[STAGES-1][IW-1 : IW-IN_W];
            out_valid <= 1'b1;
        end
    end
end

endmodule

