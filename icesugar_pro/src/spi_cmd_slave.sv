module spi_cmd_slave (
    input logic spi_clk,
    input logic spi_cs_n,
    input logic spi_mosi,

    input logic clk,
    input logic rst,

    output logic cmd_valid,
    output logic [7:0] cmd,
    output logic [31:0] arg
);

logic [7:0] shift;
logic [2:0] bit_cnt;
logic [2:0] byte_cnt;
logic [7:0] cmd_spi;
logic [31:0] arg_spi;
logic req_toggle_spi;

logic req_meta, req_sync, req_seen;
logic [7:0] cmd_hold;
logic [31:0] arg_hold;

wire [7:0] next_byte = {shift[6:0], spi_mosi};

initial begin
    shift = '0;
    bit_cnt = '0;
    byte_cnt = '0;
    cmd_spi = '0;
    arg_spi = '0;
    req_toggle_spi = 1'b0;
    cmd_hold = '0;
    arg_hold = '0;
end

always_ff @(posedge spi_clk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
        shift <= '0;
        bit_cnt <= '0;
        byte_cnt <= '0;
    end else begin
        shift <= next_byte;
        if (bit_cnt == 3'd7) begin
            bit_cnt <= '0;
            case (byte_cnt)
                3'd0: cmd_spi <= next_byte;
                3'd1: arg_spi[31:24] <= next_byte;
                3'd2: arg_spi[23:16] <= next_byte;
                3'd3: arg_spi[15:8] <= next_byte;
                3'd4: begin
                    arg_spi[7:0] <= next_byte;
                    cmd_hold <= cmd_spi;
                    arg_hold <= {arg_spi[31:8], next_byte};
                    req_toggle_spi <= ~req_toggle_spi;
                end
                default: begin
                end
            endcase
            if (byte_cnt != 3'd7)
                byte_cnt <= byte_cnt + 3'd1;
        end else begin
            bit_cnt <= bit_cnt + 3'd1;
        end
    end
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        req_meta <= 1'b0;
        req_sync <= 1'b0;
        req_seen <= 1'b0;
        cmd_valid <= 1'b0;
        cmd <= '0;
        arg <= '0;
    end else begin
        req_meta <= req_toggle_spi;
        req_sync <= req_meta;
        cmd_valid <= 1'b0;
        if (req_sync != req_seen) begin
            req_seen <= req_sync;
            cmd <= cmd_hold;
            arg <= arg_hold;
            cmd_valid <= 1'b1;
        end
    end
end

endmodule
