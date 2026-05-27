module i2s_tone_test_top (
    input logic CLK,

    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_sdata
);

logic rst = 1'b1;
logic [3:0] rst_cnt = '0;

always_ff @(posedge CLK) begin
    if (!rst_cnt[3]) begin
        rst_cnt <= rst_cnt + 4'd1;
        rst <= 1'b1;
    end else begin
        rst <= 1'b0;
    end
end

logic sample_req;
logic signed [15:0] tone_sample;
logic [4:0] phase;

always_ff @(posedge CLK) begin
    if (rst) begin
        tone_sample <= '0;
        phase <= 5'd0;
    end else if (sample_req) begin
        phase <= phase + 5'd1;
        case (phase)
            5'd0:  tone_sample <= 16'sd0;
            5'd1:  tone_sample <= 16'sd6393;
            5'd2:  tone_sample <= 16'sd12539;
            5'd3:  tone_sample <= 16'sd18204;
            5'd4:  tone_sample <= 16'sd23170;
            5'd5:  tone_sample <= 16'sd27245;
            5'd6:  tone_sample <= 16'sd30273;
            5'd7:  tone_sample <= 16'sd32137;
            5'd8:  tone_sample <= 16'sd32767;
            5'd9:  tone_sample <= 16'sd32137;
            5'd10: tone_sample <= 16'sd30273;
            5'd11: tone_sample <= 16'sd27245;
            5'd12: tone_sample <= 16'sd23170;
            5'd13: tone_sample <= 16'sd18204;
            5'd14: tone_sample <= 16'sd12539;
            5'd15: tone_sample <= 16'sd6393;
            5'd16: tone_sample <= 16'sd0;
            5'd17: tone_sample <= -16'sd6393;
            5'd18: tone_sample <= -16'sd12539;
            5'd19: tone_sample <= -16'sd18204;
            5'd20: tone_sample <= -16'sd23170;
            5'd21: tone_sample <= -16'sd27245;
            5'd22: tone_sample <= -16'sd30273;
            5'd23: tone_sample <= -16'sd32137;
            5'd24: tone_sample <= -16'sd32767;
            5'd25: tone_sample <= -16'sd32137;
            5'd26: tone_sample <= -16'sd30273;
            5'd27: tone_sample <= -16'sd27245;
            5'd28: tone_sample <= -16'sd23170;
            5'd29: tone_sample <= -16'sd18204;
            5'd30: tone_sample <= -16'sd12539;
            default: tone_sample <= -16'sd6393;
        endcase
    end
end

i2s_tx u_i2s (
    .clk (CLK),
    .rst (rst),
    .left_in (tone_sample),
    .right_in (tone_sample),
    .sample_req (sample_req),
    .bclk (i2s_bclk),
    .lrclk (i2s_lrclk),
    .sdata (i2s_sdata)
);

endmodule
