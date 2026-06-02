module spi_ui_cmd_rx (
    input  logic        spi_clk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,

    input  logic        clk,
    input  logic        rst,

    output logic        cmd_valid,
    output logic [7:0]  cmd,
    output logic [31:0] arg,

    output logic [15:0] good_frames,
    output logic [15:0] bad_frames,
    output logic [15:0] dropped_events
);

localparam logic [7:0] WIRE_MAGIC = 8'hA5;
localparam logic [7:0] OP_FULL_STATE = 8'h01;
localparam logic [7:0] OP_PARTIAL_STATE = 8'h02;

localparam logic [7:0] UI_STATE_VERSION = 8'd3;
localparam logic [15:0] UI_STATE_SIZE = 16'd564;

localparam logic [15:0] OFF_VERSION = 16'd0;
localparam logic [15:0] OFF_DEMOD = 16'd2;
localparam logic [15:0] OFF_VOLUME = 16'd3;
localparam logic [15:0] OFF_FREQ = 16'd4;
localparam logic [15:0] OFF_FLAGS = 16'd11;

localparam logic [7:0] DEMOD_FM = 8'd0;
localparam logic [7:0] DEMOD_GOES = 8'd2;
localparam logic [7:0] DEMOD_ADSB = 8'd3;

localparam logic [7:0] CMD_SET_MODE = 8'h01;
localparam logic [7:0] CMD_SET_VOLUME = 8'h02;
localparam logic [7:0] CMD_SET_FREQ = 8'h03;

localparam logic [2:0] P_IDLE = 3'd0;
localparam logic [2:0] P_OPCODE = 3'd1;
localparam logic [2:0] P_LEN0 = 3'd2;
localparam logic [2:0] P_LEN1 = 3'd3;
localparam logic [2:0] P_PAYLOAD = 3'd4;
localparam logic [2:0] P_CRC0 = 3'd5;
localparam logic [2:0] P_CRC1 = 3'd6;

localparam logic [2:0] CH_OFF0 = 3'd0;
localparam logic [2:0] CH_OFF1 = 3'd1;
localparam logic [2:0] CH_LEN0 = 3'd2;
localparam logic [2:0] CH_LEN1 = 3'd3;
localparam logic [2:0] CH_DATA = 3'd4;

logic [7:0] shift_spi;
logic [2:0] bit_cnt_spi;
wire [7:0] next_byte = {shift_spi[6:0], spi_mosi};

logic [2:0] parser_state;
logic [7:0] opcode_spi;
logic [15:0] payload_len_spi;
logic [15:0] payload_idx_spi;
logic [15:0] crc_spi;
logic [7:0] crc0_spi;
logic payload_bad_spi;

logic [7:0] demod_spi;
logic [7:0] volume_spi;
logic flags_spi;
logic [31:0] freq_hz_spi;

logic [7:0] cand_demod_spi;
logic [7:0] cand_volume_spi;
logic cand_flags_spi;
logic [31:0] cand_freq_hz_spi;
logic version_ok_spi;

logic [2:0] chunk_state_spi;
logic [15:0] chunk_off_spi;
logic [15:0] chunk_len_spi;
logic [15:0] chunk_count_spi;

logic [7:0] event_demod_spi;
logic [7:0] event_volume_spi;
logic event_mute_spi;
logic [31:0] event_freq_hz_spi;
logic [2:0] event_mask_spi;
logic event_toggle_spi;
logic event_ack_meta_spi, event_ack_sync_spi;

logic event_meta, event_sync, event_seen;
logic event_ack_toggle;
logic [7:0] event_demod_hold;
logic [7:0] event_volume_hold;
logic event_mute_hold;
logic [31:0] event_freq_hz_hold;
logic [2:0] pending_mask;
logic [2:0] pending_mask_next;

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

function automatic logic valid_demod(input logic [7:0] demod);
    valid_demod = (demod == DEMOD_FM) || (demod == DEMOD_GOES) || (demod == DEMOD_ADSB);
endfunction

