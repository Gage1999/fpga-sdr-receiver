module audio_volume (
    input logic signed [7:0] audio_in,
    input logic [7:0] volume,
    input logic mute,
    input logic enable,

    output logic signed [15:0] audio_out
);

logic signed [15:0] audio_ext;
logic signed [23:0] scaled;

always_comb begin
    audio_ext = {{8{audio_in[7]}}, audio_in};
    scaled = audio_ext * 16'(volume);
    if (mute || !enable)
        audio_out = '0;
    else
        audio_out = scaled[15:0];
end

endmodule
