`timescale 1ns/1ps

module top_tb;

localparam CLK_PERIOD = 40;
localparam SPI_HALF = 5 * CLK_PERIOD;

logic CLK;
logic spi_clk, cs, mosi, miso;
logic spi_clk_pico, cs1, mosi_pico;
logic i2s_bclk, i2s_lrclk, i2s_sdata;
logic LCD_CLK, LCD_DEN;
logic [4:0] LCD_R;
logic [5:0] LCD_G;
logic [4:0] LCD_B;

top dut (
    .CLK (CLK),
    .spi_clk (spi_clk),
    .cs (cs),
    .mosi (mosi),
    .miso (miso),
    .spi_clk_pico (spi_clk_pico),
    .cs1 (cs1),
    .mosi_pico (mosi_pico),
    .i2s_bclk (i2s_bclk),
    .i2s_lrclk (i2s_lrclk),
    .i2s_sdata (i2s_sdata),
    .LCD_CLK (LCD_CLK),
    .LCD_DEN (LCD_DEN),
    .LCD_R (LCD_R),
    .LCD_G (LCD_G),
    .LCD_B (LCD_B)
);

// Clock
initial CLK = 0;
always #(CLK_PERIOD/2) CLK = ~CLK;

initial begin
    spi_clk = 1;
    cs = 1;
    mosi = 0;
    spi_clk_pico = 1;
    cs1 = 1;
    mosi_pico = 0;
end

task automatic spi_send_iq(input logic [15:0] i_val, input logic [15:0] q_val);
    logic [31:0] data;
    int k;
    data = {i_val, q_val};
    cs = 0;
    #SPI_HALF;
    for (k = 31; k >= 0; k--) begin
        mosi = data[k];
        #SPI_HALF;
        spi_clk = 0;
        #SPI_HALF;
        spi_clk = 1;
    end
    mosi = 0;
    #SPI_HALF;
    cs = 1;
    #(4 * SPI_HALF);
endtask

function automatic logic [15:0] crc16_update(input logic [15:0] crc_in, input logic [7:0] data);
    logic [15:0] crc;
    int b;
    begin
        crc = crc_in ^ {data, 8'h00};
        for (b = 0; b < 8; b++) begin
            if (crc[15])
                crc = {crc[14:0], 1'b0} ^ 16'h1021;
            else
                crc = {crc[14:0], 1'b0};
        end
        crc16_update = crc;
    end
endfunction

task automatic pico_send_byte(input logic [7:0] data);
    int k;
    for (k = 7; k >= 0; k--) begin
        mosi_pico = data[k];
        #SPI_HALF;
        spi_clk_pico = 1;
        #SPI_HALF;
        spi_clk_pico = 0;
    end
endtask

task automatic spi_send_full_state(
    input logic [7:0] demod,
    input logic [7:0] volume,
    input logic [31:0] freq_hz,
    input logic [7:0] flags
);
    logic [15:0] crc;
    logic [7:0] b;
    int i;
    cs1 = 0;
    spi_clk_pico = 0;
    #SPI_HALF;

    crc = 16'hFFFF;
    pico_send_byte(8'hA5);
    pico_send_byte(8'h01); crc = crc16_update(crc, 8'h01);
    pico_send_byte(8'h34); crc = crc16_update(crc, 8'h34);
    pico_send_byte(8'h02); crc = crc16_update(crc, 8'h02);

    for (i = 0; i < 564; i++) begin
        case (i)
            0: b = 8'd3;
            1: b = (demod == 8'd2) ? 8'd1 : ((demod == 8'd3) ? 8'd2 : 8'd0);
            2: b = demod;
            3: b = volume;
            4: b = freq_hz[7:0];
            5: b = freq_hz[15:8];
            6: b = freq_hz[23:16];
            7: b = freq_hz[31:24];
            11: b = flags;
            16: b = 8'hff;
            17: b = 8'd80;
            18: b = 8'd75;
            default: b = 8'd0;
        endcase
        pico_send_byte(b);
        crc = crc16_update(crc, b);
    end

    pico_send_byte(crc[7:0]);
    pico_send_byte(crc[15:8]);
    mosi_pico = 0;
    #SPI_HALF;
    cs1 = 1;
    spi_clk_pico = 1;
    #(4 * SPI_HALF);
endtask

integer errors = 0;

initial begin
    $dumpfile("build/top.vcd");
    $dumpvars(0, top_tb);

    #(20 * CLK_PERIOD);

    // SPI data path
    $display("TEST 1: SPI data path");

    spi_send_iq(16'h1234, 16'h5678);
    #(20 * CLK_PERIOD);

    spi_send_iq(16'hABCD, 16'hEF01);
    #(20 * CLK_PERIOD);
    $display("  PASS SPI clocking smoke completed");

    // Pico command path
    $display("TEST 2: Pico command path");

    spi_send_full_state(8'd2, 8'd50, 32'd101_700_000, 8'h01);
    #(40 * CLK_PERIOD);
    if (dut.volume !== 8'h7F) begin
        $display("  FAIL volume: expected 0x7F got 0x%02X", dut.volume);
        errors++;
    end else
        $display("  PASS volume = 0x7F");

    if (dut.freq_hz !== 32'd101_700_000) begin
        $display("  FAIL freq_hz: expected 101700000 got %0d", dut.freq_hz);
        errors++;
    end else
        $display("  PASS freq_hz = 101700000");

    if (dut.mode !== 3'd2) begin
        $display("  FAIL mode: expected 2 got %0d", dut.mode);
        errors++;
    end else
        $display("  PASS mode = 2");

    if (dut.mute !== 1'b1) begin
        $display("  FAIL mute: expected 1 got %0d", dut.mute);
        errors++;
    end else
        $display("  PASS mute = 1");

    // I2S pipeline
    $display("TEST 3: I2S pipeline");
    #(10 * CLK_PERIOD);

    if (i2s_bclk === 1'bx) begin
        $display("  FAIL i2s_bclk is X");
        errors++;
    end else
        $display("  PASS i2s_bclk active");

    if (i2s_lrclk === 1'bx) begin
        $display("  FAIL i2s_lrclk is X");
        errors++;
    end else
        $display("  PASS i2s_lrclk active");

    // LCD outputs
    $display("TEST 4: LCD outputs");
    #(100 * CLK_PERIOD);
    if (LCD_DEN === 1'bx) begin
        $display("  FAIL LCD_DEN is X");
        errors++;
    end else
        $display("  PASS LCD_DEN active");

    // Summary
    #(CLK_PERIOD);
    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);

    $finish;
end

// Timeout
initial begin
    #(10_000_000);
    $display("TIMEOUT");
    $finish;
end

endmodule
