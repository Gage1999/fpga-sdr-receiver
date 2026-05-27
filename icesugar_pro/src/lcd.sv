module lcd (
    input logic rst,
    input logic pclk,
    input logic [2:0] mode,
    input logic [7:0] volume,
    input logic mute,
    input logic [7:0] dbg_rx_count,
    input logic [7:0] dbg_bin_count,
    input logic [7:0] dbg_last_mag,

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

logic prev_in_wf;
logic prev_active;
logic [15:0] bg_color;

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
            LCD_R = wf_color[15:11];
            LCD_G = wf_color[10:5];
            LCD_B = wf_color[4:0];
        end else begin
            LCD_R = bg_color[15:11];
            LCD_G = bg_color[10:5];
            LCD_B = bg_color[4:0];
        end
    end else begin
        LCD_DE = 1'b0;
        LCD_R = 5'd0;
        LCD_G = 6'd0;
        LCD_B = 5'd0;
    end
end

endmodule