function automatic logic [7:0] scale_volume(input logic [7:0] ui_volume);
    logic [15:0] scaled;
    begin
        scaled = ui_volume * 8'd163;
        if (ui_volume >= 8'd100)
            scale_volume = 8'hff;
        else
            scale_volume = scaled[15:6];
    end
endfunction

function automatic logic [2:0] changed_mask(
    input logic [7:0] old_demod,
    input logic [7:0] new_demod,
    input logic [7:0] old_volume,
    input logic [7:0] new_volume,
    input logic old_mute,
    input logic new_mute,
    input logic [31:0] old_freq,
    input logic [31:0] new_freq
);
    begin
        changed_mask[0] = valid_demod(new_demod) && (old_demod != new_demod);
        changed_mask[1] = (old_volume != new_volume) || (old_mute != new_mute);
        changed_mask[2] = (old_freq != new_freq);
    end
endfunction

task automatic apply_state_byte(input logic [15:0] off, input logic [7:0] data);
    begin
        case (off)
            OFF_VERSION: version_ok_spi <= (data == UI_STATE_VERSION);
            OFF_DEMOD: cand_demod_spi <= data;
            OFF_VOLUME: cand_volume_spi <= data;
            OFF_FREQ + 16'd0: cand_freq_hz_spi[7:0] <= data;
            OFF_FREQ + 16'd1: cand_freq_hz_spi[15:8] <= data;
            OFF_FREQ + 16'd2: cand_freq_hz_spi[23:16] <= data;
            OFF_FREQ + 16'd3: cand_freq_hz_spi[31:24] <= data;
            OFF_FLAGS: cand_flags_spi <= data[0];
            default: begin
            end
        endcase
    end
endtask

task automatic process_payload_byte(input logic [7:0] data);
    logic [15:0] next_chunk_len;
    logic [15:0] payload_left_after_header;
    begin
        if (opcode_spi == OP_FULL_STATE) begin
            apply_state_byte(payload_idx_spi, data);
        end else if (opcode_spi == OP_PARTIAL_STATE) begin
            case (chunk_state_spi)
                CH_OFF0: begin
                    chunk_off_spi[7:0] <= data;
                    chunk_state_spi <= CH_OFF1;
                end
                CH_OFF1: begin
                    chunk_off_spi[15:8] <= data;
                    chunk_state_spi <= CH_LEN0;
                end
                CH_LEN0: begin
                    chunk_len_spi[7:0] <= data;
                    chunk_state_spi <= CH_LEN1;
                end
                CH_LEN1: begin
                    next_chunk_len = {data, chunk_len_spi[7:0]};
                    payload_left_after_header = payload_len_spi - payload_idx_spi - 16'd1;
                    chunk_len_spi[15:8] <= data;
                    chunk_count_spi <= 16'd0;
                    if ((next_chunk_len == 16'd0) ||
                        (next_chunk_len > payload_left_after_header) ||
                        ((chunk_off_spi + next_chunk_len) > UI_STATE_SIZE)) begin
                        payload_bad_spi <= 1'b1;
                    end
                    chunk_state_spi <= CH_DATA;
                end
                CH_DATA: begin
                    apply_state_byte(chunk_off_spi + chunk_count_spi, data);
                    if (chunk_count_spi + 16'd1 >= chunk_len_spi) begin
                        chunk_state_spi <= CH_OFF0;
                        chunk_count_spi <= 16'd0;
                    end else begin
                        chunk_count_spi <= chunk_count_spi + 16'd1;
                    end
                end
                default: chunk_state_spi <= CH_OFF0;
            endcase
        end
    end
endtask

task automatic accept_frame;
    logic [2:0] mask;
    begin
        mask = changed_mask(demod_spi, cand_demod_spi,
                            volume_spi, cand_volume_spi,
                            flags_spi, cand_flags_spi,
                            freq_hz_spi, cand_freq_hz_spi);

        demod_spi <= cand_demod_spi;
        volume_spi <= cand_volume_spi;
        flags_spi <= cand_flags_spi;
        freq_hz_spi <= cand_freq_hz_spi;
        good_frames <= good_frames + 16'd1;

        if (mask != 3'b000) begin
            if (event_toggle_spi == event_ack_sync_spi) begin
                event_demod_spi <= cand_demod_spi;
                event_volume_spi <= cand_volume_spi;
                event_mute_spi <= cand_flags_spi;
                event_freq_hz_spi <= cand_freq_hz_spi;
                event_mask_spi <= mask;
                event_toggle_spi <= ~event_toggle_spi;
            end else begin
                dropped_events <= dropped_events + 16'd1;
            end
        end
    end
endtask

task automatic finish_frame(input logic [7:0] crc1);
    logic crc_ok;
    logic len_ok;
    begin
        crc_ok = ({crc1, crc0_spi} == crc_spi);
        len_ok = ((opcode_spi == OP_FULL_STATE) && (payload_len_spi == UI_STATE_SIZE) && version_ok_spi) ||
                 ((opcode_spi == OP_PARTIAL_STATE) && (chunk_state_spi == CH_OFF0));

        if (crc_ok && len_ok && !payload_bad_spi) begin
            accept_frame();
        end else begin
            bad_frames <= bad_frames + 16'd1;
        end
        parser_state <= P_IDLE;
    end
endtask

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        shift_spi <= '0;
        bit_cnt_spi <= '0;
        parser_state <= P_IDLE;
        payload_idx_spi <= '0;
        chunk_state_spi <= CH_OFF0;
    end else begin
        shift_spi <= next_byte;
        if (bit_cnt_spi == 3'd7) begin
            bit_cnt_spi <= '0;

            case (parser_state)
                P_IDLE: begin
                    if (next_byte == WIRE_MAGIC) begin
                        parser_state <= P_OPCODE;
                        crc_spi <= 16'hFFFF;
                        payload_bad_spi <= 1'b0;
                        version_ok_spi <= 1'b1;
                        cand_demod_spi <= demod_spi;
                        cand_volume_spi <= volume_spi;
                        cand_flags_spi <= flags_spi;
                        cand_freq_hz_spi <= freq_hz_spi;
                        chunk_state_spi <= CH_OFF0;
                        chunk_count_spi <= '0;
                    end
                end
                P_OPCODE: begin
                    opcode_spi <= next_byte;
                    crc_spi <= crc16_update(crc_spi, next_byte);
                    parser_state <= P_LEN0;
                    if ((next_byte != OP_FULL_STATE) && (next_byte != OP_PARTIAL_STATE))
                        payload_bad_spi <= 1'b1;
                end
                P_LEN0: begin
                    payload_len_spi[7:0] <= next_byte;
                    crc_spi <= crc16_update(crc_spi, next_byte);
                    parser_state <= P_LEN1;
                end
                P_LEN1: begin
                    payload_len_spi[15:8] <= next_byte;
                    crc_spi <= crc16_update(crc_spi, next_byte);
                    payload_idx_spi <= 16'd0;
                    chunk_state_spi <= CH_OFF0;
                    if ({next_byte, payload_len_spi[7:0]} == 16'd0)
                        parser_state <= P_CRC0;
                    else
                        parser_state <= P_PAYLOAD;
                end
                P_PAYLOAD: begin
                    crc_spi <= crc16_update(crc_spi, next_byte);
                    process_payload_byte(next_byte);
                    if (payload_idx_spi + 16'd1 >= payload_len_spi) begin
                        parser_state <= P_CRC0;
                    end
                    payload_idx_spi <= payload_idx_spi + 16'd1;
                end
                P_CRC0: begin
                    crc0_spi <= next_byte;
                    parser_state <= P_CRC1;
                end
                P_CRC1: begin
                    finish_frame(next_byte);
                end
                default: parser_state <= P_IDLE;
            endcase
        end else begin
            bit_cnt_spi <= bit_cnt_spi + 3'd1;
        end
    end
end

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        event_ack_meta_spi <= 1'b0;
        event_ack_sync_spi <= 1'b0;
    end else begin
        event_ack_meta_spi <= event_ack_toggle;
        event_ack_sync_spi <= event_ack_meta_spi;
    end
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        event_meta <= 1'b0;
        event_sync <= 1'b0;
        event_seen <= 1'b0;
        event_ack_toggle <= 1'b0;
        event_demod_hold <= DEMOD_FM;
        event_volume_hold <= 8'd100;
        event_mute_hold <= 1'b0;
        event_freq_hz_hold <= 32'd95_100_000;
        pending_mask <= '0;
        cmd_valid <= 1'b0;
        cmd <= '0;
        arg <= '0;
    end else begin
        event_meta <= event_toggle_spi;
        event_sync <= event_meta;
        cmd_valid <= 1'b0;

        pending_mask_next = pending_mask;

        if (event_sync != event_seen) begin
            event_seen <= event_sync;
            event_ack_toggle <= event_sync;
            event_demod_hold <= event_demod_spi;
            event_volume_hold <= event_volume_spi;
            event_mute_hold <= event_mute_spi;
            event_freq_hz_hold <= event_freq_hz_spi;
            pending_mask_next = pending_mask_next | event_mask_spi;
        end else begin
            if (pending_mask_next[0]) begin
                cmd <= CMD_SET_MODE;
                arg <= {29'd0, event_demod_hold[2:0]};
                cmd_valid <= 1'b1;
                pending_mask_next[0] = 1'b0;
            end else if (pending_mask_next[1]) begin
                cmd <= CMD_SET_VOLUME;
                arg <= {23'd0, event_mute_hold, scale_volume(event_volume_hold)};
                cmd_valid <= 1'b1;
                pending_mask_next[1] = 1'b0;
            end else if (pending_mask_next[2]) begin
                cmd <= CMD_SET_FREQ;
                arg <= event_freq_hz_hold;
                cmd_valid <= 1'b1;
                pending_mask_next[2] = 1'b0;
            end
        end

        pending_mask <= pending_mask_next;
    end
end

initial begin
    shift_spi = '0;
    bit_cnt_spi = '0;
    parser_state = P_IDLE;
    opcode_spi = '0;
    payload_len_spi = '0;
    payload_idx_spi = '0;
    crc_spi = 16'hFFFF;
    crc0_spi = '0;
    payload_bad_spi = 1'b0;
    demod_spi = DEMOD_FM;
    volume_spi = 8'd100;
    flags_spi = 1'b0;
    freq_hz_spi = 32'd95_100_000;
    cand_demod_spi = DEMOD_FM;
    cand_volume_spi = 8'd100;
    cand_flags_spi = 1'b0;
    cand_freq_hz_spi = 32'd95_100_000;
    version_ok_spi = 1'b1;
    chunk_state_spi = CH_OFF0;
    chunk_off_spi = '0;
    chunk_len_spi = '0;
    chunk_count_spi = '0;
    event_demod_spi = DEMOD_FM;
    event_volume_spi = 8'd100;
    event_mute_spi = 1'b0;
    event_freq_hz_spi = 32'd95_100_000;
    event_mask_spi = '0;
    event_toggle_spi = 1'b0;
    event_ack_meta_spi = 1'b0;
    event_ack_sync_spi = 1'b0;
    good_frames = '0;
    bad_frames = '0;
    dropped_events = '0;
end

endmodule
