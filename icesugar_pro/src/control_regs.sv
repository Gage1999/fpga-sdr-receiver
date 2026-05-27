module control_regs (
    input logic clk,
    input logic rst,

    input logic cmd_valid,
    input logic [7:0] cmd,
    input logic [31:0] arg,

    output logic [2:0] mode,
    output logic [7:0] volume,
    output logic mute,
    output logic [31:0] freq_hz
);

localparam CMD_SET_MODE = 8'h01;
localparam CMD_SET_VOLUME = 8'h02;
localparam CMD_SET_FREQ = 8'h03;

localparam MODE_FM = 3'd0;

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        mode <= MODE_FM;
        volume <= 8'hff;
        mute <= 1'b0;
        freq_hz <= 32'd100_100_000;
    end else if (cmd_valid) begin
        case (cmd)
            CMD_SET_MODE: begin
                mode <= arg[2:0];
            end
            CMD_SET_VOLUME: begin
                volume <= arg[7:0];
                mute <= arg[8];
            end
            CMD_SET_FREQ: begin
                freq_hz <= arg;
            end
            default: begin
            end
        endcase
    end
end

endmodule
