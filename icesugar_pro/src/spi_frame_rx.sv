// spi_frame_rx — generic SPI byte deserializer with CS framing.
//
// Generalizes spi_iq_slave: instead of assuming every 32 bits is an IQ sample,
// this emits a plain byte stream and marks the first byte of each CS-active
// window (start-of-frame). A TLV demux downstream uses byte_sof to re-sync its
// parser to the packet header on every CS-fall, so the link can never get
// permanently misaligned.
//
// Same convention as spi_iq_slave: bits shifted MSB-first, sampled on the
// rising edge of spi_clk; shifter reset asynchronously while CS is high.
// byte_valid/byte_data/byte_sof are COMBINATIONAL and asserted during the cycle
// of the byte's 8th bit, so a synchronous consumer (the byte CDC FIFO) captures
// each byte on that bit's own clock edge — including the last byte of a frame,
// before CS deasserts. (A registered pulse would be lost there.)
// One CS-active window carries one TLV packet (header + payload).

module spi_frame_rx (
    input  logic spi_clk,
    input  logic spi_cs_n,
    input  logic spi_mosi,

    output logic       byte_valid,  // high during the 8th-bit cycle of each byte
    output logic       byte_sof,    // 1 when byte_data is the first byte of this CS frame
    output logic [7:0] byte_data
);

logic [2:0] bit_cnt;
logic [7:0] shift;
logic       seen_byte;             // a byte has already completed in this CS window

wire [7:0] next_byte = {shift[6:0], spi_mosi};

assign byte_data  = next_byte;
assign byte_valid = ~spi_cs_n & (bit_cnt == 3'd7);
assign byte_sof   = ~seen_byte;    // meaningful only when byte_valid

initial begin
    bit_cnt   = '0;
    shift     = '0;
    seen_byte = 1'b0;
end

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        bit_cnt   <= '0;
        shift     <= '0;
        seen_byte <= 1'b0;
    end else begin
        shift <= next_byte;
        if (bit_cnt == 3'd7) begin
            bit_cnt   <= 3'd0;
            seen_byte <= 1'b1;     // first (and subsequent) bytes now seen
        end else begin
            bit_cnt <= bit_cnt + 3'd1;
        end
    end
end

endmodule
