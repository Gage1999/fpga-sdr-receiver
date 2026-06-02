module spi_backchannel (
    input  logic        clk,
    input  logic        rst,

    input  logic        cmd_valid,
    input  logic [7:0]  cmd,
    input  logic [31:0] arg,

    input  logic        spi_clk,
    input  logic        spi_rst,
    input  logic        spi_cs_n,
    output logic        spi_miso,

    output logic        busy,
    output logic [15:0] dropped_count
);

localparam logic [7:0] FRAME_MAGIC = 8'hA5;
localparam logic [7:0] OP_RADIO_COMMAND = 8'h06;
localparam logic [15:0] RADIO_COMMAND_LEN = 16'd5;

localparam logic [7:0] CMD_SET_MODE   = 8'h01;
localparam logic [7:0] CMD_SET_VOLUME = 8'h02;
localparam logic [7:0] CMD_SET_FREQ   = 8'h03;

logic [39:0] frame_payload_sys;
logic        req_toggle_sys;
logic        ack_meta_sys, ack_sync_sys;

logic        req_meta_spi, req_sync_spi, req_seen_spi;
logic        ack_toggle_spi;
logic [39:0] frame_payload_spi;
logic [7:0]  shift_spi;
logic [2:0]  bit_cnt_spi;
logic [3:0]  byte_idx_spi;
logic        frame_active_spi;
logic        frame_available_spi;
logic        frame_sent_this_cs_spi;
logic [2:0]  pending_mask_sys;
logic [31:0] pending_mode_arg_sys;
logic [31:0] pending_volume_arg_sys;
logic [31:0] pending_freq_arg_sys;

wire forward_cmd =
    (cmd == CMD_SET_MODE) ||
    (cmd == CMD_SET_VOLUME) ||
    (cmd == CMD_SET_FREQ);

assign busy = (req_toggle_sys != ack_sync_sys);

