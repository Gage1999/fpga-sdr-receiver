module lcd (
    input logic rst,
    input logic pclk,
    input logic [2:0] mode,
    input logic [7:0] volume,
    input logic mute,
    input logic [7:0] dbg_rx_count,
    input logic [7:0] dbg_bin_count,
    input logic [7:0] dbg_last_mag,
    input logic [31:0] rx_sps_bcd,

    input logic [7:0] wf_magnitude,
    output logic [7:0] wf_bin,
    output logic [8:0] wf_row_age,

    output logic LCD_DE,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B
);

logic [10:0] x;
logic [9:0] y;

localparam MODE_FM = 3'd0;
localparam MODE_ADSB = 3'd1;
localparam MODE_APT = 3'd2;
localparam MODE_DIAG = 3'd7;

localparam [10:0] STATUS_TEXT_X = 11'd664;
localparam [9:0] STATUS_TEXT_Y = 10'd460;
localparam [10:0] STATUS_TEXT_W = 11'd128;
localparam [9:0] STATUS_TEXT_H = 10'd16;

function automatic logic [7:0] digit_char(input logic [3:0] digit);
    begin
        digit_char = 8'h30 + {4'd0, digit};
    end
endfunction

function automatic logic [7:0] sps_char_at(
    input logic [4:0] col,
    input logic [31:0] bcd
);
    begin
        case (col)
            5'd0: sps_char_at = 8'h52; // R
            5'd1: sps_char_at = 8'h58; // X
            5'd2: sps_char_at = 8'h3a; // :
            5'd3: sps_char_at = 8'h20;
            5'd4: sps_char_at = (|bcd[31:28]) ? digit_char(bcd[31:28]) : 8'h20;
            5'd5: sps_char_at = (|bcd[31:24]) ? digit_char(bcd[27:24]) : 8'h20;
            5'd6: sps_char_at = (|bcd[31:20]) ? digit_char(bcd[23:20]) : 8'h20;
            5'd7: sps_char_at = (|bcd[31:16]) ? digit_char(bcd[19:16]) : 8'h20;
            5'd8: sps_char_at = (|bcd[31:12]) ? digit_char(bcd[15:12]) : 8'h20;
            5'd9: sps_char_at = (|bcd[31:8]) ? digit_char(bcd[11:8]) : 8'h20;
            5'd10: sps_char_at = (|bcd[31:4]) ? digit_char(bcd[7:4]) : 8'h20;
            5'd11: sps_char_at = digit_char(bcd[3:0]);
            5'd12: sps_char_at = 8'h20;
            5'd13: sps_char_at = 8'h53; // S
            5'd14: sps_char_at = 8'h50; // P
            5'd15: sps_char_at = 8'h53; // S
            default: sps_char_at = 8'h20;
        endcase
    end
endfunction

// Timing
always_ff @(posedge pclk) begin
    if (rst) begin
        x <= 11'd0;
        y <= 10'd0;
    end else begin
        if (x < 11'd1055) begin
            x <= x + 11'd1;
        end else begin
            x <= 11'd0;
            y <= (y < 10'd524) ? y + 10'd1 : 10'd0;
        end
    end
end

// Waterfall lookup
logic [7:0] bin_req;
logic [7:0] display_bin;
logic [8:0] row_age_req;
logic in_wf;
logic [22:0] bin_product;

always_comb begin
    in_wf = (mode == MODE_FM) && (x < 11'd768) && (y < 10'd360);
    bin_product = 23'(x) * 23'd2731;
    display_bin = bin_product[20:13];
    bin_req = in_wf ? display_bin + 8'd128 : 8'd0;
    row_age_req = in_wf ? 9'(y) : 9'd0;
end

assign wf_bin = bin_req;
assign wf_row_age = row_age_req;

logic [15:0] wf_color;

color_lut u_lut (
    .magnitude (wf_magnitude),
    .color (wf_color)
);

logic in_status_text;
logic [10:0] status_dx;
logic [9:0] status_dy;
logic [4:0] status_col;
logic [2:0] status_glyph_x;
logic [3:0] status_glyph_y;
logic [7:0] status_char;
logic [7:0] status_glyph_bits;
logic status_text_pixel;

font8x16_rom u_status_font (
    .ascii (status_char),
    .row (status_glyph_y),
    .bits (status_glyph_bits)
);

always_comb begin
    in_status_text = (mode == MODE_FM) &&
        (x >= STATUS_TEXT_X) && (x < STATUS_TEXT_X + STATUS_TEXT_W) &&
        (y >= STATUS_TEXT_Y) && (y < STATUS_TEXT_Y + STATUS_TEXT_H);
    status_dx = x - STATUS_TEXT_X;
    status_dy = y - STATUS_TEXT_Y;
    status_col = status_dx[7:3];
    status_glyph_x = status_dx[2:0];
    status_glyph_y = status_dy[3:0];
    status_char = sps_char_at(status_col, rx_sps_bcd);
    status_text_pixel = in_status_text && status_glyph_bits[3'd7 - status_glyph_x];
end

logic prev_in_wf;
logic prev_active;
logic [15:0] bg_color;
logic [15:0] pixel_color;

always_ff @(posedge pclk)
    prev_in_wf <= in_wf && (x < 11'd800) && (y < 10'd480);

always_comb begin
    prev_active = (x > 11'd0 || y > 10'd0);
end

always_comb begin
    bg_color = 16'h0000;
    if (mode == MODE_FM) begin
        if (y >= 10'd372 && y < 10'd388 && x < {3'b000, volume})
            bg_color = mute ? 16'hf800 : 16'h07e0;
        else if (y >= 10'd396 && y < 10'd412 && x < 11'd96)
            bg_color = 16'h001f;
        else if (y >= 10'd420 && y < 10'd432 && x < {3'b000, dbg_rx_count})
            bg_color = 16'hf800;
        else if (y >= 10'd440 && y < 10'd452 && x < {3'b000, dbg_bin_count})
            bg_color = 16'hffe0;
        else if (y >= 10'd460 && y < 10'd472 && x < {3'b000, dbg_last_mag})
            bg_color = 16'h07ff;
    end else if (mode == MODE_ADSB) begin
        bg_color = ((x[5:0] == 6'd0) || (y[5:0] == 6'd0)) ? 16'h07e0 : 16'h0020;
    end else if (mode == MODE_APT) begin
        bg_color = y[5] ? 16'h39e7 : 16'h001f;
    end else if (mode == MODE_DIAG) begin
        bg_color = x[5] ? 16'hf800 : 16'h001f;
    end
end

always_comb begin
    if (!rst && x < 11'd800 && y < 10'd480) begin
        LCD_DE = 1'b1;
        if (prev_in_wf) begin
            pixel_color = wf_color;
        end else if (status_text_pixel) begin
            pixel_color = 16'hffff;
        end else begin
            pixel_color = bg_color;
        end
        LCD_R = pixel_color[15:11];
        LCD_G = pixel_color[10:5];
        LCD_B = pixel_color[4:0];
    end else begin
        LCD_DE = 1'b0;
        pixel_color = 16'h0000;
        LCD_R = 5'd0;
        LCD_G = 6'd0;
        LCD_B = 5'd0;
    end
end

endmodule
