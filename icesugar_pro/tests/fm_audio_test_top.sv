// Standalone FM audio bring-up top.
module fm_audio_test_top #(
    parameter FM_CIC_R     = 8,
    parameter I2S_AUDIO_RATE = 32_552,  // 25 MHz / (2*6*64), matched by IQ_SAMPLE_RATE/8
    parameter I2S_BCLK_HALF_CYCLES = 6,
    parameter IQ_SAMPLE_RATE = 260_417,
    parameter IQ_FIFO_DEPTH = 8192,
    parameter IQ_PREROLL_SAMPLES = 4096,
    parameter AFIFO_DEPTH  = 64,
    parameter AUDIO_TEST_TONE = 0,
    parameter IQ_TEST_FM = 0,
    parameter CLK_HZ       = 25_000_000
)(
    input logic CLK,

    input logic spi_clk,
    input logic cs,
    input logic mosi,

    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_sdata,
    output logic i2s_sck
);

assign i2s_sck = 1'b0;

// Reset
logic [3:0] sys_rst_cnt = 4'd0;
logic sys_rst = 1'b1;

always_ff @(posedge CLK) begin
    if (!sys_rst_cnt[3]) begin
        sys_rst_cnt <= sys_rst_cnt + 4'd1;
        sys_rst <= 1'b1;
    end else begin
        sys_rst <= 1'b0;
    end
end

logic [3:0] spi_rst_cnt = 4'd0;
logic spi_rst = 1'b1;

always_ff @(posedge spi_clk) begin
    if (!spi_rst_cnt[3]) begin
        spi_rst_cnt <= spi_rst_cnt + 4'd1;
        spi_rst <= 1'b1;
    end else begin
        spi_rst <= 1'b0;
    end
end

// SPI IQ slave
logic [15:0] spi_i, spi_q;
logic spi_iq_valid;

spi_iq_slave u_spi_iq (
    .spi_clk  (spi_clk),
    .spi_cs_n (cs),
    .spi_mosi (mosi),
    .i_data   (spi_i),
    .q_data   (spi_q),
    .iq_valid (spi_iq_valid)
);

// IQ async FIFO: spi_clk domain -> CLK domain. Pluto/Linux delivery is bursty,
// so this FIFO is intentionally large and prerolled before the paced reader
// starts feeding the FM demodulator.
localparam int IQ_PREROLL_W = (IQ_PREROLL_SAMPLES > 0) ? $clog2(IQ_PREROLL_SAMPLES + 1) : 1;

logic [31:0] fifo_rdata;
logic fifo_empty, fifo_full, fifo_pop, fifo_pop_d;
logic iq_started;
logic [IQ_PREROLL_W-1:0] iq_preroll_cnt;

async_fifo #(.WIDTH(32), .DEPTH(IQ_FIFO_DEPTH)) u_iq_fifo (
    .wclk  (spi_clk),
    .wrst  (spi_rst),
    .wdata ({spi_i, spi_q}),
    .wpush (spi_iq_valid & ~fifo_full & ~spi_rst),
    .wfull (fifo_full),
    .rclk  (CLK),
    .rrst  (sys_rst),
    .rdata (fifo_rdata),
    .rpop  (fifo_pop),
    .rempty(fifo_empty)
);

logic [31:0] iq_rate_acc;
logic iq_sample_tick;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        iq_rate_acc <= 32'd0;
        iq_sample_tick <= 1'b0;
    end else begin
        iq_sample_tick <= 1'b0;
        if (iq_rate_acc >= (CLK_HZ - IQ_SAMPLE_RATE)) begin
            iq_rate_acc <= iq_rate_acc + IQ_SAMPLE_RATE - CLK_HZ;
            iq_sample_tick <= 1'b1;
        end else begin
            iq_rate_acc <= iq_rate_acc + IQ_SAMPLE_RATE;
        end
    end
end

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        iq_started <= 1'b0;
        iq_preroll_cnt <= '0;
    end else if (IQ_TEST_FM) begin
        iq_started <= 1'b1;
    end else if (!iq_started && !fifo_empty && iq_sample_tick) begin
        if (iq_preroll_cnt == IQ_PREROLL_SAMPLES[$bits(iq_preroll_cnt)-1:0])
            iq_started <= 1'b1;
        else
            iq_preroll_cnt <= iq_preroll_cnt + 1'b1;
    end
end

assign fifo_pop = (!IQ_TEST_FM) && iq_started && iq_sample_tick && ~fifo_empty;

always_ff @(posedge CLK) begin
    if (sys_rst) fifo_pop_d <= 1'b0;
    else         fifo_pop_d <= fifo_pop;
end

logic signed [15:0] sys_i, sys_q;
logic sys_iq_valid;
logic [7:0] test_fm_phase;
logic [15:0] test_audio_phase;

