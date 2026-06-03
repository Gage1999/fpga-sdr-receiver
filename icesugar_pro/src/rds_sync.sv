// rds_sync — RDS/RBDS block + group synchronizer.
//
// Consumes the differentially-decoded NRZ bit stream from rds_demod (one bit per
// `bit_valid` strobe) and recovers 104-bit groups (4 blocks x 26 bits). Each
// block is 16 information bits followed by a 10-bit checkword. The checkword is
//     check = CRC10(info) XOR offset_word
// where CRC10 is the remainder of info(x)*x^10 modulo the RDS generator
//     g(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1   (feedback mask 0x1B9).
//
// Detecting a block therefore reduces to:
//     syndrome = CRC10(info16) XOR received_check10
// which, for a correctly received block, equals the block's offset word exactly.
// No precomputed syndrome table is needed — the only constants are the five
// well-known offset words (A, B, C, C', D).
//
// Bits arrive MSB-first (RDS transmits the information MSB first, checkword LSB
// last), so the 26-bit window holds win[25:10]=info, win[9:0]=check.
//
// Sync strategy: HUNT slides bit-by-bit until an offset-A syndrome appears, then
// SYNC reads one block every 26 bits and validates each against the expected
// A,B,(C|C'),D sequence. Persistent block-offset failures drop back to HUNT.
//
// Everything runs in the `clk` domain, advancing only on `bit_valid`.

