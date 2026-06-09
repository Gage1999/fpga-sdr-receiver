// ui_wire_rx - Pico -> ECP5 0xA5 UI wire protocol receiver.

module ui_wire_rx #(
    parameter int UI_STATE_BYTES = 564,
    parameter int WIRE_MAX_PAYLOAD = 1024,
    parameter int UI_STATE_VERSION = 3
) (
    input logic spi_clk,
    input logic spi_cs_n,
    input logic spi_mosi,

    input logic clk,
    input logic rst,

    output logic [1:0] layout,
    output logic [1:0] demod,
    output logic [7:0] volume,
    output logic [31:0] freq_hz,
    output logic [15:0] span_hz_log2,
    output logic [7:0] flags,
    output logic [9:0] touch_x,
    output logic [9:0] touch_y,
    output logic [7:0] active_button,
    output logic [191:0] rds_line,
    output logic frame_valid
);
    localparam logic [7:0] WIRE_MAGIC = 8'ha5;
    localparam logic [7:0] OP_FULL_STATE = 8'h01;
    localparam logic [7:0] OP_PARTIAL_STATE = 8'h02;
    localparam logic [7:0] OP_TOUCH_EVENT = 8'h03;
    localparam logic [7:0] OP_HEARTBEAT = 8'h04;
    localparam logic [7:0] OP_SPECTRUM_BINS = 8'h05;

    localparam logic [7:0] UI_BTN_NONE = 8'hff;
    localparam logic [31:0] UI_VERSION_W = UI_STATE_VERSION;
    localparam logic [31:0] UI_STATE_BYTES_W = UI_STATE_BYTES;
    localparam logic [31:0] UI_STATE_LAST_W = UI_STATE_BYTES_W - 32'd1;
    localparam logic [31:0] WIRE_MAX_PAYLOAD_W = WIRE_MAX_PAYLOAD;
    localparam logic [7:0] UI_VERSION_U8 = UI_VERSION_W[7:0];
    localparam logic [15:0] UI_STATE_BYTES_U16 = UI_STATE_BYTES_W[15:0];
    localparam logic [16:0] UI_STATE_BYTES_U17 = UI_STATE_BYTES_W[16:0];
    localparam logic [16:0] UI_STATE_LAST_U17 = UI_STATE_LAST_W[16:0];
    localparam logic [15:0] WIRE_MAX_PAYLOAD_U16 = WIRE_MAX_PAYLOAD_W[15:0];

    typedef enum logic [2:0] {
        S_DROP = 3'd0,
        S_OPCODE = 3'd1,
        S_LEN_LO = 3'd2,
        S_LEN_HI = 3'd3,
        S_PAYLOAD = 3'd4,
        S_CRC_LO = 3'd5,
        S_CRC_HI = 3'd6
    } parse_state_e;

    logic byte_valid;
    logic byte_sof;
    logic [7:0] byte_data;

    spi_frame_rx u_frame_rx (
        .spi_clk(spi_clk),
        .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi),
        .byte_valid(byte_valid),
        .byte_sof(byte_sof),
        .byte_data(byte_data)
    );

    function automatic logic [15:0] crc16_next(input logic [15:0] crc_in,
                                                input logic [7:0] data);
        logic [15:0] crc;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (int i = 0; i < 8; i++) begin
                if (crc[15]) crc = {crc[14:0], 1'b0} ^ 16'h1021;
                else         crc = {crc[14:0], 1'b0};
            end
            crc16_next = crc;
        end
    endfunction

    parse_state_e st_spi;
    logic [7:0] opcode_spi;
    logic [15:0] payload_len_spi;
    logic [15:0] payload_pos_spi;
    logic [15:0] calc_crc_spi;
    logic [7:0] crc_lo_spi;
    logic frame_bad_spi;

    logic [1:0] layout_spi, tmp_layout;
    logic [1:0] demod_spi, tmp_demod;
    logic [7:0] volume_spi, tmp_volume;
    logic [31:0] freq_hz_spi, tmp_freq_hz;
    logic [15:0] span_hz_log2_spi, tmp_span_hz_log2;
    logic [7:0] flags_spi, tmp_flags;
    logic [9:0] touch_x_spi, tmp_touch_x;
    logic [9:0] touch_y_spi, tmp_touch_y;
    logic [7:0] active_button_spi, tmp_active_button;
    logic [191:0] rds_line_spi, tmp_rds_line;
    logic commit_toggle_spi;

    logic [1:0] partial_phase_spi; // 0 off_lo, 1 off_hi, 2 len_lo, 3 len_hi; data when partial_data_spi
    logic partial_data_spi;
    logic [15:0] chunk_off_spi;
    logic [15:0] chunk_len_spi;
    logic [15:0] chunk_pos_spi;
    wire [15:0] chunk_len_next = {byte_data, chunk_len_spi[7:0]};
    wire [16:0] chunk_end_next = {1'b0, chunk_off_spi} + {1'b0, chunk_len_next};
    wire [16:0] chunk_abs_off = {1'b0, chunk_off_spi} + {1'b0, chunk_pos_spi};

    task automatic load_tmp_from_current;
        begin
            tmp_layout <= layout_spi;
            tmp_demod <= demod_spi;
            tmp_volume <= volume_spi;
            tmp_freq_hz <= freq_hz_spi;
            tmp_span_hz_log2 <= span_hz_log2_spi;
            tmp_flags <= flags_spi;
            tmp_touch_x <= touch_x_spi;
            tmp_touch_y <= touch_y_spi;
            tmp_active_button <= active_button_spi;
            tmp_rds_line <= rds_line_spi;
        end
    endtask

    task automatic apply_ui_byte(input logic [15:0] off, input logic [7:0] b);
        logic [4:0] rds_idx;
        begin
            if (off >= 16'd20 && off < 16'd44) begin
                rds_idx = off[4:0] - 5'd20;
                tmp_rds_line[rds_idx * 8 +: 8] <= (b >= 8'h20 && b <= 8'h7e) ? b : 8'h20;
            end else begin
                unique case (off)
                    16'd0:  if (b != UI_VERSION_U8) frame_bad_spi <= 1'b1;
                    16'd1:  tmp_layout <= b[1:0];
                    16'd2:  tmp_demod <= b[1:0];
                    16'd3:  tmp_volume <= b;
                    16'd4:  tmp_freq_hz[7:0] <= b;
                    16'd5:  tmp_freq_hz[15:8] <= b;
                    16'd6:  tmp_freq_hz[23:16] <= b;
                    16'd7:  tmp_freq_hz[31:24] <= b;
                    16'd8:  tmp_span_hz_log2[7:0] <= b;
                    16'd9:  tmp_span_hz_log2[15:8] <= b;
                    16'd11: tmp_flags <= b;
                    16'd12: tmp_touch_x[7:0] <= b;
                    16'd13: tmp_touch_x[9:8] <= b[1:0];
                    16'd14: tmp_touch_y[7:0] <= b;
                    16'd15: tmp_touch_y[9:8] <= b[1:0];
                    16'd16: tmp_active_button <= b;
                    default: ;
                endcase
            end
        end
    endtask

    initial begin
        st_spi = S_DROP;
        opcode_spi = 8'd0;
        payload_len_spi = 16'd0;
        payload_pos_spi = 16'd0;
        calc_crc_spi = 16'hffff;
        crc_lo_spi = 8'd0;
        frame_bad_spi = 1'b0;
        partial_phase_spi = 2'd0;
        partial_data_spi = 1'b0;
        chunk_off_spi = 16'd0;
        chunk_len_spi = 16'd0;
        chunk_pos_spi = 16'd0;

        layout_spi = 2'd0;
        demod_spi = 2'd0;
        volume_spi = 8'd50;
        freq_hz_spi = 32'd100_000_000;
        span_hz_log2_spi = 16'd17;
        flags_spi = 8'd0;
        touch_x_spi = 10'd0;
        touch_y_spi = 10'd0;
        active_button_spi = UI_BTN_NONE;
        rds_line_spi = {24{8'h20}};
        commit_toggle_spi = 1'b0;

        tmp_layout = 2'd0;
        tmp_demod = 2'd0;
        tmp_volume = 8'd50;
        tmp_freq_hz = 32'd100_000_000;
        tmp_span_hz_log2 = 16'd17;
        tmp_flags = 8'd0;
        tmp_touch_x = 10'd0;
        tmp_touch_y = 10'd0;
        tmp_active_button = UI_BTN_NONE;
        tmp_rds_line = {24{8'h20}};
    end

    always_ff @(posedge spi_clk) begin
        if (byte_valid) begin
            if (byte_sof) begin
                load_tmp_from_current();
                opcode_spi <= 8'd0;
                payload_len_spi <= 16'd0;
                payload_pos_spi <= 16'd0;
                calc_crc_spi <= 16'hffff;
                crc_lo_spi <= 8'd0;
                frame_bad_spi <= 1'b0;
                partial_phase_spi <= 2'd0;
                partial_data_spi <= 1'b0;
                chunk_off_spi <= 16'd0;
                chunk_len_spi <= 16'd0;
                chunk_pos_spi <= 16'd0;
                st_spi <= (byte_data == WIRE_MAGIC) ? S_OPCODE : S_DROP;
            end else begin
                unique case (st_spi)
                    S_OPCODE: begin
                        opcode_spi <= byte_data;
                        calc_crc_spi <= crc16_next(16'hffff, byte_data);
                        frame_bad_spi <= !((byte_data == OP_FULL_STATE) ||
                                           (byte_data == OP_PARTIAL_STATE) ||
                                           (byte_data == OP_TOUCH_EVENT) ||
                                           (byte_data == OP_HEARTBEAT) ||
                                           (byte_data == OP_SPECTRUM_BINS));
                        st_spi <= S_LEN_LO;
                    end

                    S_LEN_LO: begin
                        payload_len_spi[7:0] <= byte_data;
                        calc_crc_spi <= crc16_next(calc_crc_spi, byte_data);
                        st_spi <= S_LEN_HI;
                    end

                    S_LEN_HI: begin
                        payload_len_spi[15:8] <= byte_data;
                        calc_crc_spi <= crc16_next(calc_crc_spi, byte_data);
                        payload_pos_spi <= 16'd0;
                        if ({byte_data, payload_len_spi[7:0]} > WIRE_MAX_PAYLOAD_U16) begin
                            frame_bad_spi <= 1'b1;
                            st_spi <= S_DROP;
                        end else if (opcode_spi == OP_FULL_STATE &&
                                     {byte_data, payload_len_spi[7:0]} != UI_STATE_BYTES_U16) begin
                            frame_bad_spi <= 1'b1;
                            st_spi <= S_DROP;
                        end else if ({byte_data, payload_len_spi[7:0]} == 16'd0) begin
                            st_spi <= S_CRC_LO;
                        end else begin
                            st_spi <= S_PAYLOAD;
                        end
                    end

                    S_PAYLOAD: begin
                        calc_crc_spi <= crc16_next(calc_crc_spi, byte_data);

                        if (opcode_spi == OP_FULL_STATE) begin
                            apply_ui_byte(payload_pos_spi, byte_data);
                        end else if (opcode_spi == OP_PARTIAL_STATE) begin
                            if (!partial_data_spi) begin
                                unique case (partial_phase_spi)
                                    2'd0: begin chunk_off_spi[7:0] <= byte_data; partial_phase_spi <= 2'd1; end
                                    2'd1: begin chunk_off_spi[15:8] <= byte_data; partial_phase_spi <= 2'd2; end
                                    2'd2: begin chunk_len_spi[7:0] <= byte_data; partial_phase_spi <= 2'd3; end
                                    default: begin
                                        chunk_len_spi[15:8] <= byte_data;
                                        chunk_pos_spi <= 16'd0;
                                        if (chunk_len_next == 16'd0 ||
                                            chunk_end_next > UI_STATE_BYTES_U17) begin
                                            frame_bad_spi <= 1'b1;
                                            partial_phase_spi <= 2'd0;
                                            partial_data_spi <= 1'b0;
                                        end else begin
                                            partial_data_spi <= 1'b1;
                                        end
                                    end
                                endcase
                            end else begin
                                if (chunk_abs_off <= UI_STATE_LAST_U17)
                                    apply_ui_byte(chunk_abs_off[15:0], byte_data);
                                if (chunk_pos_spi == chunk_len_spi - 16'd1) begin
                                    chunk_pos_spi <= 16'd0;
                                    partial_phase_spi <= 2'd0;
                                    partial_data_spi <= 1'b0;
                                end else begin
                                    chunk_pos_spi <= chunk_pos_spi + 16'd1;
                                end
                            end
                        end

                        if (payload_pos_spi == payload_len_spi - 16'd1)
                            st_spi <= S_CRC_LO;
                        payload_pos_spi <= payload_pos_spi + 16'd1;
                    end

                    S_CRC_LO: begin
                        crc_lo_spi <= byte_data;
                        st_spi <= S_CRC_HI;
                    end

                    S_CRC_HI: begin
                        if (!frame_bad_spi &&
                            opcode_spi == OP_PARTIAL_STATE &&
                            (partial_data_spi || partial_phase_spi != 2'd0)) begin
                            frame_bad_spi <= 1'b1;
                        end else if (!frame_bad_spi &&
                                     {byte_data, crc_lo_spi} == calc_crc_spi &&
                                     (opcode_spi == OP_FULL_STATE ||
                                      opcode_spi == OP_PARTIAL_STATE)) begin
                            layout_spi <= tmp_layout;
                            demod_spi <= tmp_demod;
                            volume_spi <= tmp_volume;
                            freq_hz_spi <= tmp_freq_hz;
                            span_hz_log2_spi <= tmp_span_hz_log2;
                            flags_spi <= tmp_flags;
                            touch_x_spi <= tmp_touch_x;
                            touch_y_spi <= tmp_touch_y;
                            active_button_spi <= tmp_active_button;
                            rds_line_spi <= tmp_rds_line;
                            commit_toggle_spi <= ~commit_toggle_spi;
                        end
                        st_spi <= S_DROP;
                    end

                    default: ;
                endcase
            end
        end
    end

    logic commit_meta, commit_sync, commit_seen;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            layout <= 2'd0;
            demod <= 2'd0;
            volume <= 8'd50;
            freq_hz <= 32'd100_000_000;
            span_hz_log2 <= 16'd17;
            flags <= 8'd0;
            touch_x <= 10'd0;
            touch_y <= 10'd0;
            active_button <= UI_BTN_NONE;
            rds_line <= {24{8'h20}};
            commit_meta <= 1'b0;
            commit_sync <= 1'b0;
            commit_seen <= 1'b0;
            frame_valid <= 1'b0;
        end else begin
            commit_meta <= commit_toggle_spi;
            commit_sync <= commit_meta;
            frame_valid <= 1'b0;
            if (commit_sync != commit_seen) begin
                commit_seen <= commit_sync;
                layout <= layout_spi;
                demod <= demod_spi;
                volume <= volume_spi;
                freq_hz <= freq_hz_spi;
                span_hz_log2 <= span_hz_log2_spi;
                flags <= flags_spi;
                touch_x <= touch_x_spi;
                touch_y <= touch_y_spi;
                active_button <= active_button_spi;
                rds_line <= rds_line_spi;
                frame_valid <= 1'b1;
            end
        end
    end
endmodule
