# fishball7020_rf/system_constr.xdc
#
# Pin constraints for fishball7020 (PlutoSky 7020, XC7Z020-2CLG400I).
# Verified against fishball7020.pdf schematic.
#
# Bank 34  VCCO = 2.5V -> LVDS_25 / LVCMOS25
# Bank 35  VCCO = 1.8V -> LVCMOS18
# Bank 13  VCCO = 3.3V -> LVCMOS33

# =============================================================================
# AD9363 LVDS data interface, Bank 34 (LVDS_25, VCCO=2.5V)
# =============================================================================

set_property  -dict {PACKAGE_PIN  U18  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports rx_clk_in_p]         ; ## DATA_CLK_P
set_property  -dict {PACKAGE_PIN  U19  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports rx_clk_in_n]         ; ## DATA_CLK_N
set_property  -dict {PACKAGE_PIN  Y16  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports rx_frame_in_p]       ; ## RX_FRAME_P
set_property  -dict {PACKAGE_PIN  Y17  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports rx_frame_in_n]       ; ## RX_FRAME_N
set_property  -dict {PACKAGE_PIN  Y18  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[0]}]   ; ## RX_D0_P
set_property  -dict {PACKAGE_PIN  Y19  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[0]}]   ; ## RX_D0_N
set_property  -dict {PACKAGE_PIN  T16  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[1]}]   ; ## RX_D1_P
set_property  -dict {PACKAGE_PIN  U17  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[1]}]   ; ## RX_D1_N
set_property  -dict {PACKAGE_PIN  V20  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[2]}]   ; ## RX_D2_P
set_property  -dict {PACKAGE_PIN  W20  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[2]}]   ; ## RX_D2_N
set_property  -dict {PACKAGE_PIN  T17  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[3]}]   ; ## RX_D3_P
set_property  -dict {PACKAGE_PIN  R18  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[3]}]   ; ## RX_D3_N
set_property  -dict {PACKAGE_PIN  T20  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[4]}]   ; ## RX_D4_P
set_property  -dict {PACKAGE_PIN  U20  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[4]}]   ; ## RX_D4_N
set_property  -dict {PACKAGE_PIN  W18  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_p[5]}]   ; ## RX_D5_P
set_property  -dict {PACKAGE_PIN  W19  IOSTANDARD LVDS_25   DIFF_TERM TRUE} [get_ports {rx_data_in_n[5]}]   ; ## RX_D5_N

set_property  -dict {PACKAGE_PIN  U14  IOSTANDARD LVDS_25}                  [get_ports tx_clk_out_p]        ; ## FB_CLK_P
set_property  -dict {PACKAGE_PIN  U15  IOSTANDARD LVDS_25}                  [get_ports tx_clk_out_n]        ; ## FB_CLK_N
set_property  -dict {PACKAGE_PIN  V16  IOSTANDARD LVDS_25}                  [get_ports tx_frame_out_p]      ; ## TX_FRAME_P
set_property  -dict {PACKAGE_PIN  W16  IOSTANDARD LVDS_25}                  [get_ports tx_frame_out_n]      ; ## TX_FRAME_N
set_property  -dict {PACKAGE_PIN  V15  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[0]}]  ; ## TX_D0_P
set_property  -dict {PACKAGE_PIN  W15  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[0]}]  ; ## TX_D0_N
set_property  -dict {PACKAGE_PIN  V12  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[1]}]  ; ## TX_D1_P
set_property  -dict {PACKAGE_PIN  W13  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[1]}]  ; ## TX_D1_N
set_property  -dict {PACKAGE_PIN  W14  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[2]}]  ; ## TX_D2_P
set_property  -dict {PACKAGE_PIN  Y14  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[2]}]  ; ## TX_D2_N
set_property  -dict {PACKAGE_PIN  T12  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[3]}]  ; ## TX_D3_P
set_property  -dict {PACKAGE_PIN  U12  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[3]}]  ; ## TX_D3_N
set_property  -dict {PACKAGE_PIN  T11  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[4]}]  ; ## TX_D4_P
set_property  -dict {PACKAGE_PIN  T10  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[4]}]  ; ## TX_D4_N
set_property  -dict {PACKAGE_PIN  U13  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_p[5]}]  ; ## TX_D5_P
set_property  -dict {PACKAGE_PIN  V13  IOSTANDARD LVDS_25}                  [get_ports {tx_data_out_n[5]}]  ; ## TX_D5_N

create_clock -name rx_clk -period 8 [get_ports rx_clk_in_p]

# =============================================================================
# AD9363 single-ended control, Bank 34 (LVCMOS25, VCCO=2.5V)
# =============================================================================

set_property  -dict {PACKAGE_PIN  T15  IOSTANDARD LVCMOS25} [get_ports enable]
set_property  -dict {PACKAGE_PIN  P18  IOSTANDARD LVCMOS25} [get_ports txnrx]
set_property  -dict {PACKAGE_PIN  R19  IOSTANDARD LVCMOS25} [get_ports gpio_resetb]  ; ## RF_RESET   EMIO[13]
set_property  -dict {PACKAGE_PIN  P20  IOSTANDARD LVCMOS25} [get_ports gpio_en_agc]  ; ## EN_AGC     EMIO[12]

