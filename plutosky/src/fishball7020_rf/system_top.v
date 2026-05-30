// fishball7020_rf/system_top.v
//
// Top-level for fishball7020 (PlutoSky 7020, XC7Z020-2CLG400I).
// Based on maia-hdl/projects/pluto/system_top.v, adapted for:
//   - LVDS RF interface  (differential pairs, not single-ended CMOS)
//   - Z7020 DDR          (32-bit bus, [3:0] dm/dqs, [31:0] dq)
//   - 54-pin MIO         ([53:0] fixed_io_mio)
//   - 21-bit EMIO GPIO   (width fixed at 21 to preserve PS7 IOPLL init for USB HS)
//   - AXI SPI master on JP5 Bank 13 pins
//
// EMIO GPIO mapping (gpiochip0 lines = 54 + EMIO index):
//   EMIO[ 7: 0] = gpio_status[7:0]  AD9363 CTRL_OUT  -> lines 54-61
//   EMIO[11: 8] = gpio_ctl[3:0]     AD9363 CTRL_IN   -> lines 62-65
//   EMIO[12]    = gpio_en_agc        AD9363 EN_AGC    -> line  66
//   EMIO[13]    = gpio_resetb        AD9363 RESET_B   -> line  67
//   EMIO[14]    = (loopback)                          -> line  68
//   EMIO[15]    = up_enable -> axi_ad9361             -> line  69
//   EMIO[16]    = up_txnrx  -> axi_ad9361             -> line  70
//   EMIO[20:17] = (loopback, unused) JP5 now owned by AXI SPI -> lines 71-74 inert
//   JP5 pin 7  = jp5_spi_clk
//   JP5 pin 9  = jp5_spi_mosi
//   JP5 pin 11 = jp5_spi_miso
//   JP5 pin 13 = jp5_spi_csn
// ***************************************************************************

