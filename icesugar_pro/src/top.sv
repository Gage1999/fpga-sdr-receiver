module top #(
    parameter AUDIO_TEST_TONE = 0,
    parameter FM_CHAIN_TEST = 0,
    parameter FM_CIC_R = 32,
    parameter IQ_PACED = 0,
    parameter IQ_SAMPLE_RATE = 349_000,
    parameter IQ_FIFO_DEPTH = 16,
    parameter CLK_HZ = 25_000_000
)(
    input logic CLK,

    input logic spi_clk,
    input logic cs,
    input logic mosi,

    input logic spi_clk_pico,
    input logic cs1,
    input logic mosi_pico,

    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_sdata,

    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B
);

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

// Pico command SPI
logic cmd_valid;
logic [7:0] cmd;
logic [31:0] cmd_arg;

spi_cmd_slave u_spi_cmd (
    .spi_clk (spi_clk_pico),
    .spi_cs_n (cs1),
    .spi_mosi (mosi_pico),
    .clk (CLK),
    .rst (sys_rst),
    .cmd_valid (cmd_valid),
    .cmd (cmd),
    .arg (cmd_arg)
);

logic [2:0] mode;
logic [7:0] volume;
logic mute;
logic [31:0] freq_hz;
logic fm_active;

assign fm_active = (mode == 3'd0);

control_regs u_ctrl (
    .clk (CLK),
    .rst (sys_rst),
    .cmd_valid (cmd_valid),
    .cmd (cmd),
    .arg (cmd_arg),
    .mode (mode),
    .volume (volume),
    .mute (mute),
    .freq_hz (freq_hz)
);

// IQ SPI
logic [15:0] spi_i, spi_q;
logic spi_iq_valid;

spi_iq_slave u_spi_iq (
    .spi_clk (spi_clk),
    .spi_cs_n (cs),
    .spi_mosi (mosi),
    .i_data (spi_i),
    .q_data (spi_q),
    .iq_valid (spi_iq_valid)
);

// IQ FIFO
logic [31:0] fifo_wdata, fifo_rdata;
logic fifo_empty, fifo_full;
logic fifo_pop;
logic fifo_pop_d;
logic iq_sample_tick;
logic [31:0] iq_rate_acc;

assign fifo_wdata = {spi_i, spi_q};

async_fifo #(.WIDTH(32), .DEPTH(IQ_FIFO_DEPTH)) u_iq_fifo (
    .wclk (spi_clk),
    .wrst (spi_rst),
    .wdata (fifo_wdata),
    .wpush (spi_iq_valid & ~fifo_full & ~spi_rst),
    .wfull (fifo_full),
    .rclk (CLK),
    .rrst (sys_rst),
    .rdata (fifo_rdata),
    .rpop (fifo_pop),
    .rempty (fifo_empty)
);

always_ff @(posedge CLK) begin
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

assign fifo_pop = IQ_PACED ? (iq_sample_tick && ~fifo_empty) : ~fifo_empty;

always_ff @(posedge CLK) begin
    if (sys_rst)
        fifo_pop_d <= 1'b0;
    else
        fifo_pop_d <= fifo_pop;
end

logic signed [15:0] sys_i, sys_q;
logic sys_iq_valid;

always_ff @(posedge CLK) begin
    if (sys_rst) begin
        sys_iq_valid <= 1'b0;
        sys_i <= '0;
        sys_q <= '0;
    end else begin
        sys_iq_valid <= fifo_pop_d;
        sys_i <= $signed(fifo_rdata[31:16]);
        sys_q <= $signed(fifo_rdata[15:0]);
    end
end

// FFT
logic [7:0] bin_magnitude;
logic [7:0] bin_index;
logic bin_valid;
logic [7:0] wf_wr_magnitude;
logic wf_wr_valid;
logic wf_frame_write;
logic wf_frame_active;
logic [4:0] wf_frame_skip;
logic [7:0] dbg_rx_count;
logic [7:0] dbg_bin_count;
logic [7:0] dbg_last_mag;
localparam RX_SPS_CLK_W = $clog2(CLK_HZ);
logic [31:0] rx_sps_bcd;
logic [31:0] rx_sps_bcd_accum;
logic [31:0] rx_sps_bcd_next;
logic [RX_SPS_CLK_W-1:0] rx_sps_clk_count;

localparam [4:0] WF_FRAME_DECIM = 5'd31;