set_property  -dict {PACKAGE_PIN  R17  IOSTANDARD LVCMOS25  PULLTYPE PULLUP} [get_ports spi_csn]  ; ## SPI_CS
set_property  -dict {PACKAGE_PIN  V18  IOSTANDARD LVCMOS25} [get_ports spi_clk]   ; ## SPI_CLK
set_property  -dict {PACKAGE_PIN  P16  IOSTANDARD LVCMOS25} [get_ports spi_mosi]  ; ## SPI_MOSI
set_property  -dict {PACKAGE_PIN  V17  IOSTANDARD LVCMOS25} [get_ports spi_miso]  ; ## SPI_MISO

# =============================================================================
# AD9363 CTRL_OUT[7:0] -> gpio_status[7:0]   EMIO[7:0]  gpiochip0 54-61
# Bank 34 (LVCMOS25): T14, P15, N20
# Bank 35 (LVCMOS18): L20, L19, K19, M20, M19
# =============================================================================

set_property  -dict {PACKAGE_PIN  L20  IOSTANDARD LVCMOS18} [get_ports {gpio_status[0]}]  ; ## CTRL_OUT0  Bank 35  EMIO[0]
set_property  -dict {PACKAGE_PIN  L19  IOSTANDARD LVCMOS18} [get_ports {gpio_status[1]}]  ; ## CTRL_OUT1  Bank 35  EMIO[1]
set_property  -dict {PACKAGE_PIN  K19  IOSTANDARD LVCMOS18} [get_ports {gpio_status[2]}]  ; ## CTRL_OUT2  Bank 35  EMIO[2]
set_property  -dict {PACKAGE_PIN  T14  IOSTANDARD LVCMOS25} [get_ports {gpio_status[3]}]  ; ## CTRL_OUT3  Bank 34  EMIO[3]
set_property  -dict {PACKAGE_PIN  P15  IOSTANDARD LVCMOS25} [get_ports {gpio_status[4]}]  ; ## CTRL_OUT4  Bank 34  EMIO[4]
set_property  -dict {PACKAGE_PIN  M20  IOSTANDARD LVCMOS18} [get_ports {gpio_status[5]}]  ; ## CTRL_OUT5  Bank 35  EMIO[5]
set_property  -dict {PACKAGE_PIN  M19  IOSTANDARD LVCMOS18} [get_ports {gpio_status[6]}]  ; ## CTRL_OUT6  Bank 35  EMIO[6]
set_property  -dict {PACKAGE_PIN  N20  IOSTANDARD LVCMOS25} [get_ports {gpio_status[7]}]  ; ## CTRL_OUT7  Bank 34  EMIO[7]

# =============================================================================
# AD9363 CTRL_IN[3:0] -> gpio_ctl[3:0]   EMIO[11:8]  gpiochip0 62-65
# Bank 34 (LVCMOS25): R14
# Bank 35 (LVCMOS18): J19, K14, J20
# =============================================================================

set_property  -dict {PACKAGE_PIN  J19  IOSTANDARD LVCMOS18} [get_ports {gpio_ctl[0]}]  ; ## CTRL_IN0  Bank 35  EMIO[8]
set_property  -dict {PACKAGE_PIN  K14  IOSTANDARD LVCMOS18} [get_ports {gpio_ctl[1]}]  ; ## CTRL_IN1  Bank 35  EMIO[9]
set_property  -dict {PACKAGE_PIN  R14  IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[2]}]  ; ## CTRL_IN2  Bank 34  EMIO[10]
set_property  -dict {PACKAGE_PIN  J20  IOSTANDARD LVCMOS18} [get_ports {gpio_ctl[3]}]  ; ## CTRL_IN3  Bank 35  EMIO[11]

# =============================================================================
# JP5 AXI SPI master, Bank 13 (LVCMOS33, VCCO=3.3V)
# =============================================================================

set_property  -dict {PACKAGE_PIN  V10  IOSTANDARD LVCMOS33  DRIVE 4  SLEW SLOW} [get_ports jp5_spi_clk]   ; ## JP5 pin 7
set_property  -dict {PACKAGE_PIN  U9   IOSTANDARD LVCMOS33  DRIVE 4  SLEW SLOW} [get_ports jp5_spi_mosi]  ; ## JP5 pin 9
set_property  -dict {PACKAGE_PIN  U10  IOSTANDARD LVCMOS33  PULLTYPE PULLDOWN} [get_ports jp5_spi_miso]  ; ## JP5 pin 11
set_property  -dict {PACKAGE_PIN  T9   IOSTANDARD LVCMOS33  DRIVE 4  SLEW SLOW} [get_ports jp5_spi_csn]   ; ## JP5 pin 13

# =============================================================================
# Timing false paths (from maia pluto constraints)
# =============================================================================

set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_rx/i_up_adc_common/up_adc_gpio_out_int_reg[0]/C}]
set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_tx/i_up_dac_common/up_dac_gpio_out_int_reg[0]/C}]