function automatic signed [15:0] sin32(input logic [4:0] idx);
    case (idx)
        5'd0:  sin32 = 16'sd0;
        5'd1:  sin32 = 16'sd1561;
        5'd2:  sin32 = 16'sd3061;
        5'd3:  sin32 = 16'sd4444;
        5'd4:  sin32 = 16'sd5657;
        5'd5:  sin32 = 16'sd6652;
        5'd6:  sin32 = 16'sd7391;
        5'd7:  sin32 = 16'sd7846;
        5'd8:  sin32 = 16'sd8000;
        5'd9:  sin32 = 16'sd7846;
        5'd10: sin32 = 16'sd7391;
        5'd11: sin32 = 16'sd6652;
        5'd12: sin32 = 16'sd5657;
        5'd13: sin32 = 16'sd4444;
        5'd14: sin32 = 16'sd3061;
        5'd15: sin32 = 16'sd1561;
        5'd16: sin32 = 16'sd0;
        5'd17: sin32 = -16'sd1561;
        5'd18: sin32 = -16'sd3061;
        5'd19: sin32 = -16'sd4444;
        5'd20: sin32 = -16'sd5657;
        5'd21: sin32 = -16'sd6652;
        5'd22: sin32 = -16'sd7391;
        5'd23: sin32 = -16'sd7846;
        5'd24: sin32 = -16'sd8000;
        5'd25: sin32 = -16'sd7846;
        5'd26: sin32 = -16'sd7391;
        5'd27: sin32 = -16'sd6652;
        5'd28: sin32 = -16'sd5657;
        5'd29: sin32 = -16'sd4444;
        5'd30: sin32 = -16'sd3061;
        default: sin32 = -16'sd1561;
    endcase
endfunction

function automatic signed [7:0] fm_step32(input logic [4:0] idx);
    case (idx)
        5'd0:  fm_step32 = 8'sd0;
        5'd1:  fm_step32 = 8'sd1;
        5'd2:  fm_step32 = 8'sd2;
        5'd3:  fm_step32 = 8'sd3;
        5'd4:  fm_step32 = 8'sd4;
        5'd5:  fm_step32 = 8'sd5;
        5'd6:  fm_step32 = 8'sd5;
        5'd7:  fm_step32 = 8'sd5;
        5'd8:  fm_step32 = 8'sd5;
        5'd9:  fm_step32 = 8'sd5;
        5'd10: fm_step32 = 8'sd5;
        5'd11: fm_step32 = 8'sd5;
        5'd12: fm_step32 = 8'sd4;
        5'd13: fm_step32 = 8'sd3;
        5'd14: fm_step32 = 8'sd2;
        5'd15: fm_step32 = 8'sd1;
        5'd16: fm_step32 = 8'sd0;
        5'd17: fm_step32 = -8'sd1;
        5'd18: fm_step32 = -8'sd2;
        5'd19: fm_step32 = -8'sd3;
        5'd20: fm_step32 = -8'sd4;
        5'd21: fm_step32 = -8'sd5;
        5'd22: fm_step32 = -8'sd5;
        5'd23: fm_step32 = -8'sd5;
        5'd24: fm_step32 = -8'sd5;
        5'd25: fm_step32 = -8'sd5;
        5'd26: fm_step32 = -8'sd5;
        5'd27: fm_step32 = -8'sd5;
        5'd28: fm_step32 = -8'sd4;
        5'd29: fm_step32 = -8'sd3;
        5'd30: fm_step32 = -8'sd2;
        default: fm_step32 = -8'sd1;
    endcase
endfunction

