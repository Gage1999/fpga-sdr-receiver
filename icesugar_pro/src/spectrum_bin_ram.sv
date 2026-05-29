// Spectrum bin RAM — 256 x 16, dual-port (arch doc §5).
//
// Backs pixel_shader's `spectrum_bin_addr`/`spectrum_bin_data` read port.
// Two independent ports:
//   - Write port (wr_clk domain): the Pico SPI path / ingest writer pushes the
//     256 magnitude bins for the next frame here.
//   - Read port (async): the pixel_shader reads one bin per pixel.
//
// The read is asynchronous so the shader's combinational per-pixel model (the
// C executable spec) holds bit-for-bit. On ECP5 that maps this to distributed
// LUT-RAM (a 256x16 pseudo-dual-port fits easily). When the shader is
// pipelined for pixel-clock timing at integration (#18, arch §9 "1-cycle
// ROM-lookup pipeline"), this read becomes a registered EBR port and the
// budget reclaims the LUT-RAM as 1 DP16KD block.
module spectrum_bin_ram #(
    parameter INIT_FILE = ""        // optional $readmemh preload (tests)
) (
    // Write port.
    input  logic        wr_clk,
    input  logic        wr_en,
    input  logic [7:0]  wr_addr,
    input  logic [15:0] wr_data,

    // Read port (combinational).
    input  logic [7:0]  rd_addr,
    output logic [15:0] rd_data
);
    logic [15:0] mem [0:255];

    // Optional deterministic preload for simulation; harmless (and ignored by
    // synthesis for an empty string) on hardware where wr_clk fills the RAM.
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always_comb rd_data = mem[rd_addr];
endmodule
