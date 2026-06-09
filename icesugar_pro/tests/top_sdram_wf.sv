module top_sdram_wf #(
    parameter int H_ACTIVE   = 800,
    parameter int H_TOTAL    = 928,
    parameter int V_ACTIVE   = 480,
    parameter int V_TOTAL    = 525,
    parameter int LINE_WORDS = 800,
    parameter int CLKFB_DIV    = 4,
    parameter int CLKOP_DIV    = 6,
    parameter int CLKOS_DIV    = 20,
    parameter int CLKOP_CPHASE = 2,
    parameter int CLKOS_CPHASE = 2,
    parameter int TREF         = 780,
    parameter bit SDRAM_CLK_INV = 1'b0,
    parameter int CAP_PHASE    = 0,
    parameter bit WRITE_EN      = 1'b1,
    parameter bit FREEZE_SCROLL = 1'b0,
    parameter int GEN_DIV       = 256
) (
    input  logic        CLK,
    output logic        LCD_CLK,
    output logic        LCD_DEN,
    output logic [4:0]  LCD_R,
    output logic [5:0]  LCD_G,
    output logic [4:0]  LCD_B,
    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_dm,
    inout  wire  [15:0] sdram_dq
);

    logic clk_sdram, clk_pix, clk90, pll_locked;
