module top #(
    parameter FM_CIC_R = 8,
    parameter IQ_SAMPLE_RATE = 260_417,
    parameter IQ_FIFO_DEPTH = 8192,
    parameter IQ_PREROLL_SAMPLES = 4096,
    parameter BYTE_FIFO_DEPTH = 4096,
    parameter I2S_AUDIO_RATE = 32_552,
    parameter I2S_BCLK_HALF_CYCLES = 6,
    parameter AUDIO_WARMUP_SAMPLES = 512,
    parameter CLK_HZ = 25_000_000
)(
    input logic CLK,

    input logic spi_clk,
    input logic cs,
    input logic mosi,
    output logic miso,

    input logic spi_clk_pico,
    input logic cs1,
    input logic mosi_pico,

    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_sdata,
    output logic i2s_sck,

    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B,

    output logic sdram_clk,
    output logic sdram_cke,
    output logic sdram_cs_n,
    output logic sdram_ras_n,
    output logic sdram_cas_n,
    output logic sdram_we_n,
    output logic [1:0] sdram_ba,
    output logic [12:0] sdram_a,
    output logic [1:0] sdram_dm,
    inout wire [15:0] sdram_dq
);

assign i2s_sck = 1'b0;

logic clk_pix;
logic clk_sdram;
logic pll_locked;

