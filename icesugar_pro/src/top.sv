module top #(
    parameter AUDIO_TEST_TONE = 0,
    parameter FM_CHAIN_TEST = 0,
    parameter FM_CIC_R = 32,
    parameter IQ_PACED = 0,
    parameter IQ_SAMPLE_RATE = 349_000,
    parameter IQ_FIFO_DEPTH = 16,
    parameter USE_TLV = 0,           // 0 = raw-IQ link (default), 1 = TLV-framed link
    parameter BYTE_FIFO_DEPTH = 32,  // TLV byte CDC FIFO depth (spi_clk -> CLK)
    parameter I2S_BCLK_DIV = 9,      // I2S sample rate = 25M/(BCLK_DIV*64); 9 -> ~43.4kHz.
                                     // Matched to the measured demod rate: the Pluto delivers
                                     // ~352k samples/s, so at FM_CIC_R=8 the demod runs at
                                     // ~44.0kHz -> 43.4kHz is a ~1.4% match, well within the
                                     // elastic audio FIFO's skip/repeat range.
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

// Clock generation - 100 MHz SDRAM clock and 30 MHz pixel clock from 25 MHz input
// CLKOP = CLKI * CLKFB_DIV / CLKI_DIV = 25 * 4 = 100 MHz
// VCO = CLKOP * CLKOP_DIV = 100 * 6 = 600 MHz
// CLKOS = VCO / CLKOS_DIV = 600 / 20 = 30 MHz
logic clk_pix;
logic clk_sdram;
logic pll_locked;