`timescale 1ns/100ps

module system_top (

  // DDR3, 32-bit bus
  inout   [14:0]  ddr_addr,
  inout   [ 2:0]  ddr_ba,
  inout           ddr_cas_n,
  inout           ddr_ck_n,
  inout           ddr_ck_p,
  inout           ddr_cke,
  inout           ddr_cs_n,
  inout   [ 3:0]  ddr_dm,
  inout   [31:0]  ddr_dq,
  inout   [ 3:0]  ddr_dqs_n,
  inout   [ 3:0]  ddr_dqs_p,
  inout           ddr_odt,
  inout           ddr_ras_n,
  inout           ddr_reset_n,
  inout           ddr_we_n,

  // PS7 fixed IO, 54-pin MIO
  inout           fixed_io_ddr_vrn,
  inout           fixed_io_ddr_vrp,
  inout   [53:0]  fixed_io_mio,
  inout           fixed_io_ps_clk,
  inout           fixed_io_ps_porb,
  inout           fixed_io_ps_srstb,

  // AD9363 LVDS data interface, Bank 34
  input           rx_clk_in_p,
  input           rx_clk_in_n,
  input           rx_frame_in_p,
  input           rx_frame_in_n,
  input   [ 5:0]  rx_data_in_p,
  input   [ 5:0]  rx_data_in_n,
  output          tx_clk_out_p,
  output          tx_clk_out_n,
  output          tx_frame_out_p,
  output          tx_frame_out_n,
  output  [ 5:0]  tx_data_out_p,
  output  [ 5:0]  tx_data_out_n,

  // AD9363 control, Bank 34
  output          enable,
  output          txnrx,

  // AD9363 GPIO, Banks 34/35, via ad_iobuf EMIO[13:0]
  inout           gpio_resetb,    // EMIO[13] -> RESET_B
  inout           gpio_en_agc,    // EMIO[12] -> EN_AGC
  inout   [ 3:0]  gpio_ctl,       // EMIO[11:8] -> CTRL_IN[3:0]
  inout   [ 7:0]  gpio_status,    // EMIO[7:0]  -> CTRL_OUT[7:0]

  // AD9363 SPI0, Bank 34
  output          spi_csn,
  output          spi_clk,
  output          spi_mosi,
  input           spi_miso,

  // JP5 AXI SPI master, Bank 13
  output          jp5_spi_clk,   // JP5 pin 7
  output          jp5_spi_mosi,  // JP5 pin 9
  input           jp5_spi_miso,  // JP5 pin 11
  output          jp5_spi_csn    // JP5 pin 13
);

  // 21-bit EMIO GPIO bus (width kept at 21 to preserve PS7 IOPLL init for USB HS)
  wire    [20:0]  gpio_i;
  wire    [20:0]  gpio_o;
  wire    [20:0]  gpio_t;

  // AD9363 control signals, EMIO[13:0] via ad_iobuf
  ad_iobuf #(.DATA_WIDTH(14)) i_iobuf (
    .dio_t (gpio_t[13:0]),
    .dio_i (gpio_o[13:0]),
    .dio_o (gpio_i[13:0]),
    .dio_p ({gpio_resetb,    // [13]
             gpio_en_agc,    // [12]
             gpio_ctl,       // [11:8]
             gpio_status})); // [7:0]

  // EMIO[14] unused; EMIO[15:16] = up_enable/up_txnrx; EMIO[20:17] unused (JP5 = AXI SPI)
  assign gpio_i[20:14] = gpio_o[20:14];

  system_wrapper i_system_wrapper (
    .ddr_addr           (ddr_addr),
    .ddr_ba             (ddr_ba),
    .ddr_cas_n          (ddr_cas_n),
    .ddr_ck_n           (ddr_ck_n),
    .ddr_ck_p           (ddr_ck_p),
    .ddr_cke            (ddr_cke),
    .ddr_cs_n           (ddr_cs_n),
    .ddr_dm             (ddr_dm),
    .ddr_dq             (ddr_dq),
    .ddr_dqs_n          (ddr_dqs_n),
    .ddr_dqs_p          (ddr_dqs_p),
    .ddr_odt            (ddr_odt),
    .ddr_ras_n          (ddr_ras_n),
    .ddr_reset_n        (ddr_reset_n),
    .ddr_we_n           (ddr_we_n),
    .enable             (enable),
    .fixed_io_ddr_vrn   (fixed_io_ddr_vrn),
    .fixed_io_ddr_vrp   (fixed_io_ddr_vrp),
    .fixed_io_mio       (fixed_io_mio),
    .fixed_io_ps_clk    (fixed_io_ps_clk),
    .fixed_io_ps_porb   (fixed_io_ps_porb),
    .fixed_io_ps_srstb  (fixed_io_ps_srstb),
    .gpio_i             (gpio_i),
    .gpio_o             (gpio_o),
    .gpio_t             (gpio_t),
    .rx_clk_in_n        (rx_clk_in_n),
    .rx_clk_in_p        (rx_clk_in_p),
    .rx_data_in_n       (rx_data_in_n),
    .rx_data_in_p       (rx_data_in_p),
    .rx_frame_in_n      (rx_frame_in_n),
    .rx_frame_in_p      (rx_frame_in_p),
    .spi0_clk_i         (1'b0),
    .spi0_clk_o         (spi_clk),
    .spi0_csn_0_o       (spi_csn),
    .spi0_csn_1_o       (),
    .spi0_csn_2_o       (),
    .spi0_csn_i         (1'b1),
    .spi0_sdi_i         (spi_miso),
    .spi0_sdo_i         (1'b0),
    .spi0_sdo_o         (spi_mosi),
    .jp5_spi_clk_i      (1'b0),
    .jp5_spi_clk_o      (jp5_spi_clk),
    .jp5_spi_csn_i      (1'b1),
    .jp5_spi_csn_o      (jp5_spi_csn),
    .jp5_spi_miso_i     (jp5_spi_miso),
    .jp5_spi_mosi_i     (1'b0),
    .jp5_spi_mosi_o     (jp5_spi_mosi),
    .tx_clk_out_n       (tx_clk_out_n),
    .tx_clk_out_p       (tx_clk_out_p),
    .tx_data_out_n      (tx_data_out_n),
    .tx_data_out_p      (tx_data_out_p),
    .tx_frame_out_n     (tx_frame_out_n),
    .tx_frame_out_p     (tx_frame_out_p),
    .txnrx              (txnrx),
    .up_enable          (gpio_o[15]),
    .up_txnrx           (gpio_o[16]));

endmodule
