module color_lut (
    input logic [7:0] magnitude,
    output logic [15:0] color
);

logic [7:0] r, g, b;

always_comb begin
    if (magnitude < 8'd32) begin
        r = 8'd0;
        g = 8'd0;
        b = {magnitude[4:0], 3'b000};
    end else if (magnitude < 8'd96) begin
        r = 8'd0;
        g = {magnitude[5:0], 2'b00};
        b = 8'd255;
    end else if (magnitude < 8'd160) begin
        r = {magnitude[5:0], 2'b00};
        g = 8'd255;
        b = 8'd255 - {magnitude[5:0], 2'b00};
    end else begin
        r = 8'd255;
        g = 8'd255 - {magnitude[5:0], 2'b00};
        b = 8'd0;
    end
    color = {r[7:3], g[7:2], b[7:3]};
end

endmodule

