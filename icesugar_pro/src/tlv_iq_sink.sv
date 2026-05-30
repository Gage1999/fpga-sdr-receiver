// tlv_iq_sink — reassemble TLV_IQ payload bytes into {I,Q} sample words.
//
// Consumes the demux payload stream, but only the bytes tagged TLV_IQ. Four
// payload bytes per sample, big-endian, matching the Zynq packing in
// plutosky/src/icesugar_stream.c:
//     byte0 = I[15:8], byte1 = I[7:0], byte2 = Q[15:8], byte3 = Q[7:0]
//
// pl_sop realigns the byte index to 0 at the start of every packet, so a
// payload whose length is not a multiple of 4 simply drops its trailing
// partial sample at the next packet rather than corrupting alignment.

module tlv_iq_sink (
    input  logic clk,
    input  logic rst,

    input  logic       pl_valid,
    input  logic       pl_sop,
    input  logic       pl_eop,    // unused; present for interface symmetry
    input  logic [7:0] pl_byte,
    input  logic [7:0] pl_type,

    output logic signed [15:0] i_data,
    output logic signed [15:0] q_data,
    output logic               iq_word_valid
);

localparam logic [7:0] TLV_IQ = 8'h00;

wire sel = pl_valid && (pl_type == TLV_IQ);

logic [1:0] bidx;
wire  [1:0] idx = pl_sop ? 2'd0 : bidx;   // SOP forces the start of a sample

logic [7:0] b0, b1, b2;

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        bidx          <= 2'd0;
        b0            <= 8'd0;
        b1            <= 8'd0;
        b2            <= 8'd0;
        i_data        <= 16'sd0;
        q_data        <= 16'sd0;
        iq_word_valid <= 1'b0;
    end else begin
        iq_word_valid <= 1'b0;
        if (sel) begin
            case (idx)
                2'd0: b0 <= pl_byte;
                2'd1: b1 <= pl_byte;
                2'd2: b2 <= pl_byte;
                2'd3: begin
                    i_data        <= $signed({b0, b1});
                    q_data        <= $signed({b2, pl_byte});
                    iq_word_valid <= 1'b1;
                end
            endcase
            bidx <= (idx == 2'd3) ? 2'd0 : (idx + 2'd1);
        end
    end
end

endmodule