`ifdef SIMULATION
    assign clk_sdram = CLK;
    logic [1:0] pdiv = 2'd0;
    always_ff @(posedge CLK) pdiv <= pdiv + 2'd1;
    assign clk_pix = pdiv[1];
    assign clk90   = CLK;
    assign pll_locked = 1'b1;
`else
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(CLKOP_DIV), .CLKOP_CPHASE(CLKOP_CPHASE), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(CLKOS_DIV), .CLKOS_CPHASE(CLKOS_CPHASE), .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(6), .CLKOS2_CPHASE(3), .CLKOS2_FPHASE(4),
        .CLKOS3_ENABLE("DISABLED"), .CLKOS3_DIV(1), .CLKOS3_CPHASE(0), .CLKOS3_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(CLKFB_DIV)
    ) u_pll (
        .CLKI(CLK), .CLKFB(clk_sdram), .CLKOP(clk_sdram), .CLKOS(clk_pix),
        .CLKOS2(clk90), .CLKOS3(), .RST(1'b0), .STDBY(1'b0),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .ENCLKOS(1'b0), .ENCLKOS2(1'b0), .ENCLKOS3(1'b0), .LOCK(pll_locked)
    );
`endif

    logic [7:0] srst_cnt = 8'd0; logic sys_rst = 1'b1;     // clk_sdram domain
    always_ff @(posedge clk_sdram) begin
        if (!pll_locked) begin srst_cnt <= 8'd0; sys_rst <= 1'b1; end
        else if (!srst_cnt[7]) begin srst_cnt <= srst_cnt + 8'd1; sys_rst <= 1'b1; end
        else sys_rst <= 1'b0;
    end
    logic [7:0] prst_cnt = 8'd0; logic pix_rst = 1'b1;     // clk_pix domain
    always_ff @(posedge clk_pix) begin
        if (!pll_locked) begin prst_cnt <= 8'd0; pix_rst <= 1'b1; end
        else if (!prst_cnt[7]) begin prst_cnt <= prst_cnt + 8'd1; pix_rst <= 1'b1; end
        else pix_rst <= 1'b0;
    end
    wire wrst = ~pll_locked;                               // CLK (25 MHz) domain

    logic        m_req_valid, m_req_wr, m_req_ready, m_wr_valid, m_wr_ready, m_rd_valid, m_done;
    logic [24:0] m_req_addr;
    logic [9:0]  m_req_len;
    logic [15:0] m_wr_data, m_rd_data;
    logic [15:0] dq_out, dq_in; logic dq_oe;

    sdram_ctrl #(.TREF_PERIOD(TREF), .RD_LAT(3)) u_ctrl (
        .clk(clk_sdram), .rst(sys_rst),
        .req_valid(m_req_valid), .req_wr(m_req_wr), .req_addr(m_req_addr), .req_len(m_req_len),
        .req_ready(m_req_ready),
        .wr_data(m_wr_data), .wr_valid(m_wr_valid), .wr_ready(m_wr_ready),
        .rd_data(m_rd_data), .rd_valid(m_rd_valid), .done(m_done),
        .sdram_clk(/* driven below */),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in), .sdram_dm(sdram_dm)
    );
    assign sdram_dq = dq_oe ? dq_out : 16'hzzzz;
    logic [15:0] cap0, cap1, cap2, cap3;
    always_ff @(posedge clk_sdram) cap0 <= sdram_dq;
    always_ff @(posedge clk90)     cap1 <= sdram_dq;
    always_ff @(negedge clk_sdram) cap2 <= sdram_dq;
    always_ff @(negedge clk90)     cap3 <= sdram_dq;
    always_comb begin
        case (CAP_PHASE)
            0:       dq_in = cap0;
            1:       dq_in = cap1;
            2:       dq_in = cap2;
            default: dq_in = cap3;
        endcase
    end
    assign sdram_clk = SDRAM_CLK_INV ? ~clk_sdram : clk_sdram;

    logic clr_done;
    logic [2:0]       c_req_valid, c_req_wr, c_req_ready, c_wr_valid, c_wr_ready, c_rd_valid, c_done;
    logic [3*25-1:0]  c_req_addr;
    logic [3*10-1:0]  c_req_len;
    logic [3*16-1:0]  c_wr_data, c_rd_data;

    sdram_arb #(.N(3)) u_arb (
        .clk(clk_sdram), .rst(sys_rst),
        .c_req_valid(c_req_valid), .c_req_wr(c_req_wr), .c_req_addr(c_req_addr), .c_req_len(c_req_len),
        .c_req_ready(c_req_ready), .c_wr_data(c_wr_data), .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready),
        .c_rd_data(c_rd_data), .c_rd_valid(c_rd_valid), .c_done(c_done),
        .m_req_valid(m_req_valid), .m_req_wr(m_req_wr), .m_req_addr(m_req_addr), .m_req_len(m_req_len),
        .m_req_ready(m_req_ready), .m_wr_data(m_wr_data), .m_wr_valid(m_wr_valid), .m_wr_ready(m_wr_ready),
        .m_rd_data(m_rd_data), .m_rd_valid(m_rd_valid), .m_done(m_done),
        .gnt_valid(), .gnt()
    );

    logic        so_req_valid; logic [24:0] so_req_addr; logic [9:0] so_req_len;
    logic [1:0]  w_slot; logic [9:0] w_col; logic [15:0] w_data; logic w_en;
    logic [8:0]  wf_base_row;
    logic [10:0] x; logic [9:0] y; logic de;

    wire vblank_pix = (y >= V_ACTIVE[9:0]);
    logic vb1, vb2, vb3;
    always_ff @(posedge clk_sdram) begin vb1 <= vblank_pix; vb2 <= vb1; vb3 <= vb2; end
    wire vb_rise = vb2 & ~vb3;
    logic [8:0] wf_base_frame;
    always_ff @(posedge clk_sdram) begin
        if (sys_rst)      wf_base_frame <= 9'd0;
        else if (vb_rise) wf_base_frame <= wf_base_row;
    end

    scan_out #(.LINE_WORDS(LINE_WORDS), .NLINES(V_ACTIVE), .MAX_BURST(256), .HALF_PAGE(1)) u_scan (
        .clk(clk_sdram), .rst(sys_rst | ~clr_done),
        .px_line(y[8:0]), .px_hblank((x >= H_ACTIVE[10:0]) && (y < V_ACTIVE[9:0])),
        .wf_base_row(FREEZE_SCROLL ? 9'd0 : wf_base_frame),
        .req_valid(so_req_valid), .req_addr(so_req_addr), .req_len(so_req_len),
        .req_ready(c_req_ready[0]), .rd_data(c_rd_data[15:0]), .rd_valid(c_rd_valid[0]), .done(c_done[0]),
        .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en), .busy()
    );
    assign c_req_valid[0]       = so_req_valid;
    assign c_req_wr[0]          = 1'b0;
    assign c_req_addr[0*25 +:25] = so_req_addr;
    assign c_req_len [0*10 +:10] = so_req_len;
    assign c_wr_data [0*16 +:16] = 16'd0;
    assign c_wr_valid[0]        = 1'b0;

    logic        comp_req_valid, comp_req_wr, comp_wr_valid, comp_busy;
    logic [24:0] comp_req_addr; logic [9:0] comp_req_len; logic [15:0] comp_wr_data;
    logic [7:0]  mag_in; logic mag_valid;

    compositor #(.ROW_WORDS(LINE_WORDS), .NLINES(V_ACTIVE), .MAX_BURST(256), .HALF_PAGE(1), .TEST_PATTERN(1)) u_comp (
        .clk(clk_sdram), .rst(sys_rst | ~clr_done),
        .mag_in(mag_in), .mag_valid(mag_valid), .wf_base_row(wf_base_row),
        .req_valid(comp_req_valid), .req_wr(comp_req_wr), .req_addr(comp_req_addr), .req_len(comp_req_len),
        .req_ready(c_req_ready[1]), .wr_data(comp_wr_data), .wr_valid(comp_wr_valid), .wr_ready(c_wr_ready[1]),
        .done(c_done[1]), .busy(comp_busy)
    );
    assign c_req_valid[1]       = WRITE_EN ? comp_req_valid : 1'b0;
    assign c_req_wr[1]          = comp_req_wr;
    assign c_req_addr[1*25 +:25] = comp_req_addr;
    assign c_req_len [1*10 +:10] = comp_req_len;
    assign c_wr_data [1*16 +:16] = comp_wr_data;
    assign c_wr_valid[1]        = WRITE_EN ? comp_wr_valid : 1'b0;

    logic        clr_req_valid, clr_wr_valid;
    logic [18:0] clr_word;
    logic [10:0] clr_left;
    logic [8:0]  clr_line;
    logic [9:0]  clr_beats;
    typedef enum logic [2:0] { CL_INIT, CL_REQ, CL_WRITE, CL_WAIT, CL_DONE } cl_e;
    cl_e clst;
    wire  [9:0]  clr_col = 10'(clr_word % 256);
    wire  [10:0] clr_rem = 11'd256 - {1'b0, clr_col};
    wire  [10:0] clr_seg = (clr_rem < clr_left) ? clr_rem : clr_left;
    logic [10:0] clr_seg_r;
    always_ff @(posedge clk_sdram) clr_seg_r <= clr_seg;

    always_ff @(posedge clk_sdram) begin
        if (sys_rst) begin
            clst <= CL_REQ; clr_word <= 19'd0; clr_left <= LINE_WORDS[10:0]; clr_line <= 9'd0;
            clr_beats <= 10'd0; clr_req_valid <= 1'b0; clr_wr_valid <= 1'b0; clr_done <= 1'b0;
        end else begin
            case (clst)
                CL_REQ: begin
                    clr_req_valid <= 1'b1; clr_beats <= 10'd0;
                    if (clr_req_valid && c_req_ready[2]) begin
                        clr_req_valid <= 1'b0; clr_wr_valid <= 1'b1; clst <= CL_WRITE;
                    end
                end
                CL_WRITE: begin
                    clr_wr_valid <= 1'b1;
                    if (c_wr_ready[2] && clr_wr_valid) begin
                        if (clr_beats == clr_seg_r[9:0] - 10'd1) begin
                            clr_wr_valid <= 1'b0;
                            clr_word <= clr_word + 19'(clr_seg_r);
                            clr_left <= clr_left - clr_seg_r;
                            clst     <= CL_WAIT;
                        end else clr_beats <= clr_beats + 10'd1;
                    end
                end
                CL_WAIT: if (c_done[2]) begin
                    if (clr_left != 11'd0)                    clst <= CL_REQ;
                    else if (clr_line == V_ACTIVE[8:0] - 9'd1) clst <= CL_DONE;
                    else begin clr_line <= clr_line + 9'd1; clr_left <= LINE_WORDS[10:0]; clst <= CL_REQ; end
                end
                CL_DONE: clr_done <= 1'b1;
                default: clst <= CL_INIT;
            endcase
        end
    end
    assign c_req_valid[2]       = clr_req_valid;
    assign c_req_wr[2]          = 1'b1;
    assign c_req_addr[2*25 +:25] = (25'(clr_word / 256) << 10) | (25'(clr_col) << 1);
    assign c_req_len [2*10 +:10] = clr_seg_r[9:0];
    assign c_wr_data [2*16 +:16] = 16'h0000;
    assign c_wr_valid[2]        = clr_wr_valid;

    logic [7:0] gen_wdata; logic gen_wpush, gen_wfull;
    logic [9:0] gen_col = 10'd0; logic [8:0] gen_row = 9'd0;
    logic [15:0] gen_divcnt = 16'd0;
    wire  gen_tick = (gen_divcnt == GEN_DIV[15:0] - 16'd1);
    assign gen_wpush = gen_tick && !gen_wfull;
    assign gen_wdata = 8'(gen_col[9:2]);
    always_ff @(posedge CLK or posedge wrst) begin
        if (wrst) begin gen_col <= 10'd0; gen_row <= 9'd0; gen_divcnt <= 16'd0; end
        else begin
            gen_divcnt <= gen_tick ? 16'd0 : gen_divcnt + 16'd1;
            if (gen_wpush && !gen_wfull) begin
                if (gen_col == LINE_WORDS[9:0] - 10'd1) begin
                    gen_col <= 10'd0;
                    gen_row <= (gen_row == V_ACTIVE[8:0] - 9'd1) ? 9'd0 : gen_row + 9'd1;
                end else gen_col <= gen_col + 10'd1;
            end
        end
    end

    logic [7:0] gen_rdata; logic gen_rpop, gen_rempty;
    async_fifo #(.WIDTH(8), .DEPTH(32)) u_fifo (
        .wclk(CLK),       .wrst(wrst),  .wdata(gen_wdata), .wpush(gen_wpush), .wfull(gen_wfull),
        .rclk(clk_sdram), .rrst(sys_rst), .rdata(gen_rdata), .rpop(gen_rpop),  .rempty(gen_rempty)
    );

    typedef enum logic [0:0] { FD_FEED, FD_WAIT } fd_e;
    fd_e fdst;
    logic [10:0] feed_cnt; logic feed_pending;
    assign gen_rpop = clr_done && (fdst == FD_FEED) && (feed_cnt < LINE_WORDS[10:0]) && !feed_pending && !gen_rempty;
    always_ff @(posedge clk_sdram) begin
        if (sys_rst | ~clr_done) begin
            fdst <= FD_FEED; feed_cnt <= 11'd0; feed_pending <= 1'b0; mag_valid <= 1'b0; mag_in <= 8'd0;
        end else begin
            mag_valid <= 1'b0;
            case (fdst)
                FD_FEED: begin
                    if (feed_cnt == LINE_WORDS[10:0]) fdst <= FD_WAIT;
                    else if (feed_pending) begin
                        mag_in <= gen_rdata; mag_valid <= 1'b1;
                        feed_cnt <= feed_cnt + 11'd1; feed_pending <= 1'b0;
                    end else if (!gen_rempty) begin
                        feed_pending <= 1'b1;
                    end
                end
                FD_WAIT: if (!comp_busy) begin feed_cnt <= 11'd0; fdst <= FD_FEED; end
            endcase
        end
    end

    // line cache + display
    logic [15:0] px_data;
    line_cache u_cache (
        .wclk(clk_sdram), .w_slot(w_slot), .w_col(w_col), .w_data(w_data), .w_en(w_en),
        .rclk(clk_pix),   .r_slot(y[1:0]), .r_col((x < H_ACTIVE[10:0]) ? x[9:0] : 10'd0),
        .r_data(px_data)
    );

    scan_timing #(.H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE), .V_TOTAL(V_TOTAL))
    u_timing (.pclk(clk_pix), .rst(pix_rst), .x(x), .y(y), .de(de));

    assign LCD_CLK = clk_pix;
    logic de_d;
    always_ff @(posedge clk_pix) de_d <= de;
    assign LCD_DEN = de_d;
    assign LCD_R = de_d ? px_data[15:11] : 5'd0;
    assign LCD_G = de_d ? px_data[10:5]  : 6'd0;
    assign LCD_B = de_d ? px_data[4:0]   : 5'd0;

endmodule