function automatic logic [15:0] crc16_update(input logic [15:0] crc_in, input logic [7:0] data);
    logic [15:0] crc;
    integer b;
    begin
        crc = crc_in ^ {data, 8'h00};
        for (b = 0; b < 8; b = b + 1) begin
            if (crc[15])
                crc = {crc[14:0], 1'b0} ^ 16'h1021;
            else
                crc = {crc[14:0], 1'b0};
        end
        crc16_update = crc;
    end
endfunction

function automatic logic [15:0] frame_crc(input logic [39:0] payload);
    logic [15:0] crc;
    begin
        crc = 16'hFFFF;
        crc = crc16_update(crc, OP_RADIO_COMMAND);
        crc = crc16_update(crc, RADIO_COMMAND_LEN[7:0]);
        crc = crc16_update(crc, RADIO_COMMAND_LEN[15:8]);
        crc = crc16_update(crc, payload[39:32]);
        crc = crc16_update(crc, payload[7:0]);
        crc = crc16_update(crc, payload[15:8]);
        crc = crc16_update(crc, payload[23:16]);
        crc = crc16_update(crc, payload[31:24]);
        frame_crc = crc;
    end
endfunction

function automatic logic [7:0] frame_byte(
    input logic [3:0] idx,
    input logic [39:0] payload
);
    logic [15:0] crc;
    begin
        crc = frame_crc(payload);
        case (idx)
            4'd0: frame_byte = FRAME_MAGIC;
            4'd1: frame_byte = OP_RADIO_COMMAND;
            4'd2: frame_byte = RADIO_COMMAND_LEN[7:0];
            4'd3: frame_byte = RADIO_COMMAND_LEN[15:8];
            4'd4: frame_byte = payload[39:32];
            4'd5: frame_byte = payload[7:0];
            4'd6: frame_byte = payload[15:8];
            4'd7: frame_byte = payload[23:16];
            4'd8: frame_byte = payload[31:24];
            4'd9: frame_byte = crc[7:0];
            4'd10: frame_byte = crc[15:8];
            default: frame_byte = 8'h00;
        endcase
    end
endfunction

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        frame_payload_sys <= '0;
        req_toggle_sys <= 1'b0;
        ack_meta_sys <= 1'b0;
        ack_sync_sys <= 1'b0;
        dropped_count <= '0;
        pending_mask_sys <= '0;
        pending_mode_arg_sys <= '0;
        pending_volume_arg_sys <= '0;
        pending_freq_arg_sys <= '0;
    end else begin
        ack_meta_sys <= ack_toggle_spi;
        ack_sync_sys <= ack_meta_sys;

        if (cmd_valid && forward_cmd) begin
            case (cmd)
                CMD_SET_MODE: begin
                    pending_mode_arg_sys <= arg;
                    pending_mask_sys[0] <= 1'b1;
                end
                CMD_SET_VOLUME: begin
                    pending_volume_arg_sys <= arg;
                    pending_mask_sys[1] <= 1'b1;
                end
                CMD_SET_FREQ: begin
                    pending_freq_arg_sys <= arg;
                    pending_mask_sys[2] <= 1'b1;
                end
                default: begin
                end
            endcase
        end

        if (!busy) begin
            if (pending_mask_sys[0]) begin
                frame_payload_sys <= {CMD_SET_MODE, pending_mode_arg_sys};
                req_toggle_sys <= ~req_toggle_sys;
                pending_mask_sys[0] <= 1'b0;
            end else if (pending_mask_sys[1]) begin
                frame_payload_sys <= {CMD_SET_VOLUME, pending_volume_arg_sys};
                req_toggle_sys <= ~req_toggle_sys;
                pending_mask_sys[1] <= 1'b0;
            end else if (pending_mask_sys[2]) begin
                frame_payload_sys <= {CMD_SET_FREQ, pending_freq_arg_sys};
                req_toggle_sys <= ~req_toggle_sys;
                pending_mask_sys[2] <= 1'b0;
            end
        end
    end
end

always_ff @(negedge spi_clk or posedge spi_rst) begin
    if (spi_rst) begin
        req_meta_spi <= 1'b0;
        req_sync_spi <= 1'b0;
        req_seen_spi <= 1'b0;
        ack_toggle_spi <= 1'b0;
        frame_payload_spi <= '0;
        shift_spi <= '0;
        bit_cnt_spi <= '0;
        byte_idx_spi <= '0;
        frame_active_spi <= 1'b0;
        frame_available_spi <= 1'b0;
        frame_sent_this_cs_spi <= 1'b0;
        spi_miso <= 1'b0;
    end else begin
        req_meta_spi <= req_toggle_sys;
        req_sync_spi <= req_meta_spi;

        if (req_sync_spi != req_seen_spi) begin
            frame_payload_spi <= frame_payload_sys;
            req_seen_spi <= req_sync_spi;
            ack_toggle_spi <= req_sync_spi;
            frame_available_spi <= 1'b1;
        end

        if (spi_cs_n) begin
            shift_spi <= '0;
            bit_cnt_spi <= '0;
            byte_idx_spi <= '0;
            frame_active_spi <= 1'b0;
            frame_sent_this_cs_spi <= 1'b0;
            spi_miso <= 1'b0;
        end else begin
            if (bit_cnt_spi == 3'd0) begin
                logic [7:0] next_byte;

                if (!frame_active_spi && frame_available_spi && !frame_sent_this_cs_spi) begin
                    frame_active_spi <= 1'b1;
                    frame_sent_this_cs_spi <= 1'b1;
                    byte_idx_spi <= 4'd0;
                    next_byte = FRAME_MAGIC;
                end else begin
                    next_byte = frame_active_spi ? frame_byte(byte_idx_spi, frame_payload_spi) : 8'h00;
                end

                spi_miso <= next_byte[7];
                shift_spi <= {next_byte[6:0], 1'b0};
                bit_cnt_spi <= 3'd1;
            end else begin
                spi_miso <= shift_spi[7];
                shift_spi <= {shift_spi[6:0], 1'b0};

                if (bit_cnt_spi == 3'd7) begin
                    bit_cnt_spi <= 3'd0;
                    if (frame_active_spi) begin
                        if (byte_idx_spi == 4'd10) begin
                            frame_active_spi <= 1'b0;
                            byte_idx_spi <= 4'd0;
                        end else begin
                            byte_idx_spi <= byte_idx_spi + 4'd1;
                        end
                    end
                end else begin
                    bit_cnt_spi <= bit_cnt_spi + 3'd1;
                end
            end
        end
    end
end

endmodule
