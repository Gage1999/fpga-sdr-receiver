// LCD scan timing counters per arch doc §2.
//
// 800x480 active, 928x525 total. Produces the live (x, y) position and a
// DE (data enable) flag for the active region. Held at zero during reset
// so downstream consumers (pixel shader, scan-out reader) don't see a
// bogus position before the pipeline is ready.
//
// HSYNC/VSYNC outputs are deliberately omitted for now — the iCESugar-Pro
// LCD wiring is DE-only. Add when a panel that needs them lands.

module scan_timing #(
    parameter int unsigned H_ACTIVE = 800,
    parameter int unsigned H_TOTAL  = 928,
    parameter int unsigned V_ACTIVE = 480,
    parameter int unsigned V_TOTAL  = 525
) (
    input  logic        pclk,
    input  logic        rst,
    output logic [10:0] x,
    output logic [9:0]  y,
    output logic        de
);
    localparam logic [10:0] H_MAX = 11'(H_TOTAL - 1);
    localparam logic [9:0]  V_MAX = 10'(V_TOTAL  - 1);

    always_ff @(posedge pclk) begin
        if (rst) begin
            x <= 11'd0;
            y <= 10'd0;
        end else begin
            if (x < H_MAX) begin
                x <= x + 11'd1;
            end else begin
                x <= 11'd0;
                y <= (y < V_MAX) ? y + 10'd1 : 10'd0;
            end
        end
    end

    assign de = !rst && (x < 11'(H_ACTIVE)) && (y < 10'(V_ACTIVE));
endmodule
