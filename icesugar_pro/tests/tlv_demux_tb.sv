// Testbench for tlv_demux.sv
// Drives the byte-stream interface directly (one byte/cycle, as top.sv does)
// and checks: payload routing + sop/eop framing, per-type packet counts,
// back-to-back packets, SOF re-sync after a short packet, unknown types, and
// zero-length packets. Inputs driven non-blocking after the edge so they never
// race the DUT clock (matches the repo's other TBs).

`timescale 1ns/1ps

module tlv_demux_tb;

    logic clk = 0, rst = 1;
    logic       in_valid = 0, in_sof = 0;
    logic [7:0] in_byte  = 0;

    logic       pl_valid, pl_sop, pl_eop;
    logic [7:0] pl_byte, pl_type;
    logic [15:0] iq_pkt_count, img_pkt_count, obj_pkt_count;
    logic [15:0] unknown_count, short_count, stray_count;
    logic [7:0]  last_type;

    tlv_demux dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_sof(in_sof), .in_byte(in_byte),
        .pl_valid(pl_valid), .pl_sop(pl_sop), .pl_eop(pl_eop),
        .pl_byte(pl_byte), .pl_type(pl_type),
        .iq_pkt_count(iq_pkt_count), .img_pkt_count(img_pkt_count),
        .obj_pkt_count(obj_pkt_count), .unknown_count(unknown_count),
        .short_count(short_count), .stray_count(stray_count),
        .last_type(last_type)
    );

    always #5 clk = ~clk;

    int errors = 0;

    // ---- Scoreboard: capture the payload stream between resets ----
    logic [7:0] rx_byte [0:1023];
    logic [7:0] rx_type [0:1023];
    int  rx_count, sop_count, eop_count;
    bit  sb_clr;

    always_ff @(posedge clk) begin
        if (sb_clr) begin
            rx_count  <= 0;
            sop_count <= 0;
            eop_count <= 0;
        end else if (pl_valid) begin
            rx_byte[rx_count] <= pl_byte;
            rx_type[rx_count] <= pl_type;
            rx_count <= rx_count + 1;
            if (pl_sop) sop_count <= sop_count + 1;
            if (pl_eop) eop_count <= eop_count + 1;
        end
    end

    task automatic clear_sb();
        sb_clr <= 1'b1;
        @(posedge clk);
        sb_clr <= 1'b0;
        @(posedge clk);
    endtask

    task automatic drive_byte(input logic sof, input logic [7:0] b);
        @(posedge clk);
        in_valid <= 1'b1;
        in_sof   <= sof;
        in_byte  <= b;
    endtask

    task automatic idle();
        @(posedge clk);
        in_valid <= 1'b0;
        in_sof   <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // Send a full packet; payload byte i = base + i.
    task automatic send_packet(input [7:0] t, input [15:0] len, input [7:0] base);
        drive_byte(1'b1, t);
        drive_byte(1'b0, len[15:8]);
        drive_byte(1'b0, len[7:0]);
        for (int i = 0; i < len; i++)
            drive_byte(1'b0, 8'(base + i));
    endtask

    task automatic check(input string name, input bit cond);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %s", name);
        end
    endtask

    // Verify the scoreboard holds exactly `len` payload bytes of type `t`,
    // contents base+i, with one sop and one eop.
    task automatic check_payload(input string name, input [7:0] t,
                                 input int len, input [7:0] base);
        check($sformatf("%s.count", name), rx_count == len);
        check($sformatf("%s.sop", name),   sop_count == 1);
        check($sformatf("%s.eop", name),   eop_count == 1);
        for (int i = 0; i < len && i < rx_count; i++) begin
            if (rx_byte[i] !== 8'(base + i) || rx_type[i] !== t) begin
                errors = errors + 1;
                if (errors < 12)
                    $display("FAIL: %s byte %0d: got type %02h data %02h, exp type %02h data %02h",
                             name, i, rx_type[i], rx_byte[i], t, 8'(base + i));
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        // 1) Well-formed IQ packet (8 payload bytes)
        clear_sb();
        send_packet(8'h00, 16'd8, 8'hA0);
        idle();
        check("iq.count1", iq_pkt_count == 16'd1);
        check_payload("iq", 8'h00, 8, 8'hA0);
        check("iq.last_type", last_type == 8'h00);

        // 2) Image-row packet
        clear_sb();
        send_packet(8'h01, 16'd5, 8'h10);
        idle();
        check("img.count1", img_pkt_count == 16'd1);
        check_payload("img", 8'h01, 5, 8'h10);

        // 3) Object-list packet
        clear_sb();
        send_packet(8'h02, 16'd3, 8'h70);
        idle();
        check("obj.count1", obj_pkt_count == 16'd1);
        check_payload("obj", 8'h02, 3, 8'h70);

        // 4) Unknown type
        clear_sb();
        send_packet(8'h55, 16'd2, 8'h00);
        idle();
        check("unknown.count1", unknown_count == 16'd1);

        // 5) Two back-to-back IQ packets (no idle between)
        clear_sb();
        send_packet(8'h00, 16'd4, 8'h20);
        send_packet(8'h00, 16'd4, 8'h30);   // second SOF immediately follows
        idle();
        check("iq.count3", iq_pkt_count == 16'd3);   // 1 from test-1 + 2 here
        check("b2b.count", rx_count == 8);
        check("b2b.sop",   sop_count == 2);
        check("b2b.eop",   eop_count == 2);

        // 6) Short packet then resync: claim LEN=10 but a new SOF arrives after
        //    3 payload bytes. short_count++ and the new packet parses cleanly.
        clear_sb();
        drive_byte(1'b1, 8'h00);            // type IQ
        drive_byte(1'b0, 8'h00);            // LEN hi
        drive_byte(1'b0, 8'd10);            // LEN lo = 10
        drive_byte(1'b0, 8'hE0);            // payload 0
        drive_byte(1'b0, 8'hE1);            // payload 1
        drive_byte(1'b0, 8'hE2);            // payload 2
        send_packet(8'h00, 16'd2, 8'hF0);   // new SOF aborts the previous
        idle();
        check("short.count", short_count == 16'd1);
        check("resync.eop",  eop_count == 1);          // only the clean 2-byte pkt completed
        check("resync.last2", rx_byte[rx_count-1] == 8'hF1);

        // 7) Zero-length IQ packet
        clear_sb();
        send_packet(8'h00, 16'd0, 8'h00);
        idle();
        check("zlp.nodata", rx_count == 0);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
