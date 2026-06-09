module spectrum_zoom_decimator (
    input logic clk,
    input logic rst,

    input logic signed [15:0] in_i,
    input logic signed [15:0] in_q,
    input logic in_valid,
    input logic [15:0] span_hz_log2,

    output logic signed [15:0] out_i,
    output logic signed [15:0] out_q,
    output logic out_valid,
    output logic [2:0] decim_log2
);

    logic [2:0] decim_log2_next;
    logic [5:0] decim_limit;
    logic [5:0] decim_count;
    logic signed [21:0] acc_i;
    logic signed [21:0] acc_q;
    logic signed [21:0] in_i_ext;
    logic signed [21:0] in_q_ext;
    logic signed [21:0] sum_i;
    logic signed [21:0] sum_q;

    always_comb begin
        if (span_hz_log2 >= 16'd18)      decim_log2_next = 3'd0;
        else if (span_hz_log2 == 16'd17) decim_log2_next = 3'd1;
        else if (span_hz_log2 == 16'd16) decim_log2_next = 3'd2;
        else if (span_hz_log2 == 16'd15) decim_log2_next = 3'd3;
        else if (span_hz_log2 == 16'd14) decim_log2_next = 3'd4;
        else                             decim_log2_next = 3'd5;
    end

    assign decim_limit = 6'd1 << decim_log2_next;
    assign in_i_ext = {{6{in_i[15]}}, in_i};
    assign in_q_ext = {{6{in_q[15]}}, in_q};
    assign sum_i = acc_i + in_i_ext;
    assign sum_q = acc_q + in_q_ext;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            out_i <= '0;
            out_q <= '0;
            out_valid <= 1'b0;
            decim_log2 <= 3'd1;
            decim_count <= 6'd0;
            acc_i <= '0;
            acc_q <= '0;
        end else begin
            out_valid <= 1'b0;

            if (decim_log2 != decim_log2_next) begin
                decim_log2 <= decim_log2_next;
                decim_count <= 6'd0;
                acc_i <= '0;
                acc_q <= '0;
            end else if (in_valid) begin
                if (decim_log2_next == 3'd0) begin
                    out_i <= in_i;
                    out_q <= in_q;
                    out_valid <= 1'b1;
                    decim_count <= 6'd0;
                    acc_i <= '0;
                    acc_q <= '0;
                end else if (decim_count == decim_limit - 6'd1) begin
                    out_i <= 16'(sum_i >>> decim_log2_next);
                    out_q <= 16'(sum_q >>> decim_log2_next);
                    out_valid <= 1'b1;
                    decim_count <= 6'd0;
                    acc_i <= '0;
                    acc_q <= '0;
                end else begin
                    decim_count <= decim_count + 6'd1;
                    acc_i <= sum_i;
                    acc_q <= sum_q;
                end
            end
        end
    end

endmodule