fft256 u_fft (
    .clk (CLK),
    .rst (sys_rst),
    .i_in (sys_i),
    .q_in (sys_q),
    .in_valid (sys_iq_valid),
    .bin_magnitude (bin_magnitude),
    .bin_index (bin_index),
    .bin_valid (bin_valid)
);

always_ff @(posedge CLK) begin
    if (sys_rst) begin
        dbg_rx_count <= 8'd0;
        dbg_bin_count <= 8'd0;
        dbg_last_mag <= 8'd0;
    end else begin
        if (sys_iq_valid)
            dbg_rx_count <= dbg_rx_count + 8'd1;
        if (bin_valid) begin
            dbg_bin_count <= dbg_bin_count + 8'd1;
            dbg_last_mag <= bin_magnitude;
        end
    end
end

function automatic logic [31:0] bcd_inc8(input logic [31:0] value);
    logic [31:0] out;
    begin
        out = value;
        if (out[3:0] != 4'd9) begin
            out[3:0] = out[3:0] + 4'd1;
        end else begin
            out[3:0] = 4'd0;
            if (out[7:4] != 4'd9) begin
                out[7:4] = out[7:4] + 4'd1;
            end else begin
                out[7:4] = 4'd0;
                if (out[11:8] != 4'd9) begin
                    out[11:8] = out[11:8] + 4'd1;
                end else begin
                    out[11:8] = 4'd0;
                    if (out[15:12] != 4'd9) begin
                        out[15:12] = out[15:12] + 4'd1;
                    end else begin
                        out[15:12] = 4'd0;
                        if (out[19:16] != 4'd9) begin
                            out[19:16] = out[19:16] + 4'd1;
                        end else begin
                            out[19:16] = 4'd0;
                            if (out[23:20] != 4'd9) begin
                                out[23:20] = out[23:20] + 4'd1;
                            end else begin
                                out[23:20] = 4'd0;
                                if (out[27:24] != 4'd9) begin
                                    out[27:24] = out[27:24] + 4'd1;
                                end else begin
                                    out[27:24] = 4'd0;
                                    if (out[31:28] != 4'd9)
                                        out[31:28] = out[31:28] + 4'd1;
                                    else
                                        out[31:28] = 4'd0;
                                end
                            end
                        end
                    end
                end
            end
        end
        bcd_inc8 = out;
    end
endfunction

always_comb begin
    rx_sps_bcd_next = sys_iq_valid ? bcd_inc8(rx_sps_bcd_accum) : rx_sps_bcd_accum;
end

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        rx_sps_clk_count <= '0;
        rx_sps_bcd_accum <= '0;
        rx_sps_bcd <= '0;
    end else if (rx_sps_clk_count == RX_SPS_CLK_W'(CLK_HZ - 1)) begin
        rx_sps_clk_count <= '0;
        rx_sps_bcd_accum <= '0;
        rx_sps_bcd <= rx_sps_bcd_next;
    end else begin
        rx_sps_clk_count <= rx_sps_clk_count + 1'b1;
        rx_sps_bcd_accum <= rx_sps_bcd_next;
    end
end

always_comb begin
    if (bin_magnitude[7:4] != 4'b0000)
        wf_wr_magnitude = 8'hff;
    else
        wf_wr_magnitude = {bin_magnitude[3:0], 4'b0000};
end

assign wf_frame_active = (bin_index == 8'd0) ? (wf_frame_skip == 5'd0) : wf_frame_write;
assign wf_wr_valid = bin_valid && wf_frame_active;

always_ff @(posedge CLK) begin
    if (sys_rst) begin
        wf_frame_write <= 1'b0;
        wf_frame_skip <= 5'd0;
    end else if (bin_valid) begin
        if (bin_index == 8'd0)
            wf_frame_write <= (wf_frame_skip == 5'd0);

        if (bin_index == 8'd255) begin
            if (wf_frame_skip == WF_FRAME_DECIM)
                wf_frame_skip <= 5'd0;
            else
                wf_frame_skip <= wf_frame_skip + 5'd1;
        end
    end
end

// Waterfall buffer
logic [7:0] wf_bin_req;
logic [8:0] wf_row_age_req;
logic [7:0] wf_magnitude;
logic [8:0] wf_write_row;

waterfall_buf #(.BINS(256), .ROWS(360)) u_wf (
    .clk (CLK),
    .wr_magnitude (wf_wr_magnitude),
    .wr_valid (wf_wr_valid),
    .rd_bin (wf_bin_req),
    .rd_row_age (wf_row_age_req),
    .rd_magnitude (wf_magnitude),
    .write_row (wf_write_row)
);

// FM test source
function automatic logic signed [15:0] fm_test_sin32(input logic [4:0] phase);
    begin
        case (phase)
            5'd0:  fm_test_sin32 = 16'sd0;
            5'd1:  fm_test_sin32 = 16'sd3902;
            5'd2:  fm_test_sin32 = 16'sd7654;
            5'd3:  fm_test_sin32 = 16'sd11111;
            5'd4:  fm_test_sin32 = 16'sd14142;
            5'd5:  fm_test_sin32 = 16'sd16629;
            5'd6:  fm_test_sin32 = 16'sd18478;
            5'd7:  fm_test_sin32 = 16'sd19616;
            5'd8:  fm_test_sin32 = 16'sd20000;
            5'd9:  fm_test_sin32 = 16'sd19616;
            5'd10: fm_test_sin32 = 16'sd18478;
            5'd11: fm_test_sin32 = 16'sd16629;
            5'd12: fm_test_sin32 = 16'sd14142;
            5'd13: fm_test_sin32 = 16'sd11111;
            5'd14: fm_test_sin32 = 16'sd7654;
            5'd15: fm_test_sin32 = 16'sd3902;
            5'd16: fm_test_sin32 = 16'sd0;
            5'd17: fm_test_sin32 = -16'sd3902;
            5'd18: fm_test_sin32 = -16'sd7654;
            5'd19: fm_test_sin32 = -16'sd11111;
            5'd20: fm_test_sin32 = -16'sd14142;
            5'd21: fm_test_sin32 = -16'sd16629;
            5'd22: fm_test_sin32 = -16'sd18478;
            5'd23: fm_test_sin32 = -16'sd19616;
            5'd24: fm_test_sin32 = -16'sd20000;
            5'd25: fm_test_sin32 = -16'sd19616;
            5'd26: fm_test_sin32 = -16'sd18478;
            5'd27: fm_test_sin32 = -16'sd16629;
            5'd28: fm_test_sin32 = -16'sd14142;
            5'd29: fm_test_sin32 = -16'sd11111;
            5'd30: fm_test_sin32 = -16'sd7654;
            default: fm_test_sin32 = -16'sd3902;
        endcase
    end
endfunction

function automatic logic signed [7:0] fm_test_step32(input logic [4:0] phase);
    begin
        case (phase)
            5'd0:  fm_test_step32 = 8'sd0;
            5'd1:  fm_test_step32 = 8'sd1;
            5'd2:  fm_test_step32 = 8'sd2;
            5'd3:  fm_test_step32 = 8'sd3;
            5'd4:  fm_test_step32 = 8'sd4;
            5'd5:  fm_test_step32 = 8'sd5;
            5'd6:  fm_test_step32 = 8'sd6;
            5'd7:  fm_test_step32 = 8'sd6;
            5'd8:  fm_test_step32 = 8'sd6;
            5'd9:  fm_test_step32 = 8'sd6;
            5'd10: fm_test_step32 = 8'sd6;
            5'd11: fm_test_step32 = 8'sd5;
            5'd12: fm_test_step32 = 8'sd4;
            5'd13: fm_test_step32 = 8'sd3;
            5'd14: fm_test_step32 = 8'sd2;
            5'd15: fm_test_step32 = 8'sd1;
            5'd16: fm_test_step32 = 8'sd0;
            5'd17: fm_test_step32 = -8'sd1;
            5'd18: fm_test_step32 = -8'sd2;
            5'd19: fm_test_step32 = -8'sd3;
            5'd20: fm_test_step32 = -8'sd4;
            5'd21: fm_test_step32 = -8'sd5;
            5'd22: fm_test_step32 = -8'sd6;
            5'd23: fm_test_step32 = -8'sd6;
            5'd24: fm_test_step32 = -8'sd6;
            5'd25: fm_test_step32 = -8'sd6;
            5'd26: fm_test_step32 = -8'sd6;
            5'd27: fm_test_step32 = -8'sd5;
            5'd28: fm_test_step32 = -8'sd4;
            5'd29: fm_test_step32 = -8'sd3;
            5'd30: fm_test_step32 = -8'sd2;
            default: fm_test_step32 = -8'sd1;
        endcase
    end
endfunction

logic signed [15:0] cic_in_i, cic_in_q;
logic cic_in_valid;
logic signed [15:0] fm_test_i, fm_test_q;
logic fm_test_valid;
logic [4:0] fm_test_clk_cnt;
logic [4:0] fm_test_audio_cnt;
logic [4:0] fm_test_audio_phase;
logic [7:0] fm_test_phase;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        fm_test_i <= '0;
        fm_test_q <= '0;
        fm_test_valid <= 1'b0;
        fm_test_clk_cnt <= 5'd0;
        fm_test_audio_cnt <= 5'd0;
        fm_test_audio_phase <= 5'd0;
        fm_test_phase <= 8'd0;
    end else begin
        fm_test_valid <= 1'b0;

        if (fm_test_clk_cnt == 5'd24) begin
            fm_test_clk_cnt <= 5'd0;
            fm_test_valid <= 1'b1;
            fm_test_i <= fm_test_sin32(fm_test_phase[7:3] + 5'd8);
            fm_test_q <= fm_test_sin32(fm_test_phase[7:3]);
            fm_test_phase <= fm_test_phase + fm_test_step32(fm_test_audio_phase);

            if (fm_test_audio_cnt == 5'd30) begin
                fm_test_audio_cnt <= 5'd0;
                fm_test_audio_phase <= fm_test_audio_phase + 5'd1;
            end else begin
                fm_test_audio_cnt <= fm_test_audio_cnt + 5'd1;
            end
        end else begin
            fm_test_clk_cnt <= fm_test_clk_cnt + 5'd1;
        end
    end
end

assign cic_in_i = FM_CHAIN_TEST ? fm_test_i : sys_i;
assign cic_in_q = FM_CHAIN_TEST ? fm_test_q : sys_q;
assign cic_in_valid = FM_CHAIN_TEST ? fm_test_valid : sys_iq_valid;

// CIC decimator
logic signed [15:0] dec_i, dec_q;
logic dec_valid;

cic_decimate #(.IN_W(16), .R(FM_CIC_R), .STAGES(3)) u_cic (
    .clk (CLK),
    .rst (sys_rst),
    .in_i (cic_in_i),
    .in_q (cic_in_q),
    .in_valid (cic_in_valid),
    .out_i (dec_i),
    .out_q (dec_q),
    .out_valid (dec_valid)
);

// FM demodulator
logic signed [7:0] audio_sample;
logic audio_valid;

fm_demod u_fm (
    .clk (CLK),
    .rst (sys_rst),
    .i_in (dec_i),
    .q_in (dec_q),
    .in_valid (dec_valid),
    .audio_out (audio_sample),
    .audio_valid (audio_valid)
);

// I2S audio
logic signed [15:0] audio_sample_16;
logic signed [15:0] audio_to_i2s;
logic signed [15:0] tone_sample;
logic [4:0] tone_phase;
logic i2s_sample_req;

audio_volume u_audio_volume (
    .audio_in (audio_sample),
    .volume (volume),
    .mute (mute),
    .enable (fm_active),
    .audio_out (audio_sample_16)
);

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

assign audio_to_i2s = AUDIO_TEST_TONE ? tone_sample : audio_sample_16;

i2s_tx u_i2s (
    .clk (CLK),
    .rst (sys_rst),
    .left_in (audio_to_i2s),
    .right_in (audio_to_i2s),
    .sample_req (i2s_sample_req),
    .bclk (i2s_bclk),
    .lrclk (i2s_lrclk),
    .sdata (i2s_sdata)
);

// LCD controller
lcd u_lcd (
    .rst (sys_rst),
    .pclk (CLK),
    .mode (mode),
    .volume (volume),
    .mute (mute),
    .dbg_rx_count (dbg_rx_count),
    .dbg_bin_count (dbg_bin_count),
    .dbg_last_mag (dbg_last_mag),
    .rx_sps_bcd (rx_sps_bcd),
    .wf_magnitude (wf_magnitude),
    .wf_bin (wf_bin_req),
    .wf_row_age (wf_row_age_req),
    .LCD_DE (LCD_DEN),
    .LCD_R (LCD_R),
    .LCD_G (LCD_G),
    .LCD_B (LCD_B)
);

assign LCD_CLK = CLK;

endmodule
