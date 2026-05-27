module spi_iq_slave (
    input logic spi_clk,
    input logic spi_cs_n,
    input logic spi_mosi,

    output logic [15:0] i_data,
    output logic [15:0] q_data,
    output logic iq_valid
);

logic [4:0] bit_cnt;
logic [31:0] shift;
logic [31:0] next_word;

assign next_word = {shift[30:0], spi_mosi};
assign i_data = next_word[31:16];
assign q_data = next_word[15:0];
assign iq_valid = !spi_cs_n && (bit_cnt == 5'd31);

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        bit_cnt <= 5'd0;
        shift <= '0;
    end else begin
        shift <= next_word;
        if (bit_cnt == 5'd31) begin
            bit_cnt <= 5'd0;
        end else begin
            bit_cnt <= bit_cnt + 5'd1;
        end
    end
end

endmodule