always_ff @(posedge CLK) begin
    if (sys_rst) begin
        sys_iq_valid <= 1'b0;
        sys_i <= '0;
        sys_q <= '0;
        test_fm_phase <= 8'd0;
        test_audio_phase <= 16'd0;
    end else begin
        if (IQ_TEST_FM) begin
            sys_iq_valid <= iq_sample_tick;
            if (iq_sample_tick) begin
                test_fm_phase <= test_fm_phase + fm_step32(test_audio_phase[15:11]);
                test_audio_phase <= test_audio_phase + 16'd252; // ~1 kHz at 260.417 kS/s
                sys_i <= sin32((test_fm_phase[7:3] + 5'd8) & 5'h1f);
                sys_q <= sin32(test_fm_phase[7:3]);
            end
        end else begin
            sys_iq_valid <= fifo_pop_d;
            sys_i <= $signed(fifo_rdata[31:16]);
            sys_q <= $signed(fifo_rdata[15:0]);
        end
    end
end

// FM demodulator at IQ input rate. IQ is scaled down to keep the discriminator
// products inside the 16-bit audio range for this bring-up signal level.
logic signed [15:0] audio_raw;
logic audio_raw_valid;

fm_demod u_fm (
    .clk       (CLK),
    .rst       (sys_rst),
    .i_in      (sys_i >>> 3),
    .q_in      (sys_q >>> 3),
    .in_valid  (sys_iq_valid),
    .audio_out (audio_raw),
    .audio_valid(audio_raw_valid)
);

// FM_CIC_R:1 audio decimator. The 3-stage CIC provides enough stop-band
// rejection for the discriminator output before it is reduced to I2S rate.
localparam int AUD_SHIFT = $clog2(FM_CIC_R);
localparam int AUD_STAGES = 3;
localparam int AUD_W = 16 + AUD_STAGES * AUD_SHIFT + 2;
localparam int AUD_GAIN_SHIFT = AUD_STAGES * AUD_SHIFT;
localparam logic signed [AUD_W-1:0] AUD_MAX = {{(AUD_W-16){1'b0}}, 16'sd32767};
localparam logic signed [AUD_W-1:0] AUD_MIN = {{(AUD_W-16){1'b1}}, -16'sd32768};

logic signed [15:0] audio_sample;
logic audio_valid;
logic [AUD_SHIFT-1:0] aud_dec_cnt;
logic signed [AUD_W-1:0] aud_integ [0:AUD_STAGES-1];
logic signed [AUD_W-1:0] aud_comb  [0:AUD_STAGES-1];
logic signed [AUD_W-1:0] aud_prev  [0:AUD_STAGES-1];
logic signed [AUD_W-1:0] aud_decim;
logic signed [AUD_W-1:0] aud_scaled;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        aud_dec_cnt <= '0;
        aud_decim <= '0;
        aud_scaled <= '0;
        for (int k = 0; k < AUD_STAGES; k++) begin
            aud_integ[k] <= '0;
            aud_comb[k] <= '0;
            aud_prev[k] <= '0;
        end
        audio_sample <= '0;
        audio_valid <= 1'b0;
    end else begin
        audio_valid <= 1'b0;
        if (audio_raw_valid) begin
            aud_integ[0] <= aud_integ[0] + {{(AUD_W-16){audio_raw[15]}}, audio_raw};
            for (int k = 1; k < AUD_STAGES; k++)
                aud_integ[k] <= aud_integ[k] + aud_integ[k-1];

            if (&aud_dec_cnt) begin
                aud_decim <= aud_integ[AUD_STAGES-1];

                aud_comb[0] <= aud_decim - aud_prev[0];
                aud_prev[0] <= aud_decim;
                for (int k = 1; k < AUD_STAGES; k++) begin
                    aud_comb[k] <= aud_comb[k-1] - aud_prev[k];
                    aud_prev[k] <= aud_comb[k-1];
                end

                aud_scaled <= aud_comb[AUD_STAGES-1] >>> AUD_GAIN_SHIFT;
                if      (aud_scaled > AUD_MAX) audio_sample <= 16'sd32767;
                else if (aud_scaled < AUD_MIN) audio_sample <= -16'sd32768;
                else                           audio_sample <= aud_scaled[15:0];
                audio_valid <= 1'b1;
            end
            aud_dec_cnt <= aud_dec_cnt + 1'b1;
        end
    end
end

logic signed [15:0] audio_sample_16;
assign audio_sample_16 = audio_sample;

// Audio FIFO: preroll to half-full, then consume one sample per I2S frame.
logic [15:0] afifo_rdata;
logic afifo_empty, afifo_full;
logic [$clog2(AFIFO_DEPTH):0] afifo_count;
logic [1:0] afifo_pop_n;
logic [15:0] audio_held;
logic i2s_sample_req, i2s_sample_req_d;
wire sample_req_edge = i2s_sample_req & ~i2s_sample_req_d;
logic audio_started;

audio_fifo #(.WIDTH(16), .DEPTH(AFIFO_DEPTH)) u_afifo (
    .clk    (CLK),
    .rst    (sys_rst),
    .wdata  (audio_sample_16),
    .wpush  (audio_valid & ~afifo_full),
    .full   (afifo_full),
    .rdata  (afifo_rdata),
    .rpop_n (afifo_pop_n),
    .empty  (afifo_empty),
    .count  (afifo_count)
);

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst)
        audio_started <= 1'b0;
    else if (afifo_count >= (AFIFO_DEPTH / 2))
        audio_started <= 1'b1;
end

assign afifo_pop_n = (audio_started && sample_req_edge && !afifo_empty) ? 2'd1 : 2'd0;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) i2s_sample_req_d <= 1'b0;
    else         i2s_sample_req_d <= i2s_sample_req;
end

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst)           audio_held <= '0;
    else if (~afifo_empty) audio_held <= afifo_rdata;
end

wire signed [15:0] audio_play = (!audio_started || afifo_empty) ? audio_held : afifo_rdata;

logic signed [15:0] tone_sample;
logic [4:0] tone_phase;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        tone_sample <= '0;
        tone_phase <= 5'd0;
    end else if (i2s_sample_req) begin
        tone_phase <= tone_phase + 5'd1;
        case (tone_phase)
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

wire signed [15:0] audio_to_i2s = AUDIO_TEST_TONE ? tone_sample : audio_play;

// I2S transmitter
i2s_tx #(
    .AUDIO_RATE(I2S_AUDIO_RATE),
    .CLK_HZ(CLK_HZ),
    .BCLK_HALF_CYCLES(I2S_BCLK_HALF_CYCLES)
) u_i2s (
    .clk       (CLK),
    .rst       (sys_rst),
    .left_in   (audio_to_i2s),
    .right_in  (audio_to_i2s),
    .sample_req(i2s_sample_req),
    .bclk      (i2s_bclk),
    .lrclk     (i2s_lrclk),
    .sdata     (i2s_sdata)
);

endmodule
