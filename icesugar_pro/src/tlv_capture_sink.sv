// tlv_capture_sink — v1 stub sink for decoded-data TLV types.
//
// The SDRAM compositor that will eventually consume IMAGE_ROW / OBJECT_LIST
// packets isn't part of the FM bitstream yet, so this lightweight sink stands
// in: it counts packets of its CAP_TYPE, records the last packet's length, and
// latches the payload into a small BRAM that a debug reader (LCD or logic
// analyzer) can inspect. That's enough to prove the demux routes a given type
// end-to-end without depending on the unbuilt SDRAM path.
//
// Payload longer than DEPTH is truncated into the buffer (write stops) but
// last_len still reports the true length, so over-long packets are visible.

module tlv_capture_sink #(
    parameter logic [7:0] CAP_TYPE = 8'h01,
    parameter int         DEPTH    = 256
) (
    input  logic clk,
    input  logic rst,

    input  logic       pl_valid,
    input  logic       pl_sop,
    input  logic       pl_eop,
    input  logic [7:0] pl_byte,
    input  logic [7:0] pl_type,

    output logic [15:0] pkt_count,
    output logic [15:0] last_len,

    // Debug read port (registered, infers EBR).
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [7:0]               rd_data
);

localparam int AW = $clog2(DEPTH);

logic [7:0] mem [0:DEPTH-1];

logic [15:0] bytecnt;

wire sel = pl_valid && (pl_type == CAP_TYPE);

// SOP restarts the byte counter for this packet; bytecnt is the byte index.
wire [15:0] eff_cnt = pl_sop ? 16'd0 : bytecnt;

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        bytecnt   <= 16'd0;
        pkt_count <= 16'd0;
        last_len  <= 16'd0;
    end else if (sel) begin
        if (eff_cnt < DEPTH)
            mem[eff_cnt[AW-1:0]] <= pl_byte;
        bytecnt <= eff_cnt + 16'd1;
        if (pl_eop) begin
            last_len  <= eff_cnt + 16'd1;
            pkt_count <= pkt_count + 16'd1;
        end
    end
end

always_ff @(posedge clk) begin
    rd_data <= mem[rd_addr];
end

endmodule
