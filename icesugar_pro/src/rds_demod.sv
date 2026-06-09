// rds_demod - recover the RDS NRZ bit stream from the FM composite (MPX) signal.

module rds_demod #(
    parameter int unsigned PILOT_FW = 32'd313360413,
    parameter int          KP        = 48,
    parameter int          KI_SH     = 9,
    parameter int          KE_SH     = 4,
    parameter int          KD_SH     = 4,
    parameter int          ZC_GATE   = 48,
    parameter int          T_THRESH  = 28
)(
    input  logic               clk,
    input  logic               rst,
    input  logic signed [15:0] mpx_in,
    input  logic               mpx_valid,

    output logic               bit_out,
    output logic               bit_valid,
    output logic               pll_locked
);

    localparam logic signed [11:0] BP_A1 = 12'sd1809;
    localparam logic signed [11:0] BP_A2 = 12'sd994;
    localparam logic signed [6:0]  BP_B0 = 7'sd15;

    logic signed [17:0] bp_x1, bp_x2, bp_y1, bp_y2, bp_y;
    logic signed [31:0] bp_acc;
    assign bp_acc = BP_A1 * bp_y1 - BP_A2 * bp_y2
                  + BP_B0 * ($signed({{2{mpx_in[15]}}, mpx_in}) - bp_x2);
    assign bp_y   = bp_acc >>> 10;

    // 1. Pilot PLL (19 kHz).
    logic [31:0]        phase;
    logic signed [33:0] integ;
    logic signed [23:0] err_lp;

    logic cos_pos1;
    assign cos_pos1 = (phase[31] == phase[30]);

    logic signed [18:0] pd;
    assign pd = cos_pos1 ? {bp_y[17], bp_y} : -{bp_y[17], bp_y};

    logic [31:0] phase3;
    assign phase3 = phase + (phase << 1);
    logic cos_pos3, sin_pos3;
    assign cos_pos3 = (phase3[31] == phase3[30]);
    assign sin_pos3 = (phase3[31] == 1'b0);

    logic signed [33:0] inc_calc;
    logic [32:0]        phase_sum;
    logic               tick;
    assign inc_calc  = $signed({2'b00, PILOT_FW}) + integ + (err_lp * KP);
    assign phase_sum = {1'b0, phase} + {1'b0, inc_calc[31:0]};
    assign tick      = phase_sum[32];

    // 2. 57 kHz coherent demod + data low-pass (two 1-pole stages per arm).
    logic signed [16:0] i_mix, q_mix;
    assign i_mix = cos_pos3 ? {mpx_in[15], mpx_in} : -{mpx_in[15], mpx_in};
    assign q_mix = sin_pos3 ? {mpx_in[15], mpx_in} : -{mpx_in[15], mpx_in};

    logic signed [20:0] i_lp1, i_lp2, q_lp1, q_lp2;

    logic signed [20:0] d_base;
    logic               arm_sel;
    logic [31:0]        sum_i, sum_q;
    logic [12:0]        arm_cnt;

    function automatic logic [20:0] abs21(input logic signed [20:0] v);
        abs21 = v[20] ? (-v) : v;
    endfunction

    assign d_base = arm_sel ? q_lp2 : i_lp2;

    // 3 + 4. Bit window (pilot/16), biphase integrate-and-dump, diff decode.
    logic [4:0]         tcnt;
    logic [4:0]         bit_len;
    logic signed [27:0] acc1, acc2;
    logic               d_sign, d_sign_q;
    logic signed [15:0] terr;
    logic               sym_prev;

    logic finalize;
    assign finalize = tick && (tcnt >= bit_len - 5'd1);

    logic zc;
    assign d_sign = d_base[20];
    assign zc = (d_sign != d_sign_q) && (abs21(d_base) > ZC_GATE[20:0]);

    logic [2:0]        t8;
    logic signed [3:0] terr_step;
    assign t8        = tcnt[2:0];
    assign terr_step = (t8 < 3'd4) ? $signed({1'b0, t8}) : ($signed({1'b0, t8}) - 4'sd8);

    logic        locked_q;
    logic [23:0] mag_ema;
    logic [23:0] abs_err;
    assign abs_err = err_lp[23] ? (-err_lp) : err_lp;

    logic cur_sym;
    assign cur_sym = ((acc1 - acc2) >= 0);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bp_x1    <= '0; bp_x2 <= '0; bp_y1 <= '0; bp_y2 <= '0;
            phase    <= 32'd0;
            integ    <= '0;
            err_lp   <= '0;
            i_lp1    <= '0; i_lp2 <= '0; q_lp1 <= '0; q_lp2 <= '0;
            sum_i    <= '0; sum_q <= '0; arm_cnt <= '0; arm_sel <= 1'b0;
            tcnt     <= 5'd0; bit_len <= 5'd16;
            acc1     <= '0; acc2 <= '0;
            d_sign_q <= 1'b0; terr <= '0; sym_prev <= 1'b0;
            bit_out  <= 1'b0; bit_valid <= 1'b0;
            mag_ema  <= '1; locked_q <= 1'b0; pll_locked <= 1'b0;   // start "unlocked"
        end else begin
            bit_valid <= 1'b0;

            if (mpx_valid) begin
                // pilot bandpass state.
                bp_y1 <= bp_y;  bp_y2 <= bp_y1;
                bp_x1 <= $signed({{2{mpx_in[15]}}, mpx_in});  bp_x2 <= bp_x1;

                // PLL update.
                phase  <= phase_sum[31:0];
                err_lp <= err_lp + (($signed({{5{pd[18]}}, pd}) - err_lp) >>> KE_SH);
                integ  <= integ + (err_lp >>> KI_SH);

                // data arms.
                i_lp1 <= i_lp1 + (($signed({{4{i_mix[16]}}, i_mix}) - i_lp1) >>> KD_SH);
                i_lp2 <= i_lp2 + ((i_lp1 - i_lp2) >>> KD_SH);
                q_lp1 <= q_lp1 + (($signed({{4{q_mix[16]}}, q_mix}) - q_lp1) >>> KD_SH);
                q_lp2 <= q_lp2 + ((q_lp1 - q_lp2) >>> KD_SH);

                // arm selection (which subcarrier phase carries the data).
                sum_i <= sum_i + {11'd0, abs21(i_lp2)};
                sum_q <= sum_q + {11'd0, abs21(q_lp2)};
                if (arm_cnt == 13'h1FFF) begin
                    arm_sel <= (sum_q > sum_i);
                    sum_i   <= '0;
                    sum_q   <= '0;
                    arm_cnt <= '0;
                end else begin
                    arm_cnt <= arm_cnt + 13'd1;
                end

                // lock detect: EMA of |err_lp| stays small once locked.
                if (abs_err >= mag_ema) mag_ema <= mag_ema + ((abs_err - mag_ema) >> 7);
                else                    mag_ema <= mag_ema - ((mag_ema - abs_err) >> 7);
                locked_q   <= (mag_ema < 24'd2200);
                pll_locked <= locked_q;

                // zero-crossing timing detector.
                d_sign_q <= d_sign;
                if (zc)
                    terr <= terr + {{12{terr_step[3]}}, terr_step};

                // biphase integrate-and-dump + bit window.
                if (finalize) begin
                    // Differential decode: out = current symbol XOR previous symbol.
                    bit_out   <= cur_sym ^ sym_prev;
                    sym_prev  <= cur_sym;
                    bit_valid <= 1'b1;

                    acc1 <= '0;
                    acc2 <= '0;
                    tcnt <= 5'd0;

                    // timing nudge: lengthen/shorten the next bit by one tick
                    if (terr > $signed(16'(T_THRESH))) begin
                        bit_len <= 5'd17;
                        terr    <= terr - 16'sd16;
                    end else if (terr < -$signed(16'(T_THRESH))) begin
                        bit_len <= 5'd15;
                        terr    <= terr + 16'sd16;
                    end else begin
                        bit_len <= 5'd16;
                        terr    <= terr - (terr >>> 3);   // leak
                    end
                end else begin
                    if (tcnt < 5'd8) acc1 <= acc1 + {{7{d_base[20]}}, d_base};
                    else             acc2 <= acc2 + {{7{d_base[20]}}, d_base};
                    if (tick) tcnt <= tcnt + 5'd1;
                end
            end
        end
    end

endmodule
