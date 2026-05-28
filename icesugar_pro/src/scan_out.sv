// Fetches one display line from SDRAM into the line cache ahead of when it is needed.
// Runs in the 100 MHz SDRAM clock domain.
//
// Framebuffer layout: stride = 1024 words (2048 bytes) per display row.
// Each display row spans two SDRAM rows of 512 columns each.
//   Phase A: 512 words from SDRAM row 2N,   col 0  (pixels 0-511)
//   Phase B: 288 words from SDRAM row 2N+1, col 0  (pixels 512-799)
//
// Prefetch: at H-blank of display row R, fetch row R + PREFETCH_OFFSET.
// Wraparound: at V-blank rows V_TOTAL-2 and V_TOTAL-1, fetch rows 0 and 1
//   so both are in cache before the next frame starts.
//
// Slot assignment: row N is written to slot (N+1)%4.
// The display must read slot (V_CNT + 1) % 4 to get the correct line.

module scan_out (
    input  logic        clk,
    input  logic        rst,

    input  logic [9:0]  px_v_cnt,
    input  logic        px_h_blank,

    input  logic [24:0] fb_base_addr,

    output logic        req_valid,
    input  logic        req_ready,
    output logic [24:0] req_addr,
    output logic [9:0]  req_len,
    input  logic [15:0] rd_data,
    input  logic        rd_valid,

    output logic [1:0]  w_slot,
    output logic [9:0]  w_col,
    output logic [15:0] w_data,
    output logic        w_en
);

localparam LINE_WORDS      = 800;
localparam WORDS_A         = 512;
localparam WORDS_B         = LINE_WORDS - WORDS_A; // 288
localparam V_DISPLAY       = 480;
localparam V_TOTAL         = 525;
localparam PREFETCH_OFFSET = 2;

typedef enum logic [2:0] {
    S_IDLE, S_REQ_A, S_RECV_A, S_REQ_B, S_RECV_B
} state_t;

state_t      state;
logic [9:0]  line_to_fetch;
logic [1:0]  slot_to_fill;
logic [9:0]  col_counter;

// Detect rising edge of px_h_blank
logic px_h_blank_d;
always_ff @(posedge clk) px_h_blank_d <= px_h_blank;
wire fetch_trigger = px_h_blank && ~px_h_blank_d;

// Compute which display row to prefetch and whether the trigger is valid.
// V-blank rows V_TOTAL-PREFETCH_OFFSET .. V_TOTAL-1 wrap around to fetch rows 0..1.
// Active rows 0 .. V_DISPLAY-PREFETCH_OFFSET-1 fetch rows 2 .. V_DISPLAY-1.
// Rows V_DISPLAY-PREFETCH_OFFSET .. V_TOTAL-PREFETCH_OFFSET-1 are the dead zone
// (rows 478-522): no fetch needed.
logic [9:0] prefetch_line;
logic       prefetch_valid;
always_comb begin
    if (px_v_cnt >= 10'(V_TOTAL - PREFETCH_OFFSET)) begin
        prefetch_line  = px_v_cnt - 10'(V_TOTAL - PREFETCH_OFFSET);
        prefetch_valid = 1'b1;
    end else if (px_v_cnt < 10'(V_DISPLAY - PREFETCH_OFFSET)) begin
        prefetch_line  = px_v_cnt + 10'(PREFETCH_OFFSET);
        prefetch_valid = 1'b1;
    end else begin
        prefetch_line  = 10'd0;
        prefetch_valid = 1'b0;
    end
end

// Base byte address for line_to_fetch with stride = 2048 bytes (1024 words).
// {4'b0, line_to_fetch[9:0], 11'b0} = line_to_fetch * 2048 in 25 bits.
wire [24:0] line_base = fb_base_addr + {4'b0, line_to_fetch, 11'b0};

always_ff @(posedge clk) begin
    if (rst) begin
        state         <= S_IDLE;
        req_valid     <= 1'b0;
        w_en          <= 1'b0;
        slot_to_fill  <= 2'd0;
        col_counter   <= 10'd0;
        line_to_fetch <= 10'd0;
        req_addr      <= 25'd0;
        req_len       <= 10'd0;
        w_slot        <= 2'd0;
        w_col         <= 10'd0;
        w_data        <= 16'd0;
    end else begin
        req_valid <= 1'b0;
        w_en      <= 1'b0;

        case (state)
            S_IDLE: begin
                if (fetch_trigger && prefetch_valid) begin
                    line_to_fetch <= prefetch_line;
                    slot_to_fill  <= prefetch_line[1:0] + 2'd1;
                    state         <= S_REQ_A;
                end
            end

            S_REQ_A: begin
                req_valid <= 1'b1;
                req_addr  <= line_base;
                req_len   <= 10'(WORDS_A);
                if (req_ready && req_valid) begin
                    req_valid   <= 1'b0;
                    col_counter <= 10'd0;
                    state       <= S_RECV_A;
                end
            end

            S_RECV_A: begin
                w_data <= rd_data;
                w_slot <= slot_to_fill;
                w_col  <= col_counter;
                if (rd_valid) begin
                    w_en        <= 1'b1;
                    col_counter <= col_counter + 10'd1;
                    if (col_counter == 10'(WORDS_A - 1))
                        state <= S_REQ_B;
                end
            end

            S_REQ_B: begin
                // col_counter holds WORDS_A (512) from S_RECV_A
                req_valid <= 1'b1;
                req_addr  <= line_base + 25'd1024; // SDRAM row 2N+1, col 0
                req_len   <= 10'(WORDS_B);
                if (req_ready) begin
                    req_valid <= 1'b0;
                    state     <= S_RECV_B;
                end
            end

            S_RECV_B: begin
                w_data <= rd_data;
                w_slot <= slot_to_fill;
                w_col  <= col_counter;
                if (rd_valid) begin
                    w_en        <= 1'b1;
                    col_counter <= col_counter + 10'd1;
                    if (col_counter == 10'(LINE_WORDS - 1))
                        state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
