// rds_group — decode RDS groups into station metadata and assemble the
// Program Service (PS) name for display.
//
// Input is one group per `group_valid` pulse from rds_sync: the four 16-bit
// information words plus their per-block validity flags. Block B always carries
// the group type code [15:12], version bit [11], TP [10] and PTY [9:5].
//
// Group type 0 (0A and 0B) carries the 8-character PS name two characters at a
// time in block D, with the 2-bit segment address in block B [1:0]:
//     PS[2*addr]   = blockD[15:8]
//     PS[2*addr+1] = blockD[7:0]
// Four segments (addr 0..3) fill the 8-character name. Characters are only
// written when both the addressing block (B) and the data block (D) validated,
// so corrupted blocks never poison the displayed name.
//
// The 24-character `rds_line` mirrors the field ui_wire_rx produces from the
// Pico link: char 0 occupies bits [7:0] (left-most on screen). The PS name fills
// characters 0..7; the remaining columns are spaces.

module rds_group (
    input  logic        clk,
    input  logic        rst,

    input  logic        group_valid,
    input  logic [15:0] pi_word,
    input  logic [15:0] blk_b,
    input  logic [15:0] blk_c,
    input  logic [15:0] blk_d,
    input  logic        c_is_cprime,
    input  logic [3:0]  block_ok,     // {a,b,c,d}

    output logic [15:0] pi,           // Program Identification (latched when block A ok)
    output logic [4:0]  pty,          // Program Type (latched when block B ok)
    output logic        tp,           // Traffic Program flag
    output logic [7:0]  ps_mask,      // which of the 8 PS characters have been received
    output logic        ps_valid,     // all 8 PS characters present
    output logic [63:0] ps_name,      // 8 PS characters, char 0 in bits [7:0]
    output logic [191:0] rds_line     // 24-char display line, PS left-aligned
);

    // Map RDS bytes to a safe printable range; everything else becomes a space.
    function automatic logic [7:0] printable(input logic [7:0] b);
        printable = (b >= 8'h20 && b <= 8'h7E) ? b : 8'h20;
    endfunction

    logic [1:0] addr;
    assign addr = blk_b[1:0];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pi       <= '0;
            pty      <= '0;
            tp       <= 1'b0;
            ps_mask  <= 8'd0;
            ps_valid <= 1'b0;
            ps_name  <= {8{8'h20}};   // spaces
        end else if (group_valid) begin
            if (block_ok[3]) pi <= pi_word;
            if (block_ok[2]) begin
                pty <= blk_b[9:5];
                tp  <= blk_b[10];
            end

            // Group type 0 (code 0000), either version, carries the PS name.
            if (blk_b[15:12] == 4'b0000 && block_ok[2] && block_ok[0]) begin
                ps_name[8*(2*addr)   +: 8] <= printable(blk_d[15:8]);
                ps_name[8*(2*addr+1) +: 8] <= printable(blk_d[7:0]);
                ps_mask[2*addr]            <= 1'b1;
                ps_mask[2*addr+1]          <= 1'b1;
                if ((ps_mask | (8'b11 << (2*addr))) == 8'hFF)
                    ps_valid <= 1'b1;
            end
        end
    end

    // Display line: PS name in the first 8 columns, spaces in the rest.
    always_comb begin
        rds_line = {24{8'h20}};
        rds_line[63:0] = ps_name;
    end

endmodule
