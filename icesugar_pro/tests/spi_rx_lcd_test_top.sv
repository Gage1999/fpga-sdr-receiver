module spi_rx_lcd_test_top (
    input logic CLK,

    input logic spi_clk,
    input logic cs,
    input logic mosi,

    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B
);

logic [10:0] x = '0;
logic [9:0] y = '0;

always_ff @(posedge CLK) begin
    if (x < 11'd1055) begin
        x <= x + 11'd1;
    end else begin
        x <= 11'd0;
        y <= (y < 10'd524) ? y + 10'd1 : 10'd0;
    end
end

assign LCD_CLK = CLK;

logic [15:0] spi_i;
logic [15:0] spi_q;
logic spi_iq_valid;

spi_iq_slave u_spi_iq (
    .spi_clk (spi_clk),
    .spi_cs_n (cs),
    .spi_mosi (mosi),
    .i_data (spi_i),
    .q_data (spi_q),
    .iq_valid (spi_iq_valid)
);

logic [15:0] last_i_spi = '0;
logic [15:0] last_q_spi = '0;
logic [15:0] word_count_spi = '0;
logic word_toggle_spi = 1'b0;
logic [15:0] sck_count_spi = '0;
logic [15:0] cs_low_count_spi = '0;
logic [15:0] mosi_one_count_spi = '0;
logic sck_toggle_spi = 1'b0;
logic [4:0] raw_bit_count_spi = '0;
logic [30:0] raw_shift_spi = '0;
logic [31:0] raw_word_spi = '0;
logic [15:0] raw_word_count_spi = '0;
logic raw_word_toggle_spi = 1'b0;

always_ff @(posedge spi_clk or posedge cs) begin
    if (cs) begin
        last_i_spi <= last_i_spi;
        last_q_spi <= last_q_spi;
        word_count_spi <= word_count_spi;
        word_toggle_spi <= word_toggle_spi;
    end else if (spi_iq_valid) begin
        last_i_spi <= spi_i;
        last_q_spi <= spi_q;
        word_count_spi <= word_count_spi + 16'd1;
        word_toggle_spi <= ~word_toggle_spi;
    end
end

always_ff @(posedge spi_clk) begin
    sck_count_spi <= sck_count_spi + 16'd1;
    sck_toggle_spi <= ~sck_toggle_spi;
    if (!cs)
        cs_low_count_spi <= cs_low_count_spi + 16'd1;
    if (mosi)
        mosi_one_count_spi <= mosi_one_count_spi + 16'd1;

    raw_shift_spi <= {raw_shift_spi[29:0], mosi};
    if (raw_bit_count_spi == 5'd31) begin
        raw_word_spi <= {raw_shift_spi, mosi};
        raw_word_count_spi <= raw_word_count_spi + 16'd1;
        raw_word_toggle_spi <= ~raw_word_toggle_spi;
        raw_bit_count_spi <= 5'd0;
    end else begin
        raw_bit_count_spi <= raw_bit_count_spi + 5'd1;
    end
end

logic word_meta = 1'b0;
logic word_sync = 1'b0;
logic word_sync_d = 1'b0;
logic sck_meta = 1'b0;
logic sck_sync = 1'b0;
logic sck_sync_d = 1'b0;
logic raw_meta = 1'b0;
logic raw_sync = 1'b0;
logic raw_sync_d = 1'b0;
logic [15:0] last_i = '0;
logic [15:0] last_q = '0;
logic [15:0] word_count = '0;
logic [15:0] sck_count = '0;
logic [15:0] cs_low_count = '0;
logic [15:0] mosi_one_count = '0;
logic [31:0] raw_word = '0;
logic [15:0] raw_word_count = '0;
logic [23:0] recent_timer = '0;
logic [23:0] sck_recent_timer = '0;
logic [23:0] raw_recent_timer = '0;
logic got_word = 1'b0;
logic got_sck = 1'b0;
logic got_raw_word = 1'b0;
logic cs_level = 1'b1;
logic mosi_level = 1'b0;

always_ff @(posedge CLK) begin
    cs_level <= cs;
    mosi_level <= mosi;

    word_meta <= word_toggle_spi;
    word_sync <= word_meta;
    word_sync_d <= word_sync;
    sck_meta <= sck_toggle_spi;
    sck_sync <= sck_meta;
    sck_sync_d <= sck_sync;
    raw_meta <= raw_word_toggle_spi;
    raw_sync <= raw_meta;
    raw_sync_d <= raw_sync;

    if (word_sync != word_sync_d) begin
        last_i <= last_i_spi;
        last_q <= last_q_spi;
        word_count <= word_count_spi;
        recent_timer <= 24'hffffff;
        got_word <= 1'b1;
    end else if (recent_timer != 24'd0) begin
        recent_timer <= recent_timer - 24'd1;
    end

    if (sck_sync != sck_sync_d) begin
        sck_count <= sck_count_spi;
        cs_low_count <= cs_low_count_spi;
        mosi_one_count <= mosi_one_count_spi;
        sck_recent_timer <= 24'hffffff;
        got_sck <= 1'b1;
    end else if (sck_recent_timer != 24'd0) begin
        sck_recent_timer <= sck_recent_timer - 24'd1;
    end

    if (raw_sync != raw_sync_d) begin
        raw_word <= raw_word_spi;
        raw_word_count <= raw_word_count_spi;
        raw_recent_timer <= 24'hffffff;
        got_raw_word <= 1'b1;
    end else if (raw_recent_timer != 24'd0) begin
        raw_recent_timer <= raw_recent_timer - 24'd1;
    end
end

logic active;
logic recent;
logic sck_recent;
logic raw_recent;
logic [3:0] bit_idx;
logic bit_on;
logic [15:0] color;

assign active = (x < 11'd800) && (y < 10'd480);
assign recent = (recent_timer != 24'd0);
assign sck_recent = (sck_recent_timer != 24'd0);
assign raw_recent = (raw_recent_timer != 24'd0);
assign bit_idx = 4'(x[8:5]);

always_comb begin
    color = 16'h0000;
    bit_on = 1'b0;

    if (active) begin
        if (y < 10'd60) begin
            if (!got_word)
                color = 16'h8000;
            else if (recent)
                color = word_count[4] ? 16'h07e0 : 16'h03e0;
            else
                color = 16'h4200;
        end else if (y >= 10'd70 && y < 10'd110) begin
            if (!got_sck)
                color = 16'h0010;
            else if (sck_recent)
                color = 16'h001f;
            else
                color = 16'h0004;
        end else if (y >= 10'd120 && y < 10'd160) begin
            if (!cs_level)
                color = 16'hf800;
            else if (x < {3'b000, cs_low_count[7:0]})
                color = 16'h7800;
        end else if (y >= 10'd170 && y < 10'd210) begin
            if (mosi_level)
                color = 16'hffff;
            else if (x < {3'b000, mosi_one_count[7:0]})
                color = 16'h8410;
        end else if (y >= 10'd220 && y < 10'd250) begin
            if (!got_raw_word)
                color = 16'h4008;
            else if (raw_recent)
                color = raw_word_count[4] ? 16'hf81f : 16'h8010;
            else
                color = 16'h4008;
        end else if (y >= 10'd260 && y < 10'd305 && x < 11'd512) begin
            bit_on = last_i[15 - bit_idx];
            color = bit_on ? 16'h07e0 : 16'h0100;
        end else if (y >= 10'd325 && y < 10'd370 && x < 11'd512) begin
            bit_on = last_q[15 - bit_idx];
            color = bit_on ? 16'h001f : 16'h0004;
        end else if (y >= 10'd390 && y < 10'd425 && x < {3'b000, word_count[7:0]}) begin
            color = 16'hffe0;
        end else if (y >= 10'd435 && y < 10'd470 && x < {3'b000, sck_count[7:0]}) begin
            color = 16'h07ff;
        end else if (x < 11'd24 && recent) begin
            color = 16'hffff;
        end
    end
end

always_comb begin
    LCD_DEN = active;
    LCD_R = active ? color[15:11] : 5'd0;
    LCD_G = active ? color[10:5] : 6'd0;
    LCD_B = active ? color[4:0] : 5'd0;
end

endmodule