module rds_sync (
    input  logic        clk,
    input  logic        rst,
    input  logic        bit_in,
    input  logic        bit_valid,

    output logic        group_valid,    // 1-cycle pulse when a 4-block group completes
    output logic [15:0] pi_word,        // block A information word (Program Identification)
    output logic [15:0] blk_b,          // block B information word
    output logic [15:0] blk_c,          // block C information word
    output logic [15:0] blk_d,          // block D information word
    output logic        c_is_cprime,    // block C used offset C' (group version B)
    output logic [3:0]  block_ok,       // {a,b,c,d} offset matched as expected
    output logic        synced          // tracker currently locked
);

    // RDS offset words.
    localparam logic [9:0] OFF_A  = 10'h0FC;
    localparam logic [9:0] OFF_B  = 10'h198;
    localparam logic [9:0] OFF_C  = 10'h168;
    localparam logic [9:0] OFF_CP = 10'h350;
    localparam logic [9:0] OFF_D  = 10'h1B4;

    localparam logic [9:0] POLY = 10'h1B9;

    typedef enum logic [2:0] {OFF_NONE, OFF_IS_A, OFF_IS_B, OFF_IS_C, OFF_IS_CP, OFF_IS_D} off_e;

    // Remainder of info(x)*x^10 modulo g(x): MSB-first division, feedback from the
    // bit shifted past x^9. Synthesizes to a fixed 10-bit XOR tree of the 16 inputs.
    function automatic logic [9:0] rds_crc(input logic [15:0] info);
        logic [9:0] s;
        logic       fb;
        int         i;
        begin
            s = 10'd0;
            for (i = 15; i >= 0; i--) begin
                fb = s[9] ^ info[i];
                s  = {s[8:0], 1'b0};
                if (fb) s = s ^ POLY;
            end
            rds_crc = s;
        end
    endfunction

    function automatic off_e classify(input logic [9:0] s);
        begin
            case (s)
                OFF_A:   classify = OFF_IS_A;
                OFF_B:   classify = OFF_IS_B;
                OFF_C:   classify = OFF_IS_C;
                OFF_CP:  classify = OFF_IS_CP;
                OFF_D:   classify = OFF_IS_D;
                default: classify = OFF_NONE;
            endcase
        end
    endfunction

    logic [25:0] win;            // sliding 26-bit window, oldest bit at [25]

    // The block that ends on the bit currently being clocked in: combinational
    // view of the window after the in-flight shift.
    logic [25:0] next_win;
    off_e        next_off;
    assign next_win = {win[24:0], bit_in};
    assign next_off = classify(rds_crc(next_win[25:10]) ^ next_win[9:0]);

    typedef enum logic {ST_HUNT, ST_TRACK} state_e;
    state_e      state;
    logic        confident;      // a full good group has confirmed the lock
    logic [4:0]  bit_cnt;        // bits collected toward the current block (0..25)
    logic [1:0]  blk_pos;        // 0=A,1=B,2=C,3=D position within the group
    logic [2:0]  bad_groups;     // consecutive groups failing health check

    // Whether a freshly completed block's offset matches what blk_pos expects.
    // Returns {cprime, match}: bit0 = offset matched, bit1 = block C used C'.
    function automatic logic [1:0] offset_ok(input logic [1:0] pos, input off_e off);
        begin
            case (pos)
                2'd0:    offset_ok = {1'b0, (off == OFF_IS_A)};
                2'd1:    offset_ok = {1'b0, (off == OFF_IS_B)};
                2'd2:    offset_ok = {(off == OFF_IS_CP), (off == OFF_IS_C) || (off == OFF_IS_CP)};
                default: offset_ok = {1'b0, (off == OFF_IS_D)};
            endcase
        end
    endfunction

    logic [1:0] blk_res;
    logic       blk_match, blk_cprime;
    logic [2:0] ok_cnt;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            win         <= '0;
            state       <= ST_HUNT;
            confident   <= 1'b0;
            bit_cnt     <= 5'd0;
            blk_pos     <= 2'd0;
            bad_groups  <= 3'd0;
            group_valid <= 1'b0;
            pi_word     <= '0;
            blk_b       <= '0;
            blk_c       <= '0;
            blk_d       <= '0;
            c_is_cprime <= 1'b0;
            block_ok    <= 4'd0;
            synced      <= 1'b0;
        end else begin
            group_valid <= 1'b0;

            if (bit_valid) begin
                win <= next_win;

                case (state)
                    ST_HUNT: begin
                        // Lock tentatively on the first A-offset boundary; the
                        // following B/C/D blocks confirm or reject it.
                        if (next_off == OFF_IS_A) begin
                            pi_word    <= next_win[25:10];
                            block_ok   <= 4'b1000;   // A good
                            blk_pos    <= 2'd1;       // next block to collect is B
                            bit_cnt    <= 5'd0;
                            bad_groups <= 3'd0;
                            confident  <= 1'b0;
                            state      <= ST_TRACK;
                        end
                    end

                    ST_TRACK: begin
                        if (bit_cnt == 5'd25) begin
                            bit_cnt   <= 5'd0;
                            blk_res    = offset_ok(blk_pos, next_off);
                            blk_match  = blk_res[0];
                            blk_cprime = blk_res[1];
                            case (blk_pos)
                                2'd0: begin pi_word <= next_win[25:10]; block_ok[3] <= blk_match; end
                                2'd1: begin blk_b   <= next_win[25:10]; block_ok[2] <= blk_match; end
                                2'd2: begin
                                    blk_c       <= next_win[25:10];
                                    block_ok[1] <= blk_match;
                                    c_is_cprime <= blk_cprime;
                                end
                                default: begin blk_d <= next_win[25:10]; block_ok[0] <= blk_match; end
                            endcase

                            if (!confident && (blk_pos == 2'd1 || blk_pos == 2'd2) && !blk_match) begin
                                // Probation: B or C disagrees -> this was a false A. Re-hunt now.
                                state  <= ST_HUNT;
                                synced <= 1'b0;
                            end else if (blk_pos == 2'd3) begin
                                blk_pos <= 2'd0;
                                // block_ok[3:1] hold this group's A,B,C; blk_match is D.
                                ok_cnt = {2'd0, block_ok[3]} + {2'd0, block_ok[2]}
                                       + {2'd0, block_ok[1]} + {2'd0, blk_match};
                                if (ok_cnt >= 3'd3) begin
                                    confident   <= 1'b1;
                                    synced      <= 1'b1;
                                    bad_groups  <= 3'd0;
                                    group_valid <= 1'b1;
                                end else if (confident) begin
                                    group_valid <= 1'b1;   // stay locked through rough groups
                                    if (ok_cnt <= 3'd1) begin
                                        if (bad_groups >= 3'd2) begin
                                            state     <= ST_HUNT;
                                            synced    <= 1'b0;
                                            confident <= 1'b0;
                                        end else begin
                                            bad_groups <= bad_groups + 3'd1;
                                        end
                                    end else begin
                                        bad_groups <= 3'd0;
                                    end
                                end else begin
                                    // First group too weak to trust: re-hunt.
                                    state  <= ST_HUNT;
                                    synced <= 1'b0;
                                end
                            end else begin
                                blk_pos <= blk_pos + 2'd1;
                            end
                        end else begin
                            bit_cnt <= bit_cnt + 5'd1;
                        end
                    end
                endcase
            end
        end
    end

endmodule
