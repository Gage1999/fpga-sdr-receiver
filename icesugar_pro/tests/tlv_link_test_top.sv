// tlv_link_test_top - quantitative on-hardware functional test for the TLV

module tlv_link_test_top (
    input  logic CLK,

    input  logic spi_clk,
    input  logic cs,
    input  logic mosi,

    output logic LCD_CLK,
    output logic LCD_DEN,
    output logic [4:0] LCD_R,
    output logic [5:0] LCD_G,
    output logic [4:0] LCD_B
);

assign LCD_CLK = CLK;

// Resets (one per clock domain).
logic [3:0] spi_rst_cnt = 4'd0;
logic       spi_rst = 1'b1;
always_ff @(posedge spi_clk) begin
    if (!spi_rst_cnt[3]) begin spi_rst_cnt <= spi_rst_cnt + 4'd1; spi_rst <= 1'b1; end
    else                   spi_rst <= 1'b0;
end

logic [3:0] sys_rst_cnt = 4'd0;
logic       sys_rst = 1'b1;
always_ff @(posedge CLK) begin
    if (!sys_rst_cnt[3]) begin sys_rst_cnt <= sys_rst_cnt + 4'd1; sys_rst <= 1'b1; end
    else                   sys_rst <= 1'b0;
end

// SPI byte deserializer.
logic       fr_valid, fr_sof;
logic [7:0] fr_byte;
spi_frame_rx u_fr (
    .spi_clk(spi_clk), .spi_cs_n(cs), .spi_mosi(mosi),
    .byte_valid(fr_valid), .byte_sof(fr_sof), .byte_data(fr_byte)
);

// Byte CDC (spi_clk -> CLK).
logic [8:0] brd;
logic       bemp, bful, bpop, bpop_d;
async_fifo #(.WIDTH(9), .DEPTH(32)) u_bf (
    .wclk(spi_clk), .wrst(spi_rst), .wdata({fr_sof, fr_byte}),
    .wpush(fr_valid & ~bful & ~spi_rst), .wfull(bful),
    .rclk(CLK), .rrst(sys_rst), .rdata(brd), .rpop(bpop), .rempty(bemp)
);
assign bpop = ~bemp;
always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) bpop_d <= 1'b0;
    else         bpop_d <= bpop;
end

// Demux.
logic       pl_valid, pl_sop, pl_eop;
logic [7:0] pl_byte, pl_type;
logic [15:0] iq_pkts, img_pkts, obj_pkts, unknown_c, short_c, stray_c;
logic [7:0]  last_type;
tlv_demux u_dm (
    .clk(CLK), .rst(sys_rst),
    .in_valid(bpop_d), .in_sof(brd[8]), .in_byte(brd[7:0]),
    .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
    .pl_byte(pl_byte), .pl_type(pl_type),
    .iq_pkt_count(iq_pkts), .img_pkt_count(img_pkts), .obj_pkt_count(obj_pkts),
    .unknown_count(unknown_c), .short_count(short_c), .stray_count(stray_c),
    .last_type(last_type)
);

// IQ sink.
logic signed [15:0] oi, oq;
logic               ov;
tlv_iq_sink u_sink (
    .clk(CLK), .rst(sys_rst),
    .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
    .pl_byte(pl_byte), .pl_type(pl_type),
    .i_data(oi), .q_data(oq), .iq_word_valid(ov)
);

// +1 invariant check on reconstructed IQ words.
logic [31:0] last_word, total_count, err_count;
logic        seeded;
wire  [31:0] rx_word = {oi, oq};
always_ff @(posedge CLK or posedge sys_rst) begin
    if (sys_rst) begin
        last_word <= 32'd0; total_count <= 32'd0; err_count <= 32'd0; seeded <= 1'b0;
    end else if (ov) begin
        if (seeded && (rx_word != (last_word + 32'd1)))
            err_count <= err_count + 32'd1;
        last_word   <= rx_word;
        total_count <= total_count + 32'd1;
        seeded      <= 1'b1;
    end
end

// Display.
logic [10:0] x = 11'd0;
logic [9:0]  y = 10'd0;
always_ff @(posedge CLK) begin
    if (x < 11'd1055) x <= x + 11'd1;
    else begin x <= 11'd0; y <= (y < 10'd524) ? y + 10'd1 : 10'd0; end
end

wire active  = (x < 11'd800) && (y < 10'd480);
wire in_bits = (x < 11'd512);
wire [4:0] bidx = x[8:4];

localparam logic [15:0] C_WHITE=16'hFFFF, C_GREEN=16'h07E0, C_RED=16'hF800,
                        C_BLUE=16'h001F, C_CYAN=16'h07FF, C_YEL=16'hFFE0,
                        C_MAG=16'hF81F, C_ORANGE=16'hFC00;
localparam logic [15:0] C_DKR=16'h2000, C_DKC=16'h0208, C_DKY=16'h2100,
                        C_DKM=16'h2008, C_DKW=16'h2104, C_DKO=16'h2080;

function automatic logic [15:0] bitcell(input [31:0] val, input [15:0] on, input [15:0] off);
    bitcell = val[5'd31 - bidx] ? on : off;
endfunction

logic [15:0] color;
always_comb begin
    color = 16'h0000;
    if (active) begin
        if (y < 10'd44) begin
            if (!seeded)             color = C_BLUE;
            else if (err_count != 0) color = C_RED;
            else                     color = C_GREEN;
        end else if (in_bits) begin
            if      (y >= 10'd48  && y < 10'd78)  color = bitcell(err_count,          C_RED,    C_DKR);
            else if (y >= 10'd86  && y < 10'd116) color = bitcell({16'd0, iq_pkts},    C_CYAN,   C_DKC);
            else if (y >= 10'd124 && y < 10'd154) color = bitcell({16'd0, img_pkts},   C_YEL,    C_DKY);
            else if (y >= 10'd162 && y < 10'd192) color = bitcell({16'd0, obj_pkts},   C_MAG,    C_DKM);
            else if (y >= 10'd200 && y < 10'd230) color = bitcell({16'd0, unknown_c},  C_WHITE,  C_DKW);
            else if (y >= 10'd238 && y < 10'd268) color = bitcell({16'd0, short_c},    C_ORANGE, C_DKO);
            else if (y >= 10'd276 && y < 10'd306) color = bitcell({16'd0, stray_c},    C_RED,    C_DKR);
        end
    end
end

always_comb begin
    LCD_DEN = active;
    LCD_R   = active ? color[15:11] : 5'd0;
    LCD_G   = active ? color[10:5]  : 6'd0;
    LCD_B   = active ? color[4:0]   : 5'd0;
end

endmodule
