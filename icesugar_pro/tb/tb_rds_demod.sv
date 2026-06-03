`timescale 1ns/1ps

// tb_rds_demod — synthesize an FM composite (MPX) signal carrying RDS and verify
// the demodulator recovers the transmitted bit stream.
//
// MPX = 19 kHz pilot + 57 kHz suppressed-carrier DSB biphase subcarrier (coherent
// 3rd harmonic of the pilot) modulated by a known, differentially-encoded random
// bit pattern at 1187.5 bps. Sample rate 260.417 kHz (one sample per clock).
//
// The demod has an unknown lock/pipeline latency, so the test records the
// recovered bits and finds the bit alignment that minimizes mismatches against
// the transmitted pattern; it passes if a long run matches at the best offset.

module tb_rds_demod;

    localparam real PI  = 3.14159265358979323846;
    localparam real FS  = 260417.0;
    localparam real FP  = 19000.0;
    localparam real SPB = FS / 1187.5;          // samples per bit (~219.3)

    localparam int  NTX  = 400;                 // transmitted bits
    localparam int  NSAMP = 90000;              // ~ NTX*SPB samples

    localparam CLK_PERIOD = 40;

    logic clk = 0, rst;
    logic signed [15:0] mpx_in;
    logic               mpx_valid;
    logic               bit_out, bit_valid, pll_locked;

    rds_demod dut (
        .clk(clk), .rst(rst),
        .mpx_in(mpx_in), .mpx_valid(mpx_valid),
        .bit_out(bit_out), .bit_valid(bit_valid), .pll_locked(pll_locked)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Transmitted data and its differential encoding.
    bit tx_b [0:NTX-1];      // payload bits
    bit tx_t [0:NTX-1];      // differentially-encoded symbols actually sent

    // Recovered bits.
    bit rx_b [0:1023];
    int rx_n = 0;

    always @(posedge clk) begin
        if (!rst && bit_valid && rx_n < 1024) begin
            rx_b[rx_n] = bit_out;
            rx_n++;
        end
    end

    // Generate one MPX sample for absolute sample index n. Includes realistic
    // multiplex clutter: L+R mono audio (0-15 kHz) and an L-R DSB component on the
    // 38 kHz stereo subcarrier, which the demod must reject.
    function automatic real mpx_sample(input int n);
        real theta_p, pos, frac, t;
        int  k, half, sym;
        real bp, pilot, rds, audio, stereo, lr;
        begin
            theta_p = 2.0*PI*FP*n/FS;
            t    = n / FS;
            pos  = n / SPB;
            k    = $rtoi(pos);
            if (k > NTX-1) k = NTX-1;
            frac = pos - k;
            half = (frac >= 0.5) ? 1 : 0;        // biphase half-bit
            sym  = tx_t[k] ? 1 : -1;             // +/-1 from the sent symbol
            bp   = sym * (half == 0 ? 1.0 : -1.0);
            pilot  = 6000.0 * $sin(theta_p);
            rds    = 3500.0 * bp * $cos(3.0*theta_p);            // in-phase with cos(3*theta)
            lr     = 0.6*$sin(2.0*PI*1500.0*t) + 0.4*$sin(2.0*PI*6000.0*t);
            audio  = 8000.0 * lr;                                // L+R baseband
            stereo = 4000.0 * $sin(2.0*PI*900.0*t) * $sin(2.0*theta_p); // L-R DSB at 38 kHz
            mpx_sample = pilot + rds + audio + stereo;
        end
    endfunction

    integer seed = 32'hC0FFEE;
    int i, n, s, mism, best_s, best_mism;
    int errors = 0;
    localparam int WARM = 120;   // skip lock transient
    localparam int CMP  = 160;   // compare-window length

    initial begin
        $dumpfile("build/rds_demod.vcd");
        $dumpvars(0, tb_rds_demod);

        // Build payload + differential encoding (t[k] = t[k-1] ^ b[k]).
        for (i = 0; i < NTX; i++) tx_b[i] = $random(seed) & 1;
        tx_t[0] = tx_b[0];
        for (i = 1; i < NTX; i++) tx_t[i] = tx_t[i-1] ^ tx_b[i];

        rst = 1'b1;
        mpx_in = '0;
        mpx_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        for (n = 0; n < NSAMP; n++) begin
            @(posedge clk);
            mpx_in    <= $rtoi(mpx_sample(n));
            mpx_valid <= 1'b1;
        end
        @(posedge clk);
        mpx_valid <= 1'b0;
        repeat (10) @(posedge clk);

        $display("recovered %0d bits, pll_locked=%b", rx_n, pll_locked);

        if (rx_n < WARM + CMP) begin
            $display("FAIL too few bits recovered (%0d)", rx_n);
            errors++;
        end else begin
            // Find the tx alignment minimizing mismatches for the compare window.
            best_mism = CMP + 1;
            best_s    = 0;
            for (s = 0; s <= NTX - CMP; s++) begin
                mism = 0;
                for (i = 0; i < CMP; i++)
                    if (rx_b[WARM + i] != tx_b[s + i]) mism++;
                if (mism < best_mism) begin best_mism = mism; best_s = s; end
            end
            $display("best alignment shift=%0d, mismatches=%0d / %0d", best_s, best_mism, CMP);
            if (best_mism > 2) begin
                $display("FAIL bit error rate too high");
                errors++;
            end
        end

        if (!pll_locked) begin $display("FAIL pll_locked not asserted"); errors++; end

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
