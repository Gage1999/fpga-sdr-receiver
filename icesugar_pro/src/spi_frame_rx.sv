module spi_frame_rx (
    input logic spi_clk,
    input logic spi_cs_n,
    input logic spi_mosi,

    output logic byte_valid,
    output logic byte_sof,
    output logic [7:0] byte_data
);

logic [2:0] bit_cnt;
logic [7:0] shift;
logic seen_byte;

wire [7:0] next_byte = {shift[6:0], spi_mosi};

assign byte_data = next_byte;
assign byte_valid = ~spi_cs_n & (bit_cnt == 3'd7);
assign byte_sof = ~seen_byte;

initial begin
    bit_cnt = '0;
    shift = '0;
    seen_byte = 1'b0;
end

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        bit_cnt <= '0;
        shift <= '0;
        seen_byte <= 1'b0;
    end else begin
        shift <= next_byte;
        if (bit_cnt == 3'd7) begin
            bit_cnt <= 3'd0;
            seen_byte <= 1'b1;
        end else begin
            bit_cnt <= bit_cnt + 3'd1;
        end
    end
end

endmodule
