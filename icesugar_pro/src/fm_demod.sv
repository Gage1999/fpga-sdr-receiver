module fm_demod (
    input logic clk,
    input logic rst,
    input logic signed [15:0] i_in,
    input logic signed [15:0] q_in,
    input logic in_valid,

    output logic signed [7:0] audio_out,
    output logic audio_valid
);

logic signed [15:0] i_prev, q_prev;
logic signed [31:0] cross1, cross2;
logic signed [32:0] demod_raw;
logic signed [15:0] demod_scaled;

localparam DE_SHIFT = 2;
logic signed [15:0] de_state;

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
    end else begin
        audio_valid <= 1'b0;
        if (in_valid) begin
            cross1 <= i_prev * q_in;
            cross2 <= i_in * q_prev;
            demod_raw <= cross1 - cross2;

            demod_scaled <= demod_raw[23:8];

            de_state <= de_state
                        - (de_state >>> DE_SHIFT)
                        + (demod_scaled >>> DE_SHIFT);

            audio_out <= de_state[15:8];
            audio_valid <= 1'b1;

            i_prev <= i_in;
            q_prev <= q_in;
        end
    end
end

endmodule