`ifdef SIMULATION
assign clk_sdram = CLK;
assign clk_pix = CLK;
assign pll_locked = 1'b1;
`else
EHXPLLL #(
    .PLLRST_ENA("DISABLED"),
    .INTFB_WAKE("DISABLED"),
    .STDBY_ENABLE("DISABLED"),
    .DPHASE_SOURCE("DISABLED"),
    .OUTDIVIDER_MUXA("DIVA"),
    .OUTDIVIDER_MUXB("DIVB"),
    .OUTDIVIDER_MUXC("DIVC"),
    .OUTDIVIDER_MUXD("DIVD"),
    .CLKI_DIV(1),
    .CLKOP_ENABLE("ENABLED"),
    .CLKOP_DIV(6),
    .CLKOP_CPHASE(0),
    .CLKOP_FPHASE(0),
    .CLKOS_ENABLE("ENABLED"),
    .CLKOS_DIV(20),
    .CLKOS_CPHASE(0),
    .CLKOS_FPHASE(0),
    .CLKOS2_ENABLE("DISABLED"),
    .CLKOS2_DIV(6),
    .CLKOS2_CPHASE(3),
    .CLKOS2_FPHASE(4),
    .CLKOS3_ENABLE("DISABLED"),
    .CLKOS3_DIV(1),
    .CLKOS3_CPHASE(0),
    .CLKOS3_FPHASE(0),
    .FEEDBK_PATH("CLKOP"),
    .CLKFB_DIV(4)
) u_pll (
    .CLKI(CLK),
    .CLKFB(clk_sdram),
    .CLKOP(clk_sdram),
    .CLKOS(clk_pix),
    .CLKOS2(),
    .CLKOS3(),
    .RST(1'b0),
    .STDBY(1'b0),
    .PHASESEL0(1'b0),
    .PHASESEL1(1'b0),
    .PHASEDIR(1'b0),
    .PHASESTEP(1'b0),
    .PLLWAKESYNC(1'b0),
    .ENCLKOP(1'b0),
    .ENCLKOS(1'b0),
    .ENCLKOS2(1'b0),
    .ENCLKOS3(1'b0),
    .LOCK(pll_locked)
);
`endif

// Reset
logic [3:0] sys_rst_cnt = 4'd0;
logic sys_rst = 1'b1;

always_ff @(posedge CLK) begin
    if (!pll_locked) begin
        sys_rst_cnt <= 4'd0;
        sys_rst <= 1'b1;
    end else if (!sys_rst_cnt[3]) begin
        sys_rst_cnt <= sys_rst_cnt + 4'd1;
        sys_rst <= 1'b1;
    end else begin
        sys_rst <= 1'b0;
    end
end

logic [7:0] sdram_rst_cnt = 8'd0;
logic sdram_rst = 1'b1;

always_ff @(posedge clk_sdram) begin
    if (!pll_locked) begin
        sdram_rst_cnt <= 8'd0;
        sdram_rst <= 1'b1;
    end else if (!sdram_rst_cnt[7]) begin
        sdram_rst_cnt <= sdram_rst_cnt + 8'd1;
        sdram_rst <= 1'b1;
    end else begin
        sdram_rst <= 1'b0;
    end
end

logic [7:0] pix_rst_cnt = 8'd0;
logic pix_rst = 1'b1;

always_ff @(posedge clk_pix) begin
    if (!pll_locked) begin
        pix_rst_cnt <= 8'd0;
        pix_rst <= 1'b1;
    end else if (!pix_rst_cnt[7]) begin
        pix_rst_cnt <= pix_rst_cnt + 8'd1;
        pix_rst <= 1'b1;
    end else begin
        pix_rst <= 1'b0;
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

logic cmd_valid;
logic [7:0] cmd;
logic [31:0] cmd_arg;

spi_ui_cmd_rx u_spi_cmd (
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
logic [31:0] freq_hz;
logic mute;
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

spi_backchannel u_spi_backchannel (
    .clk (CLK),
    .rst (sys_rst),
    .cmd_valid (cmd_valid),
    .cmd (cmd),
    .arg (cmd_arg),
    .mode (mode),
    .volume (volume),
    .mute (mute),
    .freq_hz (freq_hz),
    .spi_clk (spi_clk),
    .spi_rst (spi_rst),
    .spi_cs_n (cs),
    .spi_miso (miso)
);

logic [1:0] ui_layout;
logic [1:0] ui_demod;
logic [7:0] ui_volume;
logic [31:0] ui_freq_hz;
logic [15:0] span_hz_log2;
logic [7:0] ui_flags;
logic [9:0] touch_x;
logic [9:0] touch_y;
logic [7:0] active_button;
logic [191:0] rds_line_pico;
logic ui_frame_valid;

ui_wire_rx u_ui_wire_rx (
    .spi_clk (spi_clk_pico),
    .spi_cs_n(cs1),
    .spi_mosi(mosi_pico),
    .clk (CLK),
    .rst (sys_rst),
    .layout(ui_layout),
    .demod(ui_demod),
    .volume (ui_volume),
    .freq_hz(ui_freq_hz),
    .span_hz_log2(span_hz_log2),
    .flags(ui_flags),
    .touch_x(touch_x),
    .touch_y(touch_y),
    .active_button(active_button),
    .rds_line(rds_line_pico),
    .frame_valid(ui_frame_valid)
);

logic [31:0] fifo_rdata;
logic fifo_empty, fifo_full;
logic fifo_pop;
logic fifo_pop_d;
logic iq_sample_tick;
logic [31:0] iq_rate_acc;
logic iq_started;
logic [$clog2(IQ_PREROLL_SAMPLES+1)-1:0] iq_preroll_cnt;

logic [31:0] iqsrc_wdata;
logic iqsrc_wpush;

logic fr_valid, fr_sof;
logic [7:0] fr_byte;

spi_frame_rx u_frame_rx (
    .spi_clk (spi_clk),
    .spi_cs_n (cs),
    .spi_mosi (mosi),
    .byte_valid(fr_valid),
    .byte_sof (fr_sof),
    .byte_data (fr_byte)
);

logic [8:0] byte_rdata;
logic byte_empty, byte_full;
logic byte_pop, byte_pop_d;

async_fifo #(.WIDTH(9), .DEPTH(BYTE_FIFO_DEPTH)) u_byte_fifo (
    .wclk (spi_clk),
    .wrst (spi_rst),
    .wdata ({fr_sof, fr_byte}),
    .wpush (fr_valid & ~byte_full & ~spi_rst),
    .wfull (byte_full),
    .rclk (CLK),
    .rrst (sys_rst),
    .rdata (byte_rdata),
    .rpop (byte_pop),
    .rempty(byte_empty)
);

assign byte_pop = ~byte_empty;
always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) byte_pop_d <= 1'b0;
    else byte_pop_d <= byte_pop;
end

logic pl_valid, pl_sop, pl_eop;
logic [7:0] pl_byte, pl_type;

tlv_demux u_demux (
    .clk (CLK),
    .rst (sys_rst),
    .in_valid (byte_pop_d),
    .in_sof (byte_rdata[8]),
    .in_byte (byte_rdata[7:0]),
    .pl_valid (pl_valid),
    .pl_sop (pl_sop),
    .pl_eop (pl_eop),
    .pl_byte (pl_byte),
    .pl_type (pl_type),
    .iq_pkt_count (),
    .img_pkt_count(),
    .obj_pkt_count(),
    .unknown_count(),
    .short_count (),
    .stray_count (),
    .last_type ()
);

logic signed [15:0] tlv_i, tlv_q;
logic tlv_iq_word_valid;

tlv_iq_sink u_iq_sink (
    .clk (CLK),
    .rst (sys_rst),
    .pl_valid (pl_valid),
    .pl_sop (pl_sop),
    .pl_eop (pl_eop),
    .pl_byte (pl_byte),
    .pl_type (pl_type),
    .i_data (tlv_i),
    .q_data (tlv_q),
    .iq_word_valid(tlv_iq_word_valid)
);

assign iqsrc_wdata = {tlv_i, tlv_q};
assign iqsrc_wpush = tlv_iq_word_valid & ~fifo_full;

async_fifo #(.WIDTH(32), .DEPTH(IQ_FIFO_DEPTH)) u_iq_fifo (
    .wclk (CLK),
    .wrst (sys_rst),
    .wdata (iqsrc_wdata),
    .wpush (iqsrc_wpush),
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

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        iq_started <= 1'b0;
        iq_preroll_cnt <= '0;
    end else if (!iq_started && !fifo_empty && iq_sample_tick) begin
        if (iq_preroll_cnt == IQ_PREROLL_SAMPLES[$bits(iq_preroll_cnt)-1:0])
            iq_started <= 1'b1;
        else
            iq_preroll_cnt <= iq_preroll_cnt + 1'b1;
    end
end

assign fifo_pop = iq_started && iq_sample_tick && ~fifo_empty;

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
logic signed [15:0] fft_i;
logic signed [15:0] fft_q;
logic fft_valid;

localparam [4:0] WF_FRAME_DECIM = 5'd31;
localparam int FFT_DC_SHIFT = 11;

logic signed [23:0] fft_dc_i;
logic signed [23:0] fft_dc_q;
logic signed [16:0] fft_i_hp_wide;
logic signed [16:0] fft_q_hp_wide;
logic signed [15:0] fft_i_in;
logic signed [15:0] fft_q_in;

function automatic logic signed [15:0] sat17_to_16(input logic signed [16:0] x);
    begin
        if (x > 17'sd32767)
            sat17_to_16 = 16'sd32767;
        else if (x < -17'sd32768)
            sat17_to_16 = -16'sd32768;
        else
            sat17_to_16 = x[15:0];
    end
endfunction

spectrum_zoom_decimator u_spectrum_zoom_decimator (
    .clk(CLK),
    .rst(sys_rst),
    .in_i(sys_i),
    .in_q(sys_q),
    .in_valid(sys_iq_valid),
    .span_hz_log2(span_hz_log2),
    .out_i(fft_i),
    .out_q(fft_q),
    .out_valid(fft_valid),
    .decim_log2()
);

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        fft_dc_i <= '0;
        fft_dc_q <= '0;
    end else if (fft_valid) begin
        fft_dc_i <= fft_dc_i + (({{8{fft_i[15]}}, fft_i} - fft_dc_i) >>> FFT_DC_SHIFT);
        fft_dc_q <= fft_dc_q + (({{8{fft_q[15]}}, fft_q} - fft_dc_q) >>> FFT_DC_SHIFT);
    end
end

always_comb begin
    fft_i_hp_wide = $signed({fft_i[15], fft_i}) - $signed(fft_dc_i[16:0]);
    fft_q_hp_wide = $signed({fft_q[15], fft_q}) - $signed(fft_dc_q[16:0]);
    fft_i_in = sat17_to_16(fft_i_hp_wide);
    fft_q_in = sat17_to_16(fft_q_hp_wide);
end

fft256 u_fft (
    .clk (CLK),
    .rst (sys_rst),
    .i_in (fft_i_in),
    .q_in (fft_q_in),
    .in_valid (fft_valid),
    .bin_magnitude (bin_magnitude),
    .bin_index (bin_index),
    .bin_valid (bin_valid)
);

always_comb begin
    unique case (bin_index)
        8'd0: wf_wr_magnitude = {1'b0, bin_magnitude[7:1]};
        8'd1,
        8'd255: wf_wr_magnitude = {1'b0, bin_magnitude[7:1]};
        default: wf_wr_magnitude = bin_magnitude;
    endcase
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

localparam int LCD_H_ACTIVE = 800;
localparam int LCD_H_TOTAL = 928;
localparam int LCD_V_ACTIVE = 480;
localparam int LCD_V_TOTAL = 525;
localparam int WF_LINE_WORDS = 800;

logic clr_done;
logic [7:0] wf_bins [0:255];
logic [9:0] wf_exp_col;
logic wf_exp_active;
logic [23:0] wf_exp_phase;
logic [15:0] wf_exp_mul_const;
logic [7:0] wf_exp_display_bin;
logic [7:0] wf_exp_bin_off;
logic [8:0] wf_exp_bin_sum;
logic [7:0] wf_exp_idx;
logic [7:0] wf_exp_wdata;
logic wf_exp_wpush;
logic [7:0] wf_exp_start_bin;
logic [8:0] wf_exp_visible_bins;
logic wf_mag_wfull;

logic [7:0] shader_spectrum_start_bin;
logic [8:0] shader_spectrum_visible_bins;

always_comb begin
    unique case (wf_exp_visible_bins)
        9'd128: wf_exp_mul_const = 16'd10486;
        9'd64: wf_exp_mul_const = 16'd5243;
        9'd32: wf_exp_mul_const = 16'd2622;
        9'd16: wf_exp_mul_const = 16'd1311;
        9'd8: wf_exp_mul_const = 16'd656;
        default: wf_exp_mul_const = 16'd20972;
    endcase
end

assign wf_exp_bin_off = wf_exp_phase[23:16];
assign wf_exp_bin_sum = {1'b0, wf_exp_start_bin} + {1'b0, wf_exp_bin_off};
assign wf_exp_display_bin = wf_exp_bin_sum[8] ? 8'hff : wf_exp_bin_sum[7:0];
assign wf_exp_idx = wf_exp_display_bin + 8'd128;
assign wf_exp_wdata = wf_bins[wf_exp_idx];
assign wf_exp_wpush = wf_exp_active && !wf_mag_wfull;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        wf_exp_col <= 10'd0;
        wf_exp_phase <= 24'd0;
        wf_exp_active <= 1'b0;
        wf_exp_start_bin <= 8'd64;
        wf_exp_visible_bins <= 9'd128;
    end else begin
        if (wf_wr_valid)
            wf_bins[bin_index] <= wf_wr_magnitude;

        if (!wf_exp_active && wf_wr_valid && bin_index == 8'd255) begin
            wf_exp_active <= 1'b1;
            wf_exp_col <= 10'd0;
            wf_exp_phase <= 24'd0;
            wf_exp_start_bin <= shader_spectrum_start_bin;
            wf_exp_visible_bins <= shader_spectrum_visible_bins;
        end else if (wf_exp_wpush) begin
            if (wf_exp_col == WF_LINE_WORDS[9:0] - 10'd1) begin
                wf_exp_active <= 1'b0;
                wf_exp_col <= 10'd0;
                wf_exp_phase <= 24'd0;
            end else begin
                wf_exp_col <= wf_exp_col + 10'd1;
                wf_exp_phase <= wf_exp_phase + {8'd0, wf_exp_mul_const};
            end
        end
    end
end

logic [7:0] wf_mag_rdata;
logic wf_mag_rpop;
logic wf_mag_rempty;

async_fifo #(.WIDTH(8), .DEPTH(1024)) u_wf_mag_fifo (
    .wclk(CLK), .wrst(sys_rst), .wdata(wf_exp_wdata),
    .wpush(wf_exp_wpush), .wfull(wf_mag_wfull),
    .rclk(clk_sdram), .rrst(sdram_rst), .rdata(wf_mag_rdata),
    .rpop(wf_mag_rpop), .rempty(wf_mag_rempty)
);

logic [7:0] comp_mag_in;
logic comp_mag_valid;
logic comp_busy;
typedef enum logic [0:0] { WF_FEED, WF_WAIT } wf_feed_state_e;
wf_feed_state_e wf_feed_state;
logic [10:0] wf_feed_cnt;
logic wf_feed_pending;

assign wf_mag_rpop = !sdram_rst && clr_done && (wf_feed_state == WF_FEED) &&
                     (wf_feed_cnt < WF_LINE_WORDS[10:0]) &&
                     !wf_feed_pending && !wf_mag_rempty;

always_ff @(posedge clk_sdram) begin
    if (sdram_rst | ~clr_done) begin
        wf_feed_state <= WF_FEED;
        wf_feed_cnt <= 11'd0;
        wf_feed_pending <= 1'b0;
        comp_mag_valid <= 1'b0;
        comp_mag_in <= 8'd0;
    end else begin
        comp_mag_valid <= 1'b0;
        case (wf_feed_state)
            WF_FEED: begin
                if (wf_feed_cnt == WF_LINE_WORDS[10:0]) begin
                    wf_feed_state <= WF_WAIT;
                end else if (wf_feed_pending) begin
                    comp_mag_in <= wf_mag_rdata;
                    comp_mag_valid <= 1'b1;
                    wf_feed_cnt <= wf_feed_cnt + 11'd1;
                    wf_feed_pending <= 1'b0;
                end else if (!wf_mag_rempty) begin
                    wf_feed_pending <= 1'b1;
                end
            end
            WF_WAIT: begin
                if (!comp_busy) begin
                    wf_feed_cnt <= 11'd0;
                    wf_feed_state <= WF_FEED;
                end
            end
        endcase
    end
end

localparam int FM_IQ_RSHIFT = 3;
logic signed [15:0] fm_i_scaled, fm_q_scaled;
assign fm_i_scaled = sys_i >>> FM_IQ_RSHIFT;
assign fm_q_scaled = sys_q >>> FM_IQ_RSHIFT;

logic signed [15:0] audio_raw;
logic audio_raw_valid;

fm_demod u_fm (
    .clk (CLK),
    .rst (sys_rst),
    .i_in (fm_i_scaled),
    .q_in (fm_q_scaled),
    .in_valid (sys_iq_valid),
    .audio_out (audio_raw),
    .audio_valid (audio_raw_valid),
    .mpx_out (),
    .mpx_valid ()
);

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
logic signed [AUD_W-1:0] aud_comb [0:AUD_STAGES-1];
logic signed [AUD_W-1:0] aud_prev [0:AUD_STAGES-1];
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
                if (aud_scaled > AUD_MAX) audio_sample <= 16'sd32767;
                else if (aud_scaled < AUD_MIN) audio_sample <= -16'sd32768;
                else audio_sample <= aud_scaled[15:0];
                audio_valid <= 1'b1;
            end
            aud_dec_cnt <= aud_dec_cnt + 1'b1;
        end
    end
end

logic signed [15:0] audio_sample_16;
logic i2s_sample_req;
logic audio_warm;
logic [$clog2(AUDIO_WARMUP_SAMPLES+1)-1:0] audio_warm_cnt;

audio_volume u_audio_volume (
    .audio_in (audio_sample),
    .volume (volume),
    .mute (mute),
    .enable (fm_active),
    .audio_out (audio_sample_16)
);

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        audio_warm <= 1'b0;
        audio_warm_cnt <= '0;
    end else if (audio_valid && fm_active && !audio_warm) begin
        if (audio_warm_cnt == AUDIO_WARMUP_SAMPLES[$bits(audio_warm_cnt)-1:0])
            audio_warm <= 1'b1;
        else
            audio_warm_cnt <= audio_warm_cnt + 1'b1;
    end
end

localparam int AFIFO_DEPTH = 64;

logic [15:0] afifo_rdata;
logic afifo_empty, afifo_full;
logic [$clog2(AFIFO_DEPTH):0] afifo_count;
logic [1:0] afifo_pop_n;
logic [15:0] audio_held;
logic i2s_sample_req_d;
wire sample_req_edge = i2s_sample_req & ~i2s_sample_req_d;
logic audio_started;

audio_fifo #(.WIDTH(16), .DEPTH(AFIFO_DEPTH)) u_afifo (
    .clk (CLK),
    .rst (sys_rst),
    .wdata (audio_sample_16),
    .wpush (audio_valid & fm_active & audio_warm & ~afifo_full),
    .full (afifo_full),
    .rdata (afifo_rdata),
    .rpop_n (afifo_pop_n),
    .empty (afifo_empty),
    .count (afifo_count)
);

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) i2s_sample_req_d <= 1'b0;
    else i2s_sample_req_d <= i2s_sample_req;
end

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst)
        audio_started <= 1'b0;
    else if (afifo_count >= (AFIFO_DEPTH / 2))
        audio_started <= 1'b1;
end

assign afifo_pop_n = (audio_started && sample_req_edge && !afifo_empty) ? 2'd1 : 2'd0;

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) audio_held <= '0;
    else if (~afifo_empty) audio_held <= afifo_rdata;
end

wire signed [15:0] audio_play = (!audio_started || afifo_empty) ? audio_held : afifo_rdata;

i2s_tx #(
    .AUDIO_RATE(I2S_AUDIO_RATE),
    .CLK_HZ(CLK_HZ),
    .BCLK_HALF_CYCLES(I2S_BCLK_HALF_CYCLES)
) u_i2s (
    .clk (CLK),
    .rst (sys_rst),
    .left_in (audio_play),
    .right_in (audio_play),
    .sample_req (i2s_sample_req),
    .bclk (i2s_bclk),
    .lrclk (i2s_lrclk),
    .sdata (i2s_sdata)
);

logic m_req_valid, m_req_wr, m_req_ready, m_wr_valid, m_wr_ready, m_rd_valid, m_done;
logic [24:0] m_req_addr;
logic [9:0] m_req_len;
logic [15:0] m_wr_data, m_rd_data;
logic [15:0] dq_out, dq_in;
logic dq_oe;

sdram_ctrl #(.TREF_PERIOD(780), .RD_LAT(3)) u_sdram_ctrl (
    .clk(clk_sdram), .rst(sdram_rst),
    .req_valid(m_req_valid), .req_wr(m_req_wr), .req_addr(m_req_addr), .req_len(m_req_len),
    .req_ready(m_req_ready),
    .wr_data(m_wr_data), .wr_valid(m_wr_valid), .wr_ready(m_wr_ready),
    .rd_data(m_rd_data), .rd_valid(m_rd_valid), .done(m_done),
    .sdram_clk(),
    .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
    .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in), .sdram_dm(sdram_dm)
);

assign sdram_dq = dq_oe ? dq_out : 16'hzzzz;

logic [15:0] cap0;
always_ff @(posedge clk_sdram) cap0 <= sdram_dq;
assign dq_in = cap0;
assign sdram_clk = clk_sdram;

logic [2:0] c_req_valid, c_req_wr, c_req_ready, c_wr_valid, c_wr_ready, c_rd_valid, c_done;
logic [3*25-1:0] c_req_addr;
logic [3*10-1:0] c_req_len;
logic [3*16-1:0] c_wr_data, c_rd_data;

sdram_arb #(.N(3)) u_sdram_arb (
    .clk(clk_sdram), .rst(sdram_rst),
    .c_req_valid(c_req_valid), .c_req_wr(c_req_wr), .c_req_addr(c_req_addr), .c_req_len(c_req_len),
    .c_req_ready(c_req_ready), .c_wr_data(c_wr_data), .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready),
    .c_rd_data(c_rd_data), .c_rd_valid(c_rd_valid), .c_done(c_done),
    .m_req_valid(m_req_valid), .m_req_wr(m_req_wr), .m_req_addr(m_req_addr), .m_req_len(m_req_len),
    .m_req_ready(m_req_ready), .m_wr_data(m_wr_data), .m_wr_valid(m_wr_valid), .m_wr_ready(m_wr_ready),
    .m_rd_data(m_rd_data), .m_rd_valid(m_rd_valid), .m_done(m_done),
    .gnt_valid(), .gnt()
);

logic [10:0] scan_x;
logic [9:0] scan_y;
logic scan_de;

scan_timing #(.H_ACTIVE(LCD_H_ACTIVE), .H_TOTAL(LCD_H_TOTAL), .V_ACTIVE(LCD_V_ACTIVE), .V_TOTAL(LCD_V_TOTAL))
u_scan_timing (
    .pclk(clk_pix),
    .rst(pix_rst),
    .x(scan_x),
    .y(scan_y),
    .de(scan_de)
);

logic vb1, vb2, vb3;
logic [8:0] wf_base_row;
logic [8:0] wf_base_frame;
wire vblank_pix = (scan_y >= LCD_V_ACTIVE[9:0]);
always_ff @(posedge clk_sdram) begin
    vb1 <= vblank_pix;
    vb2 <= vb1;
    vb3 <= vb2;
end
wire vb_rise = vb2 & ~vb3;
always_ff @(posedge clk_sdram) begin
    if (sdram_rst) wf_base_frame <= 9'd0;
    else if (vb_rise) wf_base_frame <= wf_base_row;
end

logic so_req_valid;
logic [24:0] so_req_addr;
logic [9:0] so_req_len;
logic [1:0] lc_w_slot;
logic [9:0] lc_w_col;
logic [15:0] lc_w_data;
logic lc_w_en;

scan_out #(.LINE_WORDS(WF_LINE_WORDS), .NLINES(LCD_V_ACTIVE), .VISIBLE_Y0(192), .MAX_BURST(256), .HALF_PAGE(1)) u_scan_out (
    .clk(clk_sdram), .rst(sdram_rst | ~clr_done),
    .px_line(scan_y[8:0]),
    .px_hblank((scan_x >= LCD_H_ACTIVE[10:0]) && (scan_y < LCD_V_ACTIVE[9:0])),
    .wf_base_row(wf_base_frame),
    .req_valid(so_req_valid), .req_addr(so_req_addr), .req_len(so_req_len),
    .req_ready(c_req_ready[0]), .rd_data(c_rd_data[15:0]), .rd_valid(c_rd_valid[0]), .done(c_done[0]),
    .w_slot(lc_w_slot), .w_col(lc_w_col), .w_data(lc_w_data), .w_en(lc_w_en), .busy()
);

assign c_req_valid[0] = so_req_valid;
assign c_req_wr[0] = 1'b0;
assign c_req_addr[0*25 +:25] = so_req_addr;
assign c_req_len[0*10 +:10] = so_req_len;
assign c_wr_data[0*16 +:16] = 16'd0;
assign c_wr_valid[0] = 1'b0;

logic comp_req_valid, comp_req_wr, comp_wr_valid;
logic [24:0] comp_req_addr;
logic [9:0] comp_req_len;
logic [15:0] comp_wr_data;

compositor #(.ROW_WORDS(WF_LINE_WORDS), .NLINES(LCD_V_ACTIVE), .VISIBLE_Y0(192), .MAX_BURST(256), .HALF_PAGE(1)) u_compositor (
    .clk(clk_sdram), .rst(sdram_rst | ~clr_done),
    .mag_in(comp_mag_in), .mag_valid(comp_mag_valid), .wf_base_row(wf_base_row),
    .req_valid(comp_req_valid), .req_wr(comp_req_wr), .req_addr(comp_req_addr), .req_len(comp_req_len),
    .req_ready(c_req_ready[1]), .wr_data(comp_wr_data), .wr_valid(comp_wr_valid), .wr_ready(c_wr_ready[1]),
    .done(c_done[1]), .busy(comp_busy)
);

assign c_req_valid[1] = comp_req_valid;
assign c_req_wr[1] = comp_req_wr;
assign c_req_addr[1*25 +:25] = comp_req_addr;
assign c_req_len[1*10 +:10] = comp_req_len;
assign c_wr_data[1*16 +:16] = comp_wr_data;
assign c_wr_valid[1] = comp_wr_valid;

logic clr_req_valid, clr_wr_valid;
logic [18:0] clr_word;
logic [10:0] clr_left;
logic [8:0] clr_line;
logic [9:0] clr_beats;
typedef enum logic [1:0] { CL_REQ, CL_WRITE, CL_WAIT, CL_DONE } cl_state_e;
cl_state_e cl_state;
wire [9:0] clr_col = 10'(clr_word % 256);
wire [10:0] clr_rem = 11'd256 - {1'b0, clr_col};
wire [10:0] clr_seg = (clr_rem < clr_left) ? clr_rem : clr_left;
logic [10:0] clr_seg_r;
always_ff @(posedge clk_sdram) clr_seg_r <= clr_seg;

always_ff @(posedge clk_sdram) begin
    if (sdram_rst) begin
        cl_state <= CL_REQ;
        clr_word <= 19'd0;
        clr_left <= WF_LINE_WORDS[10:0];
        clr_line <= 9'd0;
        clr_beats <= 10'd0;
        clr_req_valid <= 1'b0;
        clr_wr_valid <= 1'b0;
        clr_done <= 1'b0;
    end else begin
        case (cl_state)
            CL_REQ: begin
                clr_req_valid <= 1'b1;
                clr_beats <= 10'd0;
                if (clr_req_valid && c_req_ready[2]) begin
                    clr_req_valid <= 1'b0;
                    clr_wr_valid <= 1'b1;
                    cl_state <= CL_WRITE;
                end
            end
            CL_WRITE: begin
                clr_wr_valid <= 1'b1;
                if (c_wr_ready[2] && clr_wr_valid) begin
                    if (clr_beats == clr_seg_r[9:0] - 10'd1) begin
                        clr_wr_valid <= 1'b0;
                        clr_word <= clr_word + 19'(clr_seg_r);
                        clr_left <= clr_left - clr_seg_r;
                        cl_state <= CL_WAIT;
                    end else begin
                        clr_beats <= clr_beats + 10'd1;
                    end
                end
            end
            CL_WAIT: begin
                if (c_done[2]) begin
                    if (clr_left != 11'd0) begin
                        cl_state <= CL_REQ;
                    end else if (clr_line == LCD_V_ACTIVE[8:0] - 9'd1) begin
                        cl_state <= CL_DONE;
                    end else begin
                        clr_line <= clr_line + 9'd1;
                        clr_left <= WF_LINE_WORDS[10:0];
                        cl_state <= CL_REQ;
                    end
                end
            end
            CL_DONE: begin
                clr_done <= 1'b1;
            end
            default: cl_state <= CL_REQ;
        endcase
    end
end

assign c_req_valid[2] = clr_req_valid;
assign c_req_wr[2] = 1'b1;
assign c_req_addr[2*25 +:25] = (25'(clr_word / 256) << 10) | (25'(clr_col) << 1);
assign c_req_len[2*10 +:10] = clr_seg_r[9:0];
assign c_wr_data[2*16 +:16] = 16'h0000;
assign c_wr_valid[2] = clr_wr_valid;

logic [15:0] fb_under;
line_cache u_line_cache (
    .wclk(clk_sdram), .w_slot(lc_w_slot), .w_col(lc_w_col), .w_data(lc_w_data), .w_en(lc_w_en),
    .rclk(clk_pix), .r_slot(scan_y[1:0]), .r_col((scan_x < LCD_H_ACTIVE[10:0]) ? scan_x[9:0] : 10'd0),
    .r_data(fb_under)
);

logic [9:0] shader_x;
logic [9:0] shader_y;
logic shader_de;
always_ff @(posedge clk_pix) begin
    shader_x <= scan_x[9:0];
    shader_y <= scan_y[9:0];
    shader_de <= scan_de;
end

logic [15:0] shader_pixel;
logic [95:0] shader_freq_text;
logic [159:0] shader_band_text;
logic [31:0] shader_demod_label;
logic [15:0] shader_mode_btn_label;
logic [15:0] shader_volume_fill;
logic [7:0] shader_mute_sprite_id;
logic [15:0] spec_wr_data;
logic spec_wr_en;

ui_status_prepare u_ui_status_prepare (
    .clk(CLK),
    .rst(sys_rst),
    .update(ui_frame_valid),
    .freq_hz(ui_freq_hz),
    .span_hz_log2(span_hz_log2),
    .demod(ui_demod),
    .volume(ui_volume),
    .flags(ui_flags),
    .freq_text(shader_freq_text),
    .band_text(shader_band_text),
    .demod_label(shader_demod_label),
    .mode_btn_label(shader_mode_btn_label),
    .volume_fill_px(shader_volume_fill),
    .mute_sprite_id(shader_mute_sprite_id),
    .spectrum_start_bin(shader_spectrum_start_bin),
    .spectrum_visible_bins(shader_spectrum_visible_bins)
);

assign spec_wr_data = {wf_wr_magnitude, 8'd0};
assign spec_wr_en = bin_valid;

pixel_shader_top u_pixel_shader (
    .x(shader_x),
    .y(shader_y),
    .fb_under(fb_under),
    .layout(ui_layout),
    .demod(ui_demod),
    .flags(ui_flags),
    .active_button(active_button),
    .touch_x(touch_x),
    .touch_y(touch_y),
    .freq_text(shader_freq_text),
    .band_text(shader_band_text),
    .demod_label(shader_demod_label),
    .rds_line(rds_line_pico),
    .mode_btn_label(shader_mode_btn_label),
    .mode_btn_text_x(16'sd8),
    .mode_btn_text_y(16'sd8),
    .plus_text_x(16'sd16),
    .plus_text_y(16'sd8),
    .minus_text_x(16'sd16),
    .minus_text_y(16'sd8),
    .volume_fill_px(shader_volume_fill),
    .mute_sprite_id(shader_mute_sprite_id),
    .spectrum_start_bin(shader_spectrum_start_bin),
    .spectrum_visible_bins(shader_spectrum_visible_bins),
    .spec_wr_clk(CLK),
    .spec_wr_en(spec_wr_en),
    .spec_wr_addr(bin_index - 8'd128),
    .spec_wr_data(spec_wr_data),
    .pixel(shader_pixel)
);

assign LCD_CLK = clk_pix;
assign LCD_DEN = shader_de;
assign LCD_R = shader_de ? shader_pixel[15:11] : 5'd0;
assign LCD_G = shader_de ? shader_pixel[10:5] : 6'd0;
assign LCD_B = shader_de ? shader_pixel[4:0] : 5'd0;

endmodule
