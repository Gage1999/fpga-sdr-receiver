module fm_demod (
    input logic clk,
    input logic rst,
    input logic signed [15:0] i_in,
    input logic signed [15:0] q_in,
    input logic in_valid,

    output logic signed [15:0] audio_out,
    output logic audio_valid,

    output logic signed [15:0] mpx_out,
    output logic mpx_valid
);

logic signed [15:0] i_prev, q_prev;
logic signed [31:0] cross1, cross2;
logic signed [32:0] demod_raw;
logic signed [15:0] demod_scaled;
logic signed [24:0] demod_pre;
assign demod_pre = demod_raw[32:8];


logic signed [15:0] de_state;
logic signed [18:0] de_err;
assign de_err = {{3{demod_scaled[15]}}, demod_scaled} - {{3{de_state[15]}}, de_state};

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        i_prev <= '0;
        q_prev <= '0;
        cross1 <= '0;
        cross2 <= '0;
        demod_raw <= '0;
        demod_scaled <= '0;
        de_state <= '0;
        audio_out <= '0;
        audio_valid <= 1'b0;
        mpx_out <= '0;
        mpx_valid <= 1'b0;
    end else begin
        audio_valid <= 1'b0;
        mpx_valid <= 1'b0;
        if (in_valid) begin
            cross1 <= i_prev * q_in;
            cross2 <= i_in * q_prev;
            demod_raw <= cross1 - cross2;

            if (demod_pre > 25'sd32767) demod_scaled <= 16'sd32767;
            else if (demod_pre < -25'sd32768) demod_scaled <= -16'sd32768;
            else demod_scaled <= demod_pre[15:0];

            de_state <= de_state + ((de_err + (de_err <<< 1) + (de_err <<< 2)) >>> 7);

            audio_out <= de_state;
            audio_valid <= 1'b1;

            mpx_out <= demod_scaled;
            mpx_valid <= 1'b1;

            i_prev <= i_in;
            q_prev <= q_in;
        end
    end
end

endmodule