`ifdef SIMULATION
assign clk_sdram  = CLK;
assign clk_pix    = CLK;
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
    .CLKOS2_DIV(1),
    .CLKOS2_CPHASE(0),
    .CLKOS2_FPHASE(0),
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

// ---------------------------------------------------------------------------
// IQ front-end. Two interchangeable sources feed one shared 32-bit IQ FIFO,
// selected at build time by USE_TLV. Both converge on the same fifo_rdata /
// pacer / sys_i,sys_q,sys_iq_valid path below, so everything downstream
// (FFT/CIC/fm_demod) is identical in either mode.
//   USE_TLV=0: today's raw link  — every 32 SPI bits is one IQ sample.
//   USE_TLV=1: TLV-framed link    — spi_frame_rx -> byte CDC FIFO -> tlv_demux
//              -> tlv_iq_sink; non-IQ packet types route to stub capture sinks.
// ---------------------------------------------------------------------------
logic [31:0] fifo_rdata;
logic        fifo_empty, fifo_full;
logic        fifo_pop;
logic        fifo_pop_d;
logic        iq_sample_tick;
logic [31:0] iq_rate_acc;

// Source-side hookup for the shared IQ FIFO (driven by the selected branch).
logic        iqsrc_wclk;
logic        iqsrc_wrst;
logic [31:0] iqsrc_wdata;
logic        iqsrc_wpush;

// TLV status counters (module scope so they survive across the generate and
// can be surfaced on the LCD); tied to 0 in raw mode.
logic [15:0] tlv_iq_pkts, tlv_img_pkts, tlv_obj_pkts;
logic [15:0] tlv_unknown, tlv_short, tlv_stray;
logic [7:0]  tlv_last_type;

generate
if (USE_TLV == 0) begin : g_rawiq
    logic [15:0] spi_i, spi_q;
    logic        spi_iq_valid;

    spi_iq_slave u_spi_iq (
        .spi_clk  (spi_clk),
        .spi_cs_n (cs),
        .spi_mosi (mosi),
        .i_data   (spi_i),
        .q_data   (spi_q),
        .iq_valid (spi_iq_valid)
    );

    assign iqsrc_wclk  = spi_clk;
    assign iqsrc_wrst  = spi_rst;
    assign iqsrc_wdata = {spi_i, spi_q};
    assign iqsrc_wpush = spi_iq_valid & ~fifo_full & ~spi_rst;

    assign tlv_iq_pkts = 16'd0;
    assign tlv_img_pkts = 16'd0;
    assign tlv_obj_pkts = 16'd0;
    assign tlv_unknown = 16'd0;
    assign tlv_short = 16'd0;
    assign tlv_stray = 16'd0;
    assign tlv_last_type = 8'd0;
end else begin : g_tlv
    // SPI byte deserializer (spi_clk domain).
    logic       fr_valid, fr_sof;
    logic [7:0] fr_byte;

    spi_frame_rx u_frame_rx (
        .spi_clk   (spi_clk),
        .spi_cs_n  (cs),
        .spi_mosi  (mosi),
        .byte_valid(fr_valid),
        .byte_sof  (fr_sof),
        .byte_data (fr_byte)
    );

    // Byte CDC FIFO: {sof, byte} crosses spi_clk -> CLK.
    logic [8:0] byte_rdata;
    logic       byte_empty, byte_full;
    logic       byte_pop, byte_pop_d;

    async_fifo #(.WIDTH(9), .DEPTH(BYTE_FIFO_DEPTH)) u_byte_fifo (
        .wclk  (spi_clk),
        .wrst  (spi_rst),
        .wdata ({fr_sof, fr_byte}),
        .wpush (fr_valid & ~byte_full & ~spi_rst),
        .wfull (byte_full),
        .rclk  (CLK),
        .rrst  (sys_rst),
        .rdata (byte_rdata),
        .rpop  (byte_pop),
        .rempty(byte_empty)
    );

    // Synchronous-read FIFO: data is valid the cycle after the pop is asserted.
    assign byte_pop = ~byte_empty;
    always_ff @(posedge CLK or posedge sys_rst) begin
        if (sys_rst) byte_pop_d <= 1'b0;
        else         byte_pop_d <= byte_pop;
    end

    // Demux: route payload bytes by packet type.
    logic       pl_valid, pl_sop, pl_eop;
    logic [7:0] pl_byte, pl_type;

    tlv_demux u_demux (
        .clk          (CLK),
        .rst          (sys_rst),
        .in_valid     (byte_pop_d),
        .in_sof       (byte_rdata[8]),
        .in_byte      (byte_rdata[7:0]),
        .pl_valid     (pl_valid),
        .pl_sop       (pl_sop),
        .pl_eop       (pl_eop),
        .pl_byte      (pl_byte),
        .pl_type      (pl_type),
        .iq_pkt_count (tlv_iq_pkts),
        .img_pkt_count(tlv_img_pkts),
        .obj_pkt_count(tlv_obj_pkts),
        .unknown_count(tlv_unknown),
        .short_count  (tlv_short),
        .stray_count  (tlv_stray),
        .last_type    (tlv_last_type)
    );

    // IQ sink: reassemble {I,Q} words and push into the shared IQ FIFO.
    logic signed [15:0] tlv_i, tlv_q;
    logic               tlv_iq_word_valid;

    tlv_iq_sink u_iq_sink (
        .clk          (CLK),
        .rst          (sys_rst),
        .pl_valid     (pl_valid),
        .pl_sop       (pl_sop),
        .pl_eop       (pl_eop),
        .pl_byte      (pl_byte),
        .pl_type      (pl_type),
        .i_data       (tlv_i),
        .q_data       (tlv_q),
        .iq_word_valid(tlv_iq_word_valid)
    );

    // Stub sinks for decoded-data types (counters + capture buffer only until
    // the SDRAM compositor exists). Debug read ports are tied off for now.
    logic [15:0] img_len_unused, obj_len_unused;
    logic [7:0]  img_rd_unused, obj_rd_unused;

    tlv_capture_sink #(.CAP_TYPE(8'h01), .DEPTH(256)) u_img_sink (
        .clk(CLK), .rst(sys_rst),
        .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
        .pl_byte(pl_byte), .pl_type(pl_type),
        .pkt_count(), .last_len(img_len_unused),
        .rd_addr(8'd0), .rd_data(img_rd_unused)
    );

    tlv_capture_sink #(.CAP_TYPE(8'h02), .DEPTH(256)) u_obj_sink (
        .clk(CLK), .rst(sys_rst),
        .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
        .pl_byte(pl_byte), .pl_type(pl_type),
        .pkt_count(), .last_len(obj_len_unused),
        .rd_addr(8'd0), .rd_data(obj_rd_unused)
    );

    assign iqsrc_wclk  = CLK;
    assign iqsrc_wrst  = sys_rst;
    assign iqsrc_wdata = {tlv_i, tlv_q};
    assign iqsrc_wpush = tlv_iq_word_valid & ~fifo_full;
end
endgenerate

async_fifo #(.WIDTH(32), .DEPTH(IQ_FIFO_DEPTH)) u_iq_fifo (
    .wclk (iqsrc_wclk),
    .wrst (iqsrc_wrst),
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

// ---- Elastic audio FIFO: decouple the bursty fm_demod output rate from the
// fixed I2S playback rate, with skip/repeat rate adaptation (audio_fifo.sv).
// Without it the DAC under/over-samples the demod stream -> distortion. ----
localparam int AFIFO_DEPTH = 1024;
localparam int AFIFO_LOW   = AFIFO_DEPTH/4;       // below -> repeat (hold) to refill
localparam int AFIFO_HIGH  = (AFIFO_DEPTH*3)/4;   // above -> skip one to catch up

logic [15:0] afifo_rdata;
logic        afifo_empty, afifo_full;
logic [$clog2(AFIFO_DEPTH):0] afifo_count;
logic [1:0]  afifo_pop_n;
logic [15:0] audio_held;
logic        i2s_sample_req_d;
wire         sample_req_edge = i2s_sample_req & ~i2s_sample_req_d;

audio_fifo #(.WIDTH(16), .DEPTH(AFIFO_DEPTH)) u_afifo (
    .clk    (CLK),
    .rst    (sys_rst),
    .wdata  (audio_sample_16),
    .wpush  (audio_valid & fm_active & ~afifo_full),
    .full   (afifo_full),
    .rdata  (afifo_rdata),
    .rpop_n (afifo_pop_n),
    .empty  (afifo_empty),
    .count  (afifo_count)
);

always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) i2s_sample_req_d <= 1'b0;
    else         i2s_sample_req_d <= i2s_sample_req;
end

// One sample consumed per I2S frame; advance 0/1/2 to keep the buffer centered.
always_comb begin
    afifo_pop_n = 2'd0;
    if (sample_req_edge) begin
        if      (afifo_count <= AFIFO_LOW)  afifo_pop_n = 2'd0;  // low -> repeat
        else if (afifo_count >= AFIFO_HIGH) afifo_pop_n = 2'd2;  // high -> skip one
        else                                afifo_pop_n = 2'd1;  // normal
    end
end

// Hold the last valid sample so a brief underrun repeats it cleanly.
always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst)           audio_held <= '0;
    else if (~afifo_empty) audio_held <= afifo_rdata;
end

wire signed [15:0] audio_play = afifo_empty ? audio_held : afifo_rdata;

assign audio_to_i2s = AUDIO_TEST_TONE ? tone_sample : audio_play;

i2s_tx #(.BCLK_DIV(I2S_BCLK_DIV)) u_i2s (
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
    .pclk (clk_pix),
    .mode (mode),
    .volume (volume),
    .mute (mute),
    // In TLV mode the debug fields show TLV framing health instead of the raw
    // FFT counters: rx = IQ packets seen, bin = unknown-type packets, last =
    // last packet type. rx_sps still reflects real IQ sample flow in both modes.
    .dbg_rx_count (USE_TLV ? tlv_iq_pkts[7:0] : dbg_rx_count),
    .dbg_bin_count (USE_TLV ? tlv_unknown[7:0] : dbg_bin_count),
    .dbg_last_mag (USE_TLV ? tlv_last_type : dbg_last_mag),
    .rx_sps_bcd (rx_sps_bcd),
    .wf_magnitude (wf_magnitude),
    .wf_bin (wf_bin_req),
    .wf_row_age (wf_row_age_req),
    .LCD_DE (LCD_DEN),
    .LCD_R (LCD_R),
    .LCD_G (LCD_G),
    .LCD_B (LCD_B)
);

assign LCD_CLK = clk_pix;

endmodule
