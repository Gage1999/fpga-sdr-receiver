module audio_volume (
    input logic signed [15:0] audio_in,
    input logic [7:0] volume,
    input logic mute,
    input logic enable,

    output logic signed [15:0] audio_out
);

logic signed [31:0] scaled;

always_comb begin
    scaled = audio_in * $signed({1'b0, volume});
    if (mute || !enable)
        audio_out = '0;
    else
        audio_out = scaled[23:8];
end

endmodule
