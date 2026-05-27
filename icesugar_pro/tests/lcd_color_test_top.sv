module lcd_color_test_top (
    input logic CLK,
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

always_comb begin
    if (x < 11'd800 && y < 10'd480) begin
        LCD_DEN = 1'b1;
        if (x < 11'd267) begin
            LCD_R = 5'd0; LCD_G = 6'd0; LCD_B = 5'd31;
        end else if (x < 11'd534) begin
            LCD_R = 5'd0; LCD_G = 6'd63; LCD_B = 5'd0;
        end else begin
            LCD_R = 5'd31; LCD_G = 6'd0; LCD_B = 5'd0;
        end
    end else begin
        LCD_DEN = 1'b0;
        LCD_R = 5'd0; LCD_G = 6'd0; LCD_B = 5'd0;
    end
end

endmodule

