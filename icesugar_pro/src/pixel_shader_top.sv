// pixel_shader_top — the self-contained, synthesizable live-overlay shader.
//
// Wraps the parity-verified combinational core (pixel_shader.sv) together with
// its three EBR/logic memories so the rest of the gateware sees one block with
// no loose ROM ports:
//   - font_16x32_rom   (label/title glyphs)
//   - sprite_rom       (status-bar button icons)
//   - spectrum_bin_ram (256 magnitude bins; written by the Pico/ingest path)
//
// The "prepared" shader-state inputs (freq_text, label origins, volume_fill_px,
// …) are produced once per frame by pixel_shader_prepare() — on the Pico today,
// or a future on-FPGA prepare engine — and reach this block via the UI state
// shadow (#12). They stay as ports here: this module is exactly the per-pixel
// path of the C reference, now backed by real memories instead of harness arrays.
//
// At integration (#18) this replaces u_lcd's pixel logic: scan_timing drives
// (x,y), the line cache drives fb_under, and `pixel` goes to the LCD pins.
module pixel_shader_top #(
    parameter FONT16_MEM = "build/font_16x32.mem",
    parameter SPRITE_MEM = "build/sprite_rom.mem"
) (
    // Pixel position + framebuffer pixel under the overlay.
    input  logic [9:0]   x,
    input  logic [9:0]   y,
    input  logic [15:0]  fb_under,

    // Prepared UI state (front buffer of the UI state shadow, #12).
    input  logic [1:0]   layout,
    input  logic [1:0]   demod,
    input  logic [7:0]   flags,
    input  logic [7:0]   active_button,
    input  logic [9:0]   touch_x,
    input  logic [9:0]   touch_y,
    input  logic [95:0]  freq_text,
    input  logic [31:0]  demod_label,
    input  logic [191:0] rds_line,
    input  logic [15:0]  mode_btn_label,
    input  logic signed [15:0] mode_btn_text_x,
    input  logic signed [15:0] mode_btn_text_y,
    input  logic signed [15:0] plus_text_x,
    input  logic signed [15:0] plus_text_y,
    input  logic signed [15:0] minus_text_x,
    input  logic signed [15:0] minus_text_y,
    input  logic [15:0]  volume_fill_px,
    input  logic [7:0]   mute_sprite_id,

    // Spectrum bin write port (Pico SPI / ingest writer domain).
    input  logic         spec_wr_clk,
    input  logic         spec_wr_en,
    input  logic [7:0]   spec_wr_addr,
    input  logic [15:0]  spec_wr_data,

    output logic [15:0]  pixel
);
    // ── shader <-> memory nets ───────────────────────────────────────────
    logic [7:0]  spectrum_bin_addr;
    logic [15:0] spectrum_bin_data;
    logic [11:0] font16_addr;
    logic [15:0] font16_data;
    logic [13:0] sprite_addr;
    logic [15:0] sprite_data;

    // ── memories ─────────────────────────────────────────────────────────
    spectrum_bin_ram u_spectrum (
        .wr_clk  (spec_wr_clk),
        .wr_en   (spec_wr_en),
        .wr_addr (spec_wr_addr),
        .wr_data (spec_wr_data),
        .rd_addr (spectrum_bin_addr),
        .rd_data (spectrum_bin_data)
    );

    font_16x32_rom #(.MEMFILE(FONT16_MEM)) u_font16 (
        .addr (font16_addr),
        .data (font16_data)
    );

    sprite_rom #(.MEMFILE(SPRITE_MEM)) u_sprite (
        .addr (sprite_addr),
        .data (sprite_data)
    );

    // ── shader core ──────────────────────────────────────────────────────
    pixel_shader u_shader (
        .x                 (x),
        .y                 (y),
        .fb_under          (fb_under),
        .layout            (layout),
        .demod             (demod),
        .flags             (flags),
        .active_button     (active_button),
        .touch_x           (touch_x),
        .touch_y           (touch_y),
        .freq_text         (freq_text),
        .demod_label       (demod_label),
        .rds_line          (rds_line),
        .mode_btn_label    (mode_btn_label),
        .mode_btn_text_x   (mode_btn_text_x),
        .mode_btn_text_y   (mode_btn_text_y),
        .plus_text_x       (plus_text_x),
        .plus_text_y       (plus_text_y),
        .minus_text_x      (minus_text_x),
        .minus_text_y      (minus_text_y),
        .volume_fill_px    (volume_fill_px),
        .mute_sprite_id    (mute_sprite_id),
        .spectrum_bin_addr (spectrum_bin_addr),
        .spectrum_bin_data (spectrum_bin_data),
        .font16_addr       (font16_addr),
        .font16_data       (font16_data),
        .sprite_addr       (sprite_addr),
        .sprite_data       (sprite_data),
        .pixel             (pixel)
    );
endmodule
