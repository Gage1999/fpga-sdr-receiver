// ui_status_prepare - raw UI fields to shader-state formatter.

module ui_status_prepare (
    input logic clk,
    input logic rst,
    input logic update,

    input logic [31:0] freq_hz,
    input logic [15:0] span_hz_log2,
    input logic [1:0] demod,
    input logic [7:0] volume,
    input logic [7:0] flags,

    output logic [95:0] freq_text,
    output logic [159:0] band_text,
    output logic [31:0] demod_label,
    output logic [15:0] mode_btn_label,
    output logic [15:0] volume_fill_px,
    output logic [7:0] mute_sprite_id,
    output logic [7:0] spectrum_start_bin,
    output logic [8:0] spectrum_visible_bins
);
    localparam logic [7:0] CH_SPACE = 8'h20;
    localparam logic [7:0] CH_DOT = 8'h2e;
    localparam logic [7:0] CH_DASH = 8'h2d;
    localparam logic [7:0] CH_M = 8'h4d;
    localparam logic [7:0] CH_H = 8'h48;
    localparam logic [7:0] CH_Z = 8'h7a;

    localparam logic [1:0] DEMOD_AM = 2'd1;
    localparam logic [1:0] DEMOD_GOES = 2'd2;
    localparam logic [1:0] DEMOD_ADSB = 2'd3;

    localparam logic [7:0] SPR_BTN_MUTE = 8'd10;
    localparam logic [7:0] SPR_BTN_MUTE_ON = 8'd11;

    typedef enum logic [1:0] {
        F_IDLE = 2'd0,
        F_CENTER = 2'd1,
        F_LO = 2'd2,
        F_HI = 2'd3
    } fmt_state_e;

    fmt_state_e fmt_state;
    logic [5:0] bit_count;
    logic [31:0] bin_shift;
    logic [39:0] bcd;
    logic [31:0] pending_lo_hz;
    logic [31:0] pending_hi_hz;

    function automatic logic [7:0] ascii_digit(input logic [3:0] d);
        ascii_digit = 8'h30 + {4'd0, d};
    endfunction

    function automatic logic [3:0] bcd_digit(input logic [39:0] v, input int idx);
        bcd_digit = v[idx*4 +: 4];
    endfunction

    function automatic logic [39:0] bcd_add3(input logic [39:0] in_bcd);
        logic [39:0] out_bcd;
        begin
            out_bcd = in_bcd;
            for (int i = 0; i < 10; i++) begin
                if (out_bcd[i*4 +: 4] >= 4'd5)
                    out_bcd[i*4 +: 4] = out_bcd[i*4 +: 4] + 4'd3;
            end
            bcd_add3 = out_bcd;
        end
    endfunction

    function automatic logic [95:0] make_freq_text(input logic [39:0] hz_bcd);
        logic [95:0] t;
        begin
            for (int i = 0; i < 12; i++) t[i*8 +: 8] = CH_SPACE;
            t[0*8 +: 8] = (bcd_digit(hz_bcd, 8) != 4'd0)
                         ? ascii_digit(bcd_digit(hz_bcd, 8)) : CH_SPACE;
            t[1*8 +: 8] = (bcd_digit(hz_bcd, 8) != 4'd0 ||
                            bcd_digit(hz_bcd, 7) != 4'd0)
                         ? ascii_digit(bcd_digit(hz_bcd, 7)) : CH_SPACE;
            t[2*8 +: 8] = ascii_digit(bcd_digit(hz_bcd, 6));
            t[3*8 +: 8] = CH_DOT;
            t[4*8 +: 8] = ascii_digit(bcd_digit(hz_bcd, 5));
            t[5*8 +: 8] = ascii_digit(bcd_digit(hz_bcd, 4));
            t[6*8 +: 8] = CH_SPACE;
            t[7*8 +: 8] = CH_M;
            t[8*8 +: 8] = CH_H;
            t[9*8 +: 8] = CH_Z;
            make_freq_text = t;
        end
    endfunction

    function automatic logic [55:0] make_mhz_3dp(input logic [39:0] hz_rounded_bcd);
        logic [55:0] t;
        begin
            t[0*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 8));
            t[1*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 7));
            t[2*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 6));
            t[3*8 +: 8] = CH_DOT;
            t[4*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 5));
            t[5*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 4));
            t[6*8 +: 8] = ascii_digit(bcd_digit(hz_rounded_bcd, 3));
            make_mhz_3dp = t;
        end
    endfunction

    function automatic logic [31:0] sat_add(input logic [31:0] a, input logic [31:0] b);
        logic [32:0] sum;
        begin
            sum = {1'b0, a} + {1'b0, b};
            sat_add = sum[32] ? 32'hffff_ffff : sum[31:0];
        end
    endfunction

    logic [39:0] bcd_adj;
    logic [39:0] bcd_next;
    assign bcd_adj = bcd_add3(bcd);
    assign bcd_next = {bcd_adj[38:0], bin_shift[31]};

    logic [31:0] span_hz;
    logic [31:0] span_half;
    logic [31:0] band_lo_hz;
    logic [31:0] band_hi_hz;
    logic [15:0] span_hz_log2_clamped;
    logic [15:0] volume_scaled;
    logic [15:0] volume_fill_approx;

    always_comb begin
        if (span_hz_log2 < 16'd13)      span_hz_log2_clamped = 16'd13;
        else if (span_hz_log2 > 16'd18) span_hz_log2_clamped = 16'd18;
        else                            span_hz_log2_clamped = span_hz_log2;

        span_hz = 32'd1 << span_hz_log2_clamped[4:0];
        span_half = {1'b0, span_hz[31:1]};
        band_lo_hz = (freq_hz > span_half) ? (freq_hz - span_half) : 32'd0;
        band_hi_hz = ((32'hffff_ffff - freq_hz) < span_half)
                   ? 32'hffff_ffff : (freq_hz + span_half);

        volume_scaled = {8'd0, volume} * 16'd149;
        volume_fill_approx = {7'd0, volume_scaled[15:7]};
        if (volume_fill_approx > 16'd116) volume_fill_approx = 16'd116;
    end

    task automatic load_convert(input logic [31:0] value, input fmt_state_e next_state);
        begin
            bcd <= 40'd0;
            bin_shift <= value;
            bit_count <= 6'd0;
            fmt_state <= next_state;
        end
    endtask

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            freq_text <= {CH_SPACE, CH_SPACE, CH_Z, CH_H, CH_M, CH_SPACE,
                          8'h30, 8'h30, CH_DOT, 8'h30, 8'h30, 8'h31};
            band_text <= {CH_SPACE, CH_SPACE, CH_Z, CH_H, CH_M, 8'h36, 8'h36,
                          8'h30, CH_DOT, 8'h30, 8'h30, 8'h31, CH_DASH,
                          8'h34, 8'h33, 8'h39, CH_DOT, 8'h39, 8'h39, 8'h30};
            demod_label <= {CH_SPACE, CH_SPACE, 8'h4d, 8'h46};
            mode_btn_label <= {8'h4d, 8'h46};
            volume_fill_px <= 16'd58;
            mute_sprite_id <= SPR_BTN_MUTE;
            spectrum_visible_bins <= 9'd256;
            spectrum_start_bin <= 8'd0;
            fmt_state <= F_IDLE;
            bit_count <= 6'd0;
            bcd <= 40'd0;
            bin_shift <= 32'd0;
            pending_lo_hz <= 32'd0;
            pending_hi_hz <= 32'd0;
        end else begin
            if (update) begin
                unique case (demod)
                    DEMOD_AM: begin
                        demod_label <= {CH_SPACE, CH_SPACE, 8'h4d, 8'h41};
                        mode_btn_label <= {8'h4d, 8'h41};
                    end
                    DEMOD_GOES: begin
                        demod_label <= {8'h53, 8'h45, 8'h4f, 8'h47};
                        mode_btn_label <= {8'h4f, 8'h47};
                    end
                    DEMOD_ADSB: begin
                        demod_label <= {8'h42, 8'h53, 8'h44, 8'h41};
                        mode_btn_label <= {8'h44, 8'h41};
                    end
                    default: begin
                        demod_label <= {CH_SPACE, CH_SPACE, 8'h4d, 8'h46};
                        mode_btn_label <= {8'h4d, 8'h46};
                    end
                endcase

                volume_fill_px <= volume_fill_approx;
                mute_sprite_id <= flags[0] ? SPR_BTN_MUTE_ON : SPR_BTN_MUTE;

                spectrum_visible_bins <= 9'd256;
                spectrum_start_bin <= 8'd0;

                pending_lo_hz <= sat_add(band_lo_hz, 32'd500);
                pending_hi_hz <= sat_add(band_hi_hz, 32'd500);
                load_convert(freq_hz, F_CENTER);
            end else if (fmt_state != F_IDLE) begin
                bcd <= bcd_next;
                bin_shift <= {bin_shift[30:0], 1'b0};

                if (bit_count == 6'd31) begin
                    unique case (fmt_state)
                        F_CENTER: begin
                            freq_text <= make_freq_text(bcd_next);
                            load_convert(pending_lo_hz, F_LO);
                        end
                        F_LO: begin
                            band_text[0 +: 56] <= make_mhz_3dp(bcd_next);
                            band_text[7*8 +: 8] <= CH_DASH;
                            load_convert(pending_hi_hz, F_HI);
                        end
                        F_HI: begin
                            band_text[8*8 +: 56] <= make_mhz_3dp(bcd_next);
                            band_text[15*8 +: 8] <= CH_M;
                            band_text[16*8 +: 8] <= CH_H;
                            band_text[17*8 +: 8] <= CH_Z;
                            band_text[18*8 +: 8] <= CH_SPACE;
                            band_text[19*8 +: 8] <= CH_SPACE;
                            fmt_state <= F_IDLE;
                        end
                        default: fmt_state <= F_IDLE;
                    endcase
                end else begin
                    bit_count <= bit_count + 6'd1;
                end
            end
        end
    end
endmodule
