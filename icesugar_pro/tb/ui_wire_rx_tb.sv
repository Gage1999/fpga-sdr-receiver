module ui_wire_rx_tb;
    logic spi_clk = 1'b0;
    logic spi_cs_n = 1'b1;
    logic spi_mosi = 1'b0;
    logic clk = 1'b0;
    logic rst = 1'b1;

    logic [1:0]  layout;
    logic [1:0]  demod;
    logic [7:0]  volume;
    logic [31:0] freq_hz;
    logic [15:0] span_hz_log2;
    logic [7:0]  flags;
    logic [9:0]  touch_x;
    logic [9:0]  touch_y;
    logic [7:0]  active_button;
    logic [191:0] rds_line;
    logic        frame_valid;

    int errors = 0;

    ui_wire_rx dut (
        .spi_clk(spi_clk),
        .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi),
        .clk(clk),
        .rst(rst),
        .layout(layout),
        .demod(demod),
        .volume(volume),
        .freq_hz(freq_hz),
        .span_hz_log2(span_hz_log2),
        .flags(flags),
        .touch_x(touch_x),
        .touch_y(touch_y),
        .active_button(active_button),
        .rds_line(rds_line),
        .frame_valid(frame_valid)
    );

    always #5 clk = ~clk;

    task automatic check(input string name, input bit cond);
        begin
            if (!cond) begin
                errors++;
                $display("FAIL: %s", name);
            end
        end
    endtask

    task automatic spi_byte(input logic [7:0] b);
        begin
            for (int i = 7; i >= 0; i--) begin
                spi_mosi = b[i];
                #20 spi_clk = 1'b1;
                #20 spi_clk = 1'b0;
            end
        end
    endtask

    task automatic send_good_partial;
        begin
            // A5 02 13 00 payload CRC. Payload chunks:
            //   span_hz_log2 @ off 8  = 16
            //   freq_hz      @ off 4  = 101100000
            //   volume       @ off 3  = 42
            spi_cs_n = 1'b0; #20;
            spi_byte(8'ha5); spi_byte(8'h02); spi_byte(8'h13); spi_byte(8'h00);
            spi_byte(8'h08); spi_byte(8'h00); spi_byte(8'h02); spi_byte(8'h00);
            spi_byte(8'h10); spi_byte(8'h00);
            spi_byte(8'h04); spi_byte(8'h00); spi_byte(8'h04); spi_byte(8'h00);
            spi_byte(8'he0); spi_byte(8'ha9); spi_byte(8'h06); spi_byte(8'h06);
            spi_byte(8'h03); spi_byte(8'h00); spi_byte(8'h01); spi_byte(8'h00);
            spi_byte(8'h2a); spi_byte(8'h11); spi_byte(8'he7);
            spi_cs_n = 1'b1; #100;
        end
    endtask

    task automatic send_bad_crc_partial;
        begin
            // Same partial format, attempts span_hz_log2 = 18, CRC corrupted.
            spi_cs_n = 1'b0; #20;
            spi_byte(8'ha5); spi_byte(8'h02); spi_byte(8'h06); spi_byte(8'h00);
            spi_byte(8'h08); spi_byte(8'h00); spi_byte(8'h02); spi_byte(8'h00);
            spi_byte(8'h12); spi_byte(8'h00); spi_byte(8'hb0); spi_byte(8'hdb);
            spi_cs_n = 1'b1; #200;
        end
    endtask

    task automatic send_good_rds_partial;
        begin
            // rds_text @ off 20 = "KUCR"; CRC over opcode/len/payload.
            spi_cs_n = 1'b0; #20;
            spi_byte(8'ha5); spi_byte(8'h02); spi_byte(8'h08); spi_byte(8'h00);
            spi_byte(8'h14); spi_byte(8'h00); spi_byte(8'h04); spi_byte(8'h00);
            spi_byte(8'h4b); spi_byte(8'h55); spi_byte(8'h43); spi_byte(8'h52);
            spi_byte(8'h1a); spi_byte(8'hed);
            spi_cs_n = 1'b1; #100;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        check("default freq", freq_hz == 32'd100_000_000);
        check("default span", span_hz_log2 == 16'd17);
        check("default volume", volume == 8'd50);
        check("default rds blank", rds_line[7:0] == 8'h20);

        send_good_partial();
        repeat (20) @(posedge clk);
        check("updated freq", freq_hz == 32'd101_100_000);
        check("updated span", span_hz_log2 == 16'd16);
        check("updated volume", volume == 8'd42);

        send_bad_crc_partial();
        repeat (20) @(posedge clk);
        check("bad crc ignored span", span_hz_log2 == 16'd16);

        send_good_rds_partial();
        repeat (20) @(posedge clk);
        check("updated rds", rds_line[31:0] == 32'h5243_554b);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
