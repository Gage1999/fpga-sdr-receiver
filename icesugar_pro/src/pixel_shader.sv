// Pixel shader — SystemVerilog port of icesugar_pro/model/src/pixel_shader.c.
//
// The C function is the executable spec. This module must produce identical
// output for identical inputs; equivalence is enforced by the Verilator
// parity harness in tb_pixel_shader.cpp.
//
// Implemented:
//   - region_at + top dispatch
//   - shade_overlay (touch crosshair)
//   - shade_spectrum (with spectrum BRAM port)
//   - shade_status (volume + center freq / RDS text / demod text + buttons)
//   - spectrum-band text overlay
//   - shade_image_mode_button (GOES/ADS-B floating mode/zoom buttons)

module pixel_shader (
    input  logic [9:0]   x,
    input  logic [9:0]   y,
    input  logic [15:0]  fb_under,

    input  logic [1:0]   layout,
    input  logic [1:0]   demod,
    input  logic [7:0]   flags,
    input  logic [7:0]   active_button,
    input  logic [9:0]   touch_x,
    input  logic [9:0]   touch_y,

    // shader_state precomputed strings (LSB = byte 0):
    input  logic [95:0]  freq_text,        // 12 chars
    input  logic [159:0] band_text,        // 20 chars
    input  logic [31:0]  demod_label,      // 4 chars
    input  logic [191:0] rds_line,         // 24 chars
    input  logic [15:0]  mode_btn_label,   // 2 chars

    // label_origin outputs (signed):
    input  logic signed [15:0] mode_btn_text_x,
    input  logic signed [15:0] mode_btn_text_y,
    input  logic signed [15:0] plus_text_x,
    input  logic signed [15:0] plus_text_y,
    input  logic signed [15:0] minus_text_x,
    input  logic signed [15:0] minus_text_y,

    input  logic [15:0]  volume_fill_px,
    input  logic [7:0]   mute_sprite_id,
    input  logic [7:0]   spectrum_start_bin,
    input  logic [8:0]   spectrum_visible_bins,

    // Spectrum bin BRAM (256x16).
    output logic [7:0]   spectrum_bin_addr,
    input  logic [15:0]  spectrum_bin_data,

    // 16x32 font ROM (96 chars * 32 rows = 3072 x 16).
    output logic [11:0]  font16_addr,
    input  logic [15:0]  font16_data,

    // Sprite ROM (16 sprites * 32 * 32 = 16384 x 16).
    output logic [13:0]  sprite_addr,
    input  logic [15:0]  sprite_data,

    output logic [15:0]  pixel
);
    // ── constants mirroring shared headers ───────────────────────────────
    localparam logic [2:0] R_NONE      = 3'd0;
    localparam logic [2:0] R_STATUS    = 3'd1;
    localparam logic [2:0] R_SPECTRUM  = 3'd2;
    localparam logic [2:0] R_WATERFALL = 3'd3;
    localparam logic [2:0] R_GOES      = 3'd4;
    localparam logic [2:0] R_ADSB      = 3'd6;

    localparam logic [1:0] LAYOUT_SPECTRUM_ONLY = 2'd0;
    localparam logic [1:0] LAYOUT_GOES_FULL     = 2'd1;
    localparam logic [1:0] LAYOUT_ADSB_FULL     = 2'd2;

    localparam logic [1:0] DEMOD_FM = 2'd0;

    localparam logic [9:0] STATUS_H            = 10'd64;
    localparam logic [9:0] STATUS_SPECTRUM_END = 10'd192;
    localparam logic [9:0] SCREEN_W            = 10'd800;
    localparam logic [9:0] SCREEN_H            = 10'd480;
    localparam logic [9:0] STATUS_FREQ_X       = 10'd4;
    localparam logic [9:0] STATUS_FREQ_Y       = 10'd3;
    localparam logic [9:0] STATUS_RDS_X        = 10'd4;
    localparam logic [9:0] STATUS_RDS_Y        = 10'd32;
    localparam logic [9:0] STATUS_RDS_W        = 10'd320;
    localparam logic [9:0] SPECTRUM_BAND_X     = 10'd4;
    localparam logic [9:0] SPECTRUM_BAND_Y     = 10'd66;
    localparam logic [9:0] STATUS_VOL_X        = 10'd204;
    localparam logic [9:0] STATUS_VOL_Y        = 10'd6;
    localparam logic [9:0] STATUS_VOL_W        = 10'd120;
    localparam logic [9:0] STATUS_VOL_H        = 10'd20;
    localparam logic [9:0] STATUS_DEMOD_X      = 10'd332;
    localparam logic [9:0] STATUS_DEMOD_Y      = 10'd3;
    localparam logic [1:0] STATUS_DEMOD_CHARS  = 2'd2;

    localparam int UI_FLAG_TOUCH_ACTIVE_BIT = 2;

    // button IDs
    localparam logic [2:0] BTN_FREQ_UP  = 3'd0;
    localparam logic [2:0] BTN_FREQ_DN  = 3'd1;
    localparam logic [2:0] BTN_VOL_UP   = 3'd2;
    localparam logic [2:0] BTN_VOL_DN   = 3'd3;
    localparam logic [2:0] BTN_MODE     = 3'd4;
    localparam logic [2:0] BTN_MUTE     = 3'd5;
    localparam logic [2:0] BTN_ZOOM_IN  = 3'd6;
    localparam logic [2:0] BTN_ZOOM_OUT = 3'd7;

    // sprite IDs (sprites.h)
    localparam logic [7:0] SPR_BTN_FREQ_UP = 8'd0;
    localparam logic [7:0] SPR_BTN_FREQ_DN = 8'd1;
    localparam logic [7:0] SPR_BTN_VOL_UP  = 8'd2;
    localparam logic [7:0] SPR_BTN_VOL_DN  = 8'd3;
    localparam logic [7:0] SPR_ICON_BLANK  = 8'd15;

    // sentinel for not-yet-translated paths
    localparam logic [15:0] SENTINEL = 16'hF81F;

    // status bar colors
    localparam logic [15:0] STATUS_BG     = 16'h10C4;  // RGB565(20,24,32)
    localparam logic [15:0] IMG_BG        = 16'h0883;  // RGB565(12,18,24) — image-mode button bg
    localparam logic [15:0] STATUS_FG     = 16'hDF5F;  // RGB565(220,235,255)
    localparam logic [15:0] STATUS_ACCENT = 16'h55FF;  // RGB565(80,190,255)
    localparam logic [15:0] STATUS_DIM    = 16'hA67C;  // RGB565(165,205,225)
    localparam logic [15:0] VOL_MID       = 16'h2987;  // RGB565(40,48,60)

    // text-button frame colors (draw_text_button)
    localparam logic [15:0] TB_FILL  = 16'h1905;       // RGB565(24,32,42)
    localparam logic [15:0] TB_EDGE  = 16'h9DD9;       // RGB565(156,184,204)
    localparam logic [15:0] TB_INNER = 16'h31E9;       // RGB565(48,60,74)
    localparam logic [15:0] TB_FG    = 16'hF7FF;       // RGB565(245,252,255)

    localparam logic [15:0] CROSSHAIR_ARM = 16'hFFFF;
    localparam logic [15:0] CROSSHAIR_DOT = 16'hFA8A;

    // ── region_at ────────────────────────────────────────────────────────
    logic [2:0] region_kind;
    logic       in_screen;
    assign in_screen = (x < SCREEN_W) && (y < SCREEN_H);

    always_comb begin
        region_kind = R_NONE;
        if (in_screen) begin
            unique case (layout)
                LAYOUT_GOES_FULL: region_kind = R_GOES;
                LAYOUT_ADSB_FULL: region_kind = R_ADSB;
                default: begin
                    if (y < STATUS_H)                  region_kind = R_STATUS;
                    else if (y < STATUS_SPECTRUM_END)  region_kind = R_SPECTRUM;
                    else                               region_kind = R_WATERFALL;
                end
            endcase
        end
    end

    // ── shade_spectrum ──────────────────────────────────────────────────
    logic [31:0] bin_idx_mul;
    logic [15:0] bin_mul_const;
    logic [7:0]  span_bin_off;
    logic [8:0]  span_bin_sum;
    always_comb begin
        unique case (spectrum_visible_bins)
            9'd128: bin_mul_const = 16'd10486;
            9'd64:  bin_mul_const = 16'd5243;
            9'd32:  bin_mul_const = 16'd2622;
            9'd16:  bin_mul_const = 16'd1311;
            9'd8:   bin_mul_const = 16'd656;
            default: bin_mul_const = 16'd20972; // 256 visible bins
        endcase
    end
    assign bin_idx_mul = {22'b0, x} * {16'b0, bin_mul_const};
    assign span_bin_off = bin_idx_mul[23:16];
    assign span_bin_sum = {1'b0, spectrum_start_bin} + {1'b0, span_bin_off};
    assign spectrum_bin_addr = span_bin_sum[8] ? 8'hff : span_bin_sum[7:0];

    logic [9:0] ly_spec;
    logic [6:0] bar_h;
    logic [7:0] bar_top;
    assign ly_spec = y - STATUS_H;
    assign bar_h   = spectrum_bin_data[15:9];
    assign bar_top = 8'd128 - {1'b0, bar_h};

    localparam logic [15:0] SPEC_BG   = 16'h0862;
    localparam logic [15:0] SPEC_BAR  = 16'h7EF1;
    localparam logic [15:0] SPEC_GRID = 16'h1947;

    logic [15:0] spectrum_base_pixel;
    always_comb begin
        if (ly_spec[4:0] == 5'd0)            spectrum_base_pixel = SPEC_GRID;
        else if (ly_spec >= {2'b0, bar_top}) spectrum_base_pixel = SPEC_BAR;
        else                                 spectrum_base_pixel = SPEC_BG;
    end

    // ── shade_status ────────────────────────────────────────────────────
    // Sub-region detection (lx_st = x, ly_st = y since status x0=y0=0).
    logic [9:0] lx_st;
    logic [9:0] ly_st;
    assign lx_st = x;
    assign ly_st = y;

    logic in_freq_text;
    logic in_rds_text;
    logic in_band_text;
    logic in_vol_bar;
    logic in_demod_label;

    assign in_freq_text   = (lx_st >= STATUS_FREQ_X) && (lx_st < STATUS_FREQ_X + 10'd192)
                         && (ly_st >= STATUS_FREQ_Y) && (ly_st < 10'd32);
    assign in_rds_text    = (layout == LAYOUT_SPECTRUM_ONLY) && (demod == DEMOD_FM)
                         && (lx_st >= STATUS_RDS_X) && (lx_st < STATUS_RDS_X + STATUS_RDS_W)
                         && (ly_st >= STATUS_RDS_Y) && (ly_st < 10'd64);
    assign in_band_text   = (layout == LAYOUT_SPECTRUM_ONLY)
                         && (lx_st >= SPECTRUM_BAND_X) && (lx_st < SPECTRUM_BAND_X + 10'd320)
                         && (ly_st >= SPECTRUM_BAND_Y) && (ly_st < SPECTRUM_BAND_Y + 10'd32);
    assign in_vol_bar     = (lx_st >= STATUS_VOL_X)  && (lx_st < STATUS_VOL_X + STATUS_VOL_W)
                         && (ly_st >= STATUS_VOL_Y)  && (ly_st < STATUS_VOL_Y + STATUS_VOL_H);
    assign in_demod_label = (lx_st >= STATUS_DEMOD_X) && (lx_st < STATUS_DEMOD_X + 10'd32)
                         && (ly_st >= STATUS_DEMOD_Y) && (ly_st < 10'd32);

    // Button hit-test (spectrum-only layout). x0 values from ui_button_x0:
    //   FREQ_UP slot7 = 368, FREQ_DN slot6 = 422, VOL_UP slot5 = 476,
    //   VOL_DN slot4 = 530, MUTE slot3 = 584, ZOOM_OUT slot2 = 638,
    //   ZOOM_IN slot1 = 692, MODE slot0 = 746. width = 48.
    logic       in_button;
    logic [2:0] hit_btn_id;
    logic [9:0] hit_btn_x0;

    always_comb begin
        in_button  = 1'b0;
        hit_btn_id = 3'd0;
        hit_btn_x0 = 10'd0;
        if (layout == LAYOUT_SPECTRUM_ONLY
            && ly_st >= 10'd8 && ly_st < 10'd56) begin
            if      (lx_st >= 10'd368 && lx_st < 10'd416) begin in_button=1; hit_btn_id=BTN_FREQ_UP;  hit_btn_x0=10'd368; end
            else if (lx_st >= 10'd422 && lx_st < 10'd470) begin in_button=1; hit_btn_id=BTN_FREQ_DN;  hit_btn_x0=10'd422; end
            else if (lx_st >= 10'd476 && lx_st < 10'd524) begin in_button=1; hit_btn_id=BTN_VOL_UP;   hit_btn_x0=10'd476; end
            else if (lx_st >= 10'd530 && lx_st < 10'd578) begin in_button=1; hit_btn_id=BTN_VOL_DN;   hit_btn_x0=10'd530; end
            else if (lx_st >= 10'd584 && lx_st < 10'd632) begin in_button=1; hit_btn_id=BTN_MUTE;     hit_btn_x0=10'd584; end
            else if (lx_st >= 10'd638 && lx_st < 10'd686) begin in_button=1; hit_btn_id=BTN_ZOOM_OUT; hit_btn_x0=10'd638; end
            else if (lx_st >= 10'd692 && lx_st < 10'd740) begin in_button=1; hit_btn_id=BTN_ZOOM_IN;  hit_btn_x0=10'd692; end
            else if (lx_st >= 10'd746 && lx_st < 10'd794) begin in_button=1; hit_btn_id=BTN_MODE;    hit_btn_x0=10'd746; end
        end
    end

    // Image-layout floating buttons (GOES_FULL: MODE only; ADSB_FULL: MODE +
    // ZOOM_IN + ZOOM_OUT). Same x0 slots as spectrum buttons, drawn over the
    // FB instead of inside the status bar.
    logic       in_img_layout;
    logic       in_img_button;
    logic [2:0] img_btn_id;
    logic [9:0] img_btn_x0;

    assign in_img_layout = (layout == LAYOUT_GOES_FULL)
                        || (layout == LAYOUT_ADSB_FULL);

    always_comb begin
        in_img_button = 1'b0;
        img_btn_id    = 3'd0;
        img_btn_x0    = 10'd0;
        if (in_img_layout && y >= 10'd8 && y < 10'd56) begin
            // MODE: visible in both image layouts (slot 0 → x0 = 746)
            if (x >= 10'd746 && x < 10'd794) begin
                in_img_button = 1'b1;
                img_btn_id    = BTN_MODE;
                img_btn_x0    = 10'd746;
            end
            // ZOOM_IN / ZOOM_OUT: ADSB only (slot 1 = 692, slot 2 = 638)
            else if (layout == LAYOUT_ADSB_FULL) begin
                if (x >= 10'd692 && x < 10'd740) begin
                    in_img_button = 1'b1;
                    img_btn_id    = BTN_ZOOM_IN;
                    img_btn_x0    = 10'd692;
                end else if (x >= 10'd638 && x < 10'd686) begin
                    in_img_button = 1'b1;
                    img_btn_id    = BTN_ZOOM_OUT;
                    img_btn_x0    = 10'd638;
                end
            end
        end
    end

    // Unify status-layout and image-layout button hits into one "active button"
    // so the existing draw-logic (local coords, frame, glyph_bit, sprite) works
    // for both. Mutually exclusive by layout, so no collision priority needed.
    logic        any_btn;
    logic [2:0]  any_btn_id;
    logic [9:0]  any_btn_x0;
    logic [15:0] any_btn_bg;
    logic        any_btn_is_text;

    always_comb begin
        if (in_img_button) begin
            any_btn         = 1'b1;
            any_btn_id      = img_btn_id;
            any_btn_x0      = img_btn_x0;
            any_btn_bg      = IMG_BG;
            any_btn_is_text = 1'b1;            // image buttons are all text
        end else begin
            any_btn         = in_button;
            any_btn_id      = hit_btn_id;
            any_btn_x0      = hit_btn_x0;
            any_btn_bg      = STATUS_BG;
            any_btn_is_text = (hit_btn_id == BTN_MODE)
                           || (hit_btn_id == BTN_ZOOM_IN)
                           || (hit_btn_id == BTN_ZOOM_OUT);
        end
    end

    // Volume bar pixel.
    logic [15:0] vol_pixel;
    logic [9:0] vol_local_x;
    assign vol_local_x = lx_st - STATUS_VOL_X;
    always_comb begin
        if (lx_st == STATUS_VOL_X || lx_st == STATUS_VOL_X + STATUS_VOL_W - 10'd1
            || ly_st == STATUS_VOL_Y || ly_st == STATUS_VOL_Y + STATUS_VOL_H - 10'd1) begin
            vol_pixel = STATUS_DIM;
        end else if (vol_local_x >= 10'd2
                     && (vol_local_x - 10'd2) < volume_fill_px[9:0]) begin
            vol_pixel = STATUS_ACCENT;
        end else begin
            vol_pixel = VOL_MID;
        end
    end

    // Text path selection: which of {freq, rds, demod_label, button-text}.
    // Only one is active at a given pixel.
    typedef enum logic [3:0] {
        TXT_NONE      = 4'd0,
        TXT_FREQ      = 4'd1,
        TXT_RDS       = 4'd2,
        TXT_BAND      = 4'd3,
        TXT_DEMOD     = 4'd4,
        TXT_MODE_BTN  = 4'd5,
        TXT_IMG_MODE  = 4'd6,
        TXT_PLUS      = 4'd7,
        TXT_MINUS     = 4'd8
    } text_path_t;

    text_path_t text_path;
    always_comb begin
        // Image-button text paths first: they're in image layouts where the
        // status-region text paths can't fire anyway (region != STATUS).
        if      (in_img_button && img_btn_id == BTN_MODE)     text_path = TXT_IMG_MODE;
        else if (any_btn && any_btn_id == BTN_ZOOM_IN)        text_path = TXT_PLUS;
        else if (any_btn && any_btn_id == BTN_ZOOM_OUT)       text_path = TXT_MINUS;
        else if (in_freq_text)                                text_path = TXT_FREQ;
        else if (in_rds_text)                                 text_path = TXT_RDS;
        else if (in_band_text)                                text_path = TXT_BAND;
        else if (in_demod_label)                              text_path = TXT_DEMOD;
        else if (in_button && hit_btn_id == BTN_MODE)         text_path = TXT_MODE_BTN;
        else                                                  text_path = TXT_NONE;
    end

    // For status-bar text regions: lx-x0 → ch_idx and gx; ly-y0 → gy.
    logic [9:0] freq_col_w;
    logic [9:0] freq_gy_w;
    assign freq_col_w = lx_st - STATUS_FREQ_X;
    assign freq_gy_w  = ly_st - STATUS_FREQ_Y;
    logic [3:0] freq_ch_idx;
    logic [3:0] freq_gx;
    logic [4:0] freq_gy;
    assign freq_ch_idx = freq_col_w[7:4];   // 0..11 fits in 4
    assign freq_gx     = freq_col_w[3:0];
    assign freq_gy     = freq_gy_w[4:0];

    logic [9:0] rds_col_w;
    logic [9:0] rds_gy_w;
    assign rds_col_w = lx_st - STATUS_RDS_X;
    assign rds_gy_w  = ly_st - STATUS_RDS_Y;
    logic [4:0] rds_ch_idx;
    logic [3:0] rds_gx;
    logic [4:0] rds_gy;
    assign rds_ch_idx = rds_col_w[8:4];     // 0..19 fits in 5
    assign rds_gx     = rds_col_w[3:0];
    assign rds_gy     = rds_gy_w[4:0];

    logic [9:0] band_col_w;
    logic [9:0] band_gy_w;
    assign band_col_w = lx_st - SPECTRUM_BAND_X;
    assign band_gy_w  = ly_st - SPECTRUM_BAND_Y;
    logic [4:0] band_ch_idx;
    logic [3:0] band_gx;
    logic [4:0] band_gy;
    assign band_ch_idx = band_col_w[8:4];     // 0..19 fits in 5
    assign band_gx     = band_col_w[3:0];
    assign band_gy     = band_gy_w[4:0];

    logic [9:0] demod_col_w;
    logic [9:0] demod_gy_w;
    assign demod_col_w = lx_st - STATUS_DEMOD_X;
    assign demod_gy_w  = ly_st - STATUS_DEMOD_Y;
    logic [1:0] demod_ch_idx;
    logic [3:0] demod_gx;
    logic [4:0] demod_gy;
    assign demod_ch_idx = demod_col_w[5:4]; // 0..3 fits in 2
    assign demod_gx     = demod_col_w[3:0];
    assign demod_gy     = demod_gy_w[4:0];

    // For button text (MODE only in spectrum-only): rel_x = local_x - text_x.
    logic [9:0] btn_local_x;
    logic [9:0] btn_local_y;
    assign btn_local_x = lx_st - any_btn_x0;
    assign btn_local_y = ly_st - 10'd8;

    logic signed [15:0] btn_local_x_s;
    logic signed [15:0] btn_local_y_s;
    assign btn_local_x_s = $signed({6'b0, btn_local_x});
    assign btn_local_y_s = $signed({6'b0, btn_local_y});

    logic signed [15:0] mode_rel_x;
    logic signed [15:0] mode_rel_y;
    logic signed [15:0] plus_rel_x;
    logic signed [15:0] plus_rel_y;
    logic signed [15:0] minus_rel_x;
    logic signed [15:0] minus_rel_y;
    assign mode_rel_x  = btn_local_x_s - mode_btn_text_x;
    assign mode_rel_y  = btn_local_y_s - mode_btn_text_y;
    assign plus_rel_x  = btn_local_x_s - plus_text_x;
    assign plus_rel_y  = btn_local_y_s - plus_text_y;
    assign minus_rel_x = btn_local_x_s - minus_text_x;
    assign minus_rel_y = btn_local_y_s - minus_text_y;

    // Text-path char selection
    logic [7:0] text_char;
    logic [4:0] text_gy_sel;
    logic [3:0] text_gx_sel;
    logic       text_in_bounds;

    always_comb begin
        text_char      = 8'h20;  // space (any printable; bg result)
        text_gy_sel    = 5'd0;
        text_gx_sel    = 4'd0;
        text_in_bounds = 1'b0;
        unique case (text_path)
            TXT_FREQ: begin
                text_char      = freq_text[freq_ch_idx*8 +: 8];
                text_gx_sel    = freq_gx;
                text_gy_sel    = freq_gy;
                text_in_bounds = 1'b1;
            end
            TXT_RDS: begin
                text_char      = rds_line[rds_ch_idx*8 +: 8];
                text_gx_sel    = rds_gx;
                text_gy_sel    = rds_gy;
                text_in_bounds = 1'b1;
            end
            TXT_BAND: begin
                text_char      = band_text[band_ch_idx*8 +: 8];
                text_gx_sel    = band_gx;
                text_gy_sel    = band_gy;
                text_in_bounds = 1'b1;
            end
            TXT_DEMOD: begin
                text_char      = demod_label[demod_ch_idx*8 +: 8];
                text_gx_sel    = demod_gx;
                text_gy_sel    = demod_gy;
                text_in_bounds = 1'b1;
            end
            TXT_MODE_BTN, TXT_IMG_MODE: begin
                // Two-char label: ch_idx = (rel_x >> 4) & 1; gx = rel_x & 0xF.
                if (mode_rel_x >= 0 && mode_rel_x < 16'sd32
                    && mode_rel_y >= 0 && mode_rel_y < 16'sd32) begin
                    text_char      = mode_btn_label[mode_rel_x[4]*8 +: 8];
                    text_gx_sel    = mode_rel_x[3:0];
                    text_gy_sel    = mode_rel_y[4:0];
                    text_in_bounds = 1'b1;
                end
            end
            TXT_PLUS: begin
                // One-char "+" label.
                if (plus_rel_x >= 0 && plus_rel_x < 16'sd16
                    && plus_rel_y >= 0 && plus_rel_y < 16'sd32) begin
                    text_char      = 8'h2B;  // '+'
                    text_gx_sel    = plus_rel_x[3:0];
                    text_gy_sel    = plus_rel_y[4:0];
                    text_in_bounds = 1'b1;
                end
            end
            TXT_MINUS: begin
                if (minus_rel_x >= 0 && minus_rel_x < 16'sd16
                    && minus_rel_y >= 0 && minus_rel_y < 16'sd32) begin
                    text_char      = 8'h2D;  // '-'
                    text_gx_sel    = minus_rel_x[3:0];
                    text_gy_sel    = minus_rel_y[4:0];
                    text_in_bounds = 1'b1;
                end
            end
            default: ;
        endcase
    end

    // Normalize char to font ROM index. Range check: [0x20, 0x80); else '?'.
    logic [7:0] char_eff;
    logic [6:0] char_norm;
    assign char_eff  = (text_char >= 8'h20 && text_char < 8'h80)
                       ? text_char : 8'h3F;  // '?'
    assign char_norm = char_eff[6:0] - 7'd32;
    assign font16_addr = {char_norm, text_gy_sel};

    // Glyph bit = font16_data & (1 << (15 - gx)).
    logic glyph_bit;
    assign glyph_bit = text_in_bounds
                       && font16_data[15 - text_gx_sel] == 1'b1;

    // Sprite read for sprite buttons. spx = local_x * 32 / 48,
    // spy = local_y * 32 / 48 (reciprocal mul 43691; verified bit-equiv).
    logic [31:0] spx_mul;
    logic [31:0] spy_mul;
    logic [4:0]  spx;
    logic [4:0]  spy;
    assign spx_mul = {22'b0, btn_local_x} * 32'd43691;
    assign spy_mul = {22'b0, btn_local_y} * 32'd43691;
    assign spx     = spx_mul[20:16];
    assign spy     = spy_mul[20:16];

    // Sprite ID select. status_btn_sprite() from C: FREQ/VOL fixed, MUTE
    // takes mute_sprite_id, others use SPR_ICON_BLANK (unreachable for the
    // 6 main buttons but matches C default).
    logic [7:0] sprite_id_sel;
    always_comb begin
        unique case (any_btn_id)
            BTN_FREQ_UP: sprite_id_sel = SPR_BTN_FREQ_UP;
            BTN_FREQ_DN: sprite_id_sel = SPR_BTN_FREQ_DN;
            BTN_VOL_UP:  sprite_id_sel = SPR_BTN_VOL_UP;
            BTN_VOL_DN:  sprite_id_sel = SPR_BTN_VOL_DN;
            BTN_MUTE:    sprite_id_sel = mute_sprite_id;
            default:     sprite_id_sel = SPR_ICON_BLANK;
        endcase
    end

    // sprite_addr = sprite_id * 1024 + spy * 32 + spx
    //             = {sprite_id[3:0], spy[4:0], spx[4:0]}
    assign sprite_addr = {sprite_id_sel[3:0], spy, spx};

    // brighten_rgb565: saturating add on r/g/b channels then re-pack.
    function automatic logic [15:0] brighten_rgb565(input logic [15:0] px,
                                                    input logic [7:0] add);
        logic [7:0]  r, g, b;
        logic [9:0]  r_sum, g_sum, b_sum;
        logic [7:0]  r_sat, g_sat, b_sat;
        r = {px[15:11], 3'b0};
        g = {px[10:5],  2'b0};
        b = {px[4:0],   3'b0};
        r_sum = {2'b0, r} + {2'b0, add};
        g_sum = {2'b0, g} + {2'b0, add};
        b_sum = {2'b0, b} + {2'b0, add};
        r_sat = r_sum[9:8] == 2'b00 ? r_sum[7:0] : 8'd255;
        g_sat = g_sum[9:8] == 2'b00 ? g_sum[7:0] : 8'd255;
        b_sat = b_sum[9:8] == 2'b00 ? b_sum[7:0] : 8'd255;
        brighten_rgb565 = {r_sat[7:3], g_sat[7:2], b_sat[7:3]};
    endfunction

    // Button render: text path (MODE) or sprite path (FREQ/VOL/MUTE).
    // Edge / inner border first, then label or sprite overlay.
    logic [15:0] btn_text_base;   // before active highlight
    logic [15:0] btn_pixel;
    logic        btn_active;
    assign btn_active = (active_button[2:0] == any_btn_id)
                        && (active_button[7:3] == 5'b0);

    always_comb begin
        // text-button base (edge / inner / fill / ink)
        if (btn_local_x == 10'd0 || btn_local_y == 10'd0
            || btn_local_x == 10'd47 || btn_local_y == 10'd47) begin
            btn_text_base = TB_EDGE;
        end else if (btn_local_x < 10'd3 || btn_local_y < 10'd3
                     || btn_local_x >= 10'd45 || btn_local_y >= 10'd45) begin
            btn_text_base = TB_INNER;
        end else begin
            btn_text_base = TB_FILL;
        end
        if (glyph_bit) btn_text_base = TB_FG;

        if (any_btn_is_text) begin
            // active: brighten by 48 unless px == surrounding bg
            btn_pixel = (btn_active && btn_text_base != any_btn_bg)
                        ? brighten_rgb565(btn_text_base, 8'd48)
                        : btn_text_base;
        end else begin
            // sprite path: transparent (0) → button bg; active → brighten 80.
            if (sprite_data == 16'h0000) begin
                btn_pixel = any_btn_bg;
            end else if (btn_active) begin
                btn_pixel = brighten_rgb565(sprite_data, 8'd80);
            end else begin
                btn_pixel = sprite_data;
            end
        end
    end

    // Status pixel select (priority encode mirrors C if/else chain).
    logic [15:0] status_pixel;
    always_comb begin
        if (in_freq_text) begin
            status_pixel = glyph_bit ? STATUS_FG : STATUS_BG;
        end else if (in_rds_text) begin
            status_pixel = glyph_bit ? STATUS_DIM : STATUS_BG;
        end else if (in_vol_bar) begin
            status_pixel = vol_pixel;
        end else if (in_demod_label) begin
            status_pixel = glyph_bit ? STATUS_FG : STATUS_BG;
        end else if (in_button) begin
            status_pixel = btn_pixel;
        end else begin
            status_pixel = STATUS_BG;
        end
    end

    logic [15:0] spectrum_pixel;
    always_comb begin
        if (in_band_text && glyph_bit) spectrum_pixel = STATUS_DIM;
        else                           spectrum_pixel = spectrum_base_pixel;
    end

    // ── top dispatch ────────────────────────────────────────────────────
    logic [15:0] base;
    always_comb begin
        unique case (region_kind)
            R_STATUS:    base = status_pixel;
            R_SPECTRUM:  base = spectrum_pixel;
            R_WATERFALL: base = fb_under;
            R_GOES:      base = fb_under;
            R_ADSB:      base = fb_under;
            default:     base = 16'h0000;
        endcase
    end

    // shade_image_mode_button: in GOES_FULL / ADSB_FULL, overlay the floating
    // buttons (drawn by the same btn_pixel path, with IMG_BG as surround).
    logic [15:0] post_image_btn;
    assign post_image_btn = in_img_button ? btn_pixel : base;

    // ── shade_overlay (touch crosshair) ──────────────────────────────────
    logic signed [10:0] dx, dy;
    logic        [9:0]  adx, ady;
    assign dx  = $signed({1'b0, x}) - $signed({1'b0, touch_x});
    assign dy  = $signed({1'b0, y}) - $signed({1'b0, touch_y});
    assign adx = dx[10] ? (~dx[9:0] + 10'd1) : dx[9:0];
    assign ady = dy[10] ? (~dy[9:0] + 10'd1) : dy[9:0];

    logic touch_active;
    assign touch_active = flags[UI_FLAG_TOUCH_ACTIVE_BIT];

    always_comb begin
        pixel = post_image_btn;
        if (touch_active) begin
            if (ady == 10'd0 && adx > 10'd4 && adx < 10'd16)      pixel = CROSSHAIR_ARM;
            else if (adx == 10'd0 && ady > 10'd4 && ady < 10'd16) pixel = CROSSHAIR_ARM;
            else if (adx <= 10'd1 && ady <= 10'd1)                pixel = CROSSHAIR_DOT;
        end
    end
endmodule
