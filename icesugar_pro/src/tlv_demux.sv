// tlv_demux — parse the v1 TLV framing and route payload bytes by type.
//
// Wire format (one CS-active window = one packet):
//   byte 0      : TYPE
//   byte 1..2   : LEN[15:0]   (payload byte count, big-endian)
//   byte 3..    : payload (LEN bytes)
//
// Input is a one-byte-per-cycle stream in the CLK domain (top.sv drains the
// byte CDC FIFO into it). The demux never stalls — it consumes whatever arrives.
// byte_sof (in_sof) marks the first byte of a CS frame and ALWAYS restarts the
// parser at the TYPE field, so a glitch can never leave us permanently
// misaligned: the next CS-fall re-syncs us for free.
//
// Output is a single typed payload bus (pl_*). Downstream sinks filter on
// pl_type, so adding a future mode is just another sink watching a new type —
// no change here. Status counters are exposed for LCD-debug / logic-analyzer
// bring-up; they do not affect the wire format.

module tlv_demux (
    input  logic clk,
    input  logic rst,

    // Byte stream in (CLK domain), one byte per asserted cycle.
    input  logic       in_valid,
    input  logic       in_sof,    // 1 = first byte of a CS frame (the TYPE byte)
    input  logic [7:0] in_byte,

    // Payload stream out (CLK domain).
    output logic       pl_valid,  // a payload byte is on pl_byte this cycle
    output logic       pl_sop,    // first payload byte of the packet
    output logic       pl_eop,    // last payload byte of the packet
    output logic [7:0] pl_byte,
    output logic [7:0] pl_type,   // TYPE of the packet this payload belongs to

    // Status / debug (CLK domain).
    output logic [15:0] iq_pkt_count,
    output logic [15:0] img_pkt_count,
    output logic [15:0] obj_pkt_count,
    output logic [15:0] unknown_count,
    output logic [15:0] short_count,   // new SOF arrived before LEN was satisfied
    output logic [15:0] stray_count,   // byte without SOF while expecting a header
    output logic [7:0]  last_type
);

localparam logic [7:0] TLV_IQ          = 8'h00;
localparam logic [7:0] TLV_IMAGE_ROW   = 8'h01;
localparam logic [7:0] TLV_OBJECT_LIST = 8'h02;

localparam logic [1:0] S_TYPE    = 2'd0;
localparam logic [1:0] S_LEN_HI  = 2'd1;
localparam logic [1:0] S_LEN_LO  = 2'd2;
localparam logic [1:0] S_PAYLOAD = 2'd3;

logic [1:0]  state;
logic [7:0]  cur_type;
logic [7:0]  len_hi;
logic [15:0] remaining;
logic        payload_first;

wire [15:0] len_full = {len_hi, in_byte};   // meaningful only in S_LEN_LO

// Per-type packet-complete counter bump.
task automatic count_packet(input logic [7:0] t);
    case (t)
        TLV_IQ:          iq_pkt_count  <= iq_pkt_count  + 16'd1;
        TLV_IMAGE_ROW:   img_pkt_count <= img_pkt_count + 16'd1;
        TLV_OBJECT_LIST: obj_pkt_count <= obj_pkt_count + 16'd1;
        default:         unknown_count <= unknown_count + 16'd1;
    endcase
endtask

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        state         <= S_TYPE;
        cur_type      <= 8'd0;
        len_hi        <= 8'd0;
        remaining     <= 16'd0;
        payload_first <= 1'b0;
        pl_valid      <= 1'b0;
        pl_sop        <= 1'b0;
        pl_eop        <= 1'b0;
        pl_byte       <= 8'd0;
        pl_type       <= 8'd0;
        iq_pkt_count  <= 16'd0;
        img_pkt_count <= 16'd0;
        obj_pkt_count <= 16'd0;
        unknown_count <= 16'd0;
        short_count   <= 16'd0;
        stray_count   <= 16'd0;
        last_type     <= 8'd0;
    end else begin
        // Payload strobes default low; pulse only on a routed payload byte.
        pl_valid <= 1'b0;
        pl_sop   <= 1'b0;
        pl_eop   <= 1'b0;

        if (in_valid) begin
            if (in_sof) begin
                // Start of a new packet. Count an abort if we were mid-packet.
                if (state != S_TYPE)
                    short_count <= short_count + 16'd1;
                cur_type  <= in_byte;
                last_type <= in_byte;
                state     <= S_LEN_HI;
            end else begin
                case (state)
                    S_TYPE: begin
                        // Byte with no SOF while between packets — framing noise.
                        stray_count <= stray_count + 16'd1;
                    end
                    S_LEN_HI: begin
                        len_hi <= in_byte;
                        state  <= S_LEN_LO;
                    end
                    S_LEN_LO: begin
                        remaining <= len_full;
                        if (len_full == 16'd0) begin
                            count_packet(cur_type);   // zero-length packet
                            state <= S_TYPE;
                        end else begin
                            payload_first <= 1'b1;
                            state         <= S_PAYLOAD;
                        end
                    end
                    S_PAYLOAD: begin
                        pl_valid      <= 1'b1;
                        pl_byte       <= in_byte;
                        pl_type       <= cur_type;
                        pl_sop        <= payload_first;
                        pl_eop        <= (remaining == 16'd1);
                        payload_first <= 1'b0;
                        remaining     <= remaining - 16'd1;
                        if (remaining == 16'd1) begin
                            count_packet(cur_type);
                            state <= S_TYPE;
                        end
                    end
                    default: state <= S_TYPE;
                endcase
            end
        end
    end
end

endmodule
