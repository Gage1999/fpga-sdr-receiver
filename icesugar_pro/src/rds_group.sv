module rds_group (
    input  logic        clk,
    input  logic        rst,

    input  logic        group_valid,
    input  logic [15:0] pi_word,
    input  logic [15:0] blk_b,
    input  logic [15:0] blk_c,
    input  logic [15:0] blk_d,
    input  logic        c_is_cprime,
    input  logic [3:0]  block_ok,

    output logic [15:0] pi,
    output logic [4:0]  pty,
    output logic        tp,
    output logic [7:0]  ps_mask,
    output logic        ps_valid,
    output logic [63:0] ps_name,
    output logic [191:0] rds_line
);

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
            ps_name  <= {8{8'h20}};
        end else if (group_valid) begin
            if (block_ok[3]) pi <= pi_word;
            if (block_ok[2]) begin
                pty <= blk_b[9:5];
                tp  <= blk_b[10];
            end

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

    always_comb begin
        rds_line = {24{8'h20}};
        rds_line[63:0] = ps_name;
    end

endmodule
