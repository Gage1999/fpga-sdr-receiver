# fishball7020_rf/system_bd.tcl
#
# Maia SDR IIO block design for fishball7020 (PlutoSky 7020, XC7Z020-2CLG400I).
#
# Based on maia-hdl/projects/pluto_iio but adapted for:
#   - LVDS RF interface  (fishball7020 AD9363 runs in LVDS mode)
#   - XC7Z020 / CLG400  (32-bit DDR, 54-pin MIO, USB reset on MIO 46)
#   - fishball7020 PS7 PCW parameters (DDR delays from tezuka HWH)
#   - 21-bit EMIO GPIO  (bits 0-16 = AD9363 control + up_enable/up_txnrx; bits 17-20 = loopback/unused)
#                        width fixed at 21 to preserve IOPLL init for USB HS clock
#   - AXI Quad SPI on JP5 Bank 13 pins (Bank 13 pins no longer EMIO)
#
# AXI address map (matches tezuka device tree and maia_sdr.ko):
#   0x79020000  axi_ad9361
#   0x7C400000  axi_ad9361_adc_dma
#   0x7C420000  axi_ad9361_dac_dma
#   0x7C440000  axi_spi_jp5
#   0x7C460000  maia_sdr

# ---------------------------------------------------------------------------
# IP repository - must be set here; adi_project_create overwrites prior settings
# Paths are relative to the Vivado project directory (fishball7020_rf/fishball7020_rf/)
# ---------------------------------------------------------------------------

set_property ip_repo_paths [list \
    [file normalize [file join [file dirname [info script]] "../maia-sdr/maia-hdl/ip"]] \
    $ad_hdl_dir/library] [current_fileset]
update_ip_catalog

# ---------------------------------------------------------------------------
# Top-level ports
# ---------------------------------------------------------------------------

# PS7 DDR and FIXED_IO interfaces
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 ddr
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 fixed_io

# SPI0 (AD9363)
create_bd_port -dir O spi0_csn_2_o
create_bd_port -dir O spi0_csn_1_o
create_bd_port -dir O spi0_csn_0_o
create_bd_port -dir I spi0_csn_i
create_bd_port -dir I spi0_clk_i
create_bd_port -dir O spi0_clk_o
create_bd_port -dir I spi0_sdo_i
create_bd_port -dir O spi0_sdo_o
create_bd_port -dir I spi0_sdi_i

# EMIO GPIO, 21 bits (must match original PS7 init to preserve IOPLL/USB clock)
#   [13: 0] AD9363 control (gpio_status[7:0], gpio_ctl[3:0], gpio_en_agc, gpio_resetb)
#   [14]    unused (loopback)
#   [15]    up_enable
#   [16]    up_txnrx
#   [20:17] unused (loopback) - JP5 pins are now AXI SPI, not EMIO
create_bd_port -dir I -from 20 -to 0 gpio_i
create_bd_port -dir O -from 20 -to 0 gpio_o
create_bd_port -dir O -from 20 -to 0 gpio_t

# JP5 AXI SPI master
create_bd_port -dir O jp5_spi_csn_o
create_bd_port -dir I jp5_spi_csn_i
create_bd_port -dir I jp5_spi_clk_i
create_bd_port -dir O jp5_spi_clk_o
create_bd_port -dir I jp5_spi_mosi_i
create_bd_port -dir O jp5_spi_mosi_o
create_bd_port -dir I jp5_spi_miso_i

# AD9363 LVDS data interface
create_bd_port -dir I rx_clk_in_p
create_bd_port -dir I rx_clk_in_n
create_bd_port -dir I rx_frame_in_p
create_bd_port -dir I rx_frame_in_n
create_bd_port -dir I -from 5 -to 0 rx_data_in_p
create_bd_port -dir I -from 5 -to 0 rx_data_in_n
create_bd_port -dir O tx_clk_out_p
create_bd_port -dir O tx_clk_out_n
create_bd_port -dir O tx_frame_out_p
create_bd_port -dir O tx_frame_out_n
create_bd_port -dir O -from 5 -to 0 tx_data_out_p
create_bd_port -dir O -from 5 -to 0 tx_data_out_n

# AD9363 control
create_bd_port -dir O enable
create_bd_port -dir O txnrx
create_bd_port -dir I up_enable
create_bd_port -dir I up_txnrx

# ---------------------------------------------------------------------------
# PS7
# ---------------------------------------------------------------------------

ad_ip_instance processing_system7 sys_ps7

# Package and bank voltages - fishball7020 CLG400
ad_ip_parameter sys_ps7 CONFIG.PCW_PACKAGE_NAME              clg400
ad_ip_parameter sys_ps7 CONFIG.PCW_PRESET_BANK0_VOLTAGE      {LVCMOS 3.3V}
ad_ip_parameter sys_ps7 CONFIG.PCW_PRESET_BANK1_VOLTAGE      {LVCMOS 1.8V}

# HP AXI slave ports for DMA
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP1 1
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP2 1

# Clocks: FCLK0 = 100 MHz (sys_cpu), FCLK1 = 200 MHz (delay_clk)
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_CLK1_PORT 1
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_RST1_PORT 1
ad_ip_parameter sys_ps7 CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ 100.0
ad_ip_parameter sys_ps7 CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ 200.0

# EMIO GPIO, 21 bits - must stay at 21 to preserve IOPLL init sequence for USB HS
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_EMIO_GPIO_IO     21
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_MIO_GPIO_ENABLE  1
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_MIO_GPIO_IO      MIO

# Peripherals
ad_ip_parameter sys_ps7 CONFIG.PCW_UART1_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_UART1_UART1_IO          {MIO 8 .. 9}
ad_ip_parameter sys_ps7 CONFIG.PCW_QSPI_PERIPHERAL_ENABLE  1
ad_ip_parameter sys_ps7 CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI0_PERIPHERAL_ENABLE  1
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI0_SPI0_IO            EMIO
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI1_PERIPHERAL_ENABLE  0
ad_ip_parameter sys_ps7 CONFIG.PCW_I2C0_PERIPHERAL_ENABLE  0
ad_ip_parameter sys_ps7 CONFIG.PCW_I2C1_PERIPHERAL_ENABLE  0
ad_ip_parameter sys_ps7 CONFIG.PCW_SD0_PERIPHERAL_ENABLE   0
ad_ip_parameter sys_ps7 CONFIG.PCW_SD0_GRP_CD_ENABLE       0
ad_ip_parameter sys_ps7 CONFIG.PCW_TTC0_PERIPHERAL_ENABLE  0
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_PERIPHERAL_ENABLE  1

# USB reset on MIO 46; IO must be set before ENABLE
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_RESET_IO     {MIO 46}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_46_SLEW       slow
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_46_PULLUP     enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_RESET_ENABLE 1

# Ethernet: ENET0 has no reset pin; ENET1 not populated
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET_RESET_SELECT    {No reset}
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_RESET_ENABLE   0
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET1_PERIPHERAL_ENABLE 0
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET1_RESET_ENABLE   0

# FCLK2/RST2 not needed
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_CLK2_PORT 0
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_RST2_PORT 0

# Interrupts
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_FABRIC_INTERRUPT 1
ad_ip_parameter sys_ps7 CONFIG.PCW_IRQ_F2P_INTR         1
ad_ip_parameter sys_ps7 CONFIG.PCW_IRQ_F2P_MODE         REVERSE

# MIO pullups (match pluto base design)
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_0_PULLUP  enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_9_PULLUP  enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_10_PULLUP enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_11_PULLUP enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_48_PULLUP enabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_49_PULLUP disabled
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_53_PULLUP enabled

# DDR3: fishball7020 PCB trace delays extracted from tezuka system.hwh
# 32-bit bus (Z7020 has two 16-bit byte lanes populated on fishball7020)
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ              533.333333
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0   0.048
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1   0.050
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2   0.0
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3   0.0
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0          0.241
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1          0.240
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2          0.25
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3          0.25
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL     1
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE       1
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE        1
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF     0

# ---------------------------------------------------------------------------
# System reset and clock infrastructure
# ---------------------------------------------------------------------------

ad_ip_instance xlconcat sys_concat_intc
ad_ip_parameter sys_concat_intc CONFIG.NUM_PORTS 16

ad_ip_instance proc_sys_reset sys_rstgen
ad_ip_parameter sys_rstgen CONFIG.C_EXT_RST_WIDTH 1

ad_ip_instance axi_quad_spi axi_spi_jp5
ad_ip_parameter axi_spi_jp5 CONFIG.C_USE_STARTUP 0
ad_ip_parameter axi_spi_jp5 CONFIG.C_NUM_SS_BITS 1
ad_ip_parameter axi_spi_jp5 CONFIG.C_SCK_RATIO 8

ad_connect sys_cpu_clk  sys_ps7/FCLK_CLK0
ad_connect sys_200m_clk sys_ps7/FCLK_CLK1
ad_connect sys_cpu_reset   sys_rstgen/peripheral_reset
ad_connect sys_cpu_resetn  sys_rstgen/peripheral_aresetn
ad_connect sys_cpu_clk     sys_rstgen/slowest_sync_clk
ad_connect sys_rstgen/ext_reset_in sys_ps7/FCLK_RESET0_N

# PS7 interface connections
ad_connect ddr      sys_ps7/DDR
ad_connect gpio_i   sys_ps7/GPIO_I
ad_connect gpio_o   sys_ps7/GPIO_O
ad_connect gpio_t   sys_ps7/GPIO_T
ad_connect fixed_io sys_ps7/FIXED_IO

# SPI0
ad_connect spi0_csn_2_o sys_ps7/SPI0_SS2_O
ad_connect spi0_csn_1_o sys_ps7/SPI0_SS1_O
ad_connect spi0_csn_0_o sys_ps7/SPI0_SS_O
ad_connect spi0_csn_i   sys_ps7/SPI0_SS_I
ad_connect spi0_clk_i   sys_ps7/SPI0_SCLK_I
ad_connect spi0_clk_o   sys_ps7/SPI0_SCLK_O
ad_connect spi0_sdo_i   sys_ps7/SPI0_MOSI_I
ad_connect spi0_sdo_o   sys_ps7/SPI0_MOSI_O
ad_connect spi0_sdi_i   sys_ps7/SPI0_MISO_I

# JP5 AXI SPI
ad_connect sys_cpu_clk      axi_spi_jp5/ext_spi_clk
ad_connect jp5_spi_csn_i    axi_spi_jp5/ss_i
ad_connect jp5_spi_csn_o    axi_spi_jp5/ss_o
ad_connect jp5_spi_clk_i    axi_spi_jp5/sck_i
ad_connect jp5_spi_clk_o    axi_spi_jp5/sck_o
ad_connect jp5_spi_mosi_i   axi_spi_jp5/io0_i
ad_connect jp5_spi_mosi_o   axi_spi_jp5/io0_o
ad_connect jp5_spi_miso_i   axi_spi_jp5/io1_i

# Interrupt concatenator (unused slots tied to GND)
ad_connect sys_concat_intc/dout sys_ps7/IRQ_F2P
ad_connect sys_concat_intc/In15 GND
ad_connect sys_concat_intc/In14 GND
ad_connect sys_concat_intc/In13 GND
ad_connect sys_concat_intc/In12 GND
ad_connect sys_concat_intc/In11 GND
ad_connect sys_concat_intc/In10 GND
ad_connect sys_concat_intc/In9  GND
ad_connect sys_concat_intc/In8  GND
ad_connect sys_concat_intc/In7  GND
ad_connect sys_concat_intc/In6  GND
ad_connect sys_concat_intc/In5  GND
ad_connect sys_concat_intc/In4  GND
ad_connect sys_concat_intc/In3  GND
ad_connect sys_concat_intc/In2  GND
ad_connect sys_concat_intc/In1  GND
ad_connect sys_concat_intc/In0  GND

# ---------------------------------------------------------------------------
# axi_ad9361
# ---------------------------------------------------------------------------

ad_ip_instance axi_ad9361 axi_ad9361
ad_ip_parameter axi_ad9361 CONFIG.ID              0
ad_ip_parameter axi_ad9361 CONFIG.CMOS_OR_LVDS_N  0    ;# LVDS
ad_ip_parameter axi_ad9361 CONFIG.MODE_1R1T        0    ;# 2R2T framing
ad_ip_parameter axi_ad9361 CONFIG.ADC_INIT_DELAY   30
ad_ip_parameter axi_ad9361 CONFIG.TDD_DISABLE       1
ad_ip_parameter axi_ad9361 CONFIG.DAC_DDS_DISABLE   0   ;# DDS enabled

# LVDS AD9363 interface
ad_connect rx_clk_in_p    axi_ad9361/rx_clk_in_p
ad_connect rx_clk_in_n    axi_ad9361/rx_clk_in_n
ad_connect rx_frame_in_p  axi_ad9361/rx_frame_in_p
ad_connect rx_frame_in_n  axi_ad9361/rx_frame_in_n
ad_connect rx_data_in_p   axi_ad9361/rx_data_in_p
ad_connect rx_data_in_n   axi_ad9361/rx_data_in_n
ad_connect tx_clk_out_p   axi_ad9361/tx_clk_out_p
ad_connect tx_clk_out_n   axi_ad9361/tx_clk_out_n
ad_connect tx_frame_out_p axi_ad9361/tx_frame_out_p
ad_connect tx_frame_out_n axi_ad9361/tx_frame_out_n
ad_connect tx_data_out_p  axi_ad9361/tx_data_out_p
ad_connect tx_data_out_n  axi_ad9361/tx_data_out_n

ad_connect enable    axi_ad9361/enable
ad_connect txnrx     axi_ad9361/txnrx
ad_connect up_enable axi_ad9361/up_enable
ad_connect up_txnrx  axi_ad9361/up_txnrx

ad_connect axi_ad9361/tdd_sync GND
ad_connect sys_200m_clk        axi_ad9361/delay_clk
ad_connect axi_ad9361/l_clk    axi_ad9361/clk

# ---------------------------------------------------------------------------
# ADC data slices (12 MSBs of the 16-bit adc_data -> maia 12-bit input)
# ---------------------------------------------------------------------------

ad_ip_instance xlslice adc_i_slice
ad_ip_parameter adc_i_slice CONFIG.DIN_WIDTH  16
ad_ip_parameter adc_i_slice CONFIG.DOUT_WIDTH 12
ad_ip_parameter adc_i_slice CONFIG.DIN_FROM   11

ad_ip_instance xlslice adc_q_slice
ad_ip_parameter adc_q_slice CONFIG.DIN_TO     0
ad_ip_parameter adc_q_slice CONFIG.DIN_WIDTH  16
ad_ip_parameter adc_q_slice CONFIG.DOUT_WIDTH 12
ad_ip_parameter adc_q_slice CONFIG.DIN_FROM   11

# ---------------------------------------------------------------------------
# Maia SDR IP (maia_iio variant) + MMCM clocking
# ---------------------------------------------------------------------------

ad_ip_instance maia_sdr_maia_iio maia_sdr

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 maia_sdr_clk
set_property -dict [list \
    CONFIG.USE_PHASE_ALIGNMENT      {false}         \
    CONFIG.ENABLE_CLOCK_MONITOR     {false}         \
    CONFIG.PRIM_SOURCE              {Global_buffer} \
    CONFIG.CLKOUT2_USED             {true}          \
    CONFIG.CLKOUT3_USED             {true}          \
    CONFIG.NUM_OUT_CLKS             {3}             \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {62.500}      \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125.000}     \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {187.5}       \
    CONFIG.PRIMITIVE                {MMCM}          \
    CONFIG.MMCM_DIVCLK_DIVIDE       {1}             \
    CONFIG.MMCM_CLKFBOUT_MULT_F     {11.250}        \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F    {18.000}        \
    CONFIG.MMCM_CLKOUT1_DIVIDE      {9}             \
    CONFIG.MMCM_CLKOUT3_DIVIDE      {6}             \
    CONFIG.CLKOUT1_JITTER           {133.663}       \
    CONFIG.CLKOUT1_PHASE_ERROR      {91.100}        \
    CONFIG.CLKOUT2_JITTER           {116.571}       \
    CONFIG.CLKOUT2_PHASE_ERROR      {91.100}        \
    CONFIG.CLKOUT3_JITTER           {108.217}       \
    CONFIG.CLKOUT3_PHASE_ERROR      {91.100}] [get_bd_cells maia_sdr_clk]

# Data path: adc slices -> maia
ad_connect axi_ad9361/adc_data_i0 adc_i_slice/Din
ad_connect axi_ad9361/adc_data_q0 adc_q_slice/Din
ad_connect adc_i_slice/Dout        maia_sdr/re_in
ad_connect adc_q_slice/Dout        maia_sdr/im_in
ad_connect axi_ad9361/l_clk        maia_sdr/sampling_clk
ad_connect sys_cpu_clk             maia_sdr/s_axi_lite_clk
ad_connect sys_cpu_reset           maia_sdr/s_axi_lite_rst
ad_connect maia_sdr_clk/clk_out1   maia_sdr/clk
ad_connect maia_sdr_clk/clk_out2   maia_sdr/clk2x_clk
ad_connect maia_sdr_clk/clk_out3   maia_sdr/clk3x_clk
ad_connect sys_cpu_clk             maia_sdr_clk/clk_in1
ad_connect sys_cpu_reset           maia_sdr_clk/reset

# ---------------------------------------------------------------------------
# ADC/DAC DMAs, cpack/upack, CS8 IQ mux
# ---------------------------------------------------------------------------

ad_ip_instance axi_dmac axi_ad9361_dac_dma
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_SRC        0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_DEST       1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.CYCLIC               1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_SRC        0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_DEST       0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_2D_TRANSFER      0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_DATA_WIDTH_DEST  64

ad_ip_instance util_upack2 tx_upack

ad_ip_instance axi_dmac axi_ad9361_adc_dma
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_SRC         2
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_DEST        0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.CYCLIC                0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.SYNC_TRANSFER_START   0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_SRC         0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_DEST        0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_2D_TRANSFER       0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_DATA_WIDTH_SRC    64

ad_ip_instance util_cpack2 cpack
ad_ip_parameter cpack CONFIG.NUM_OF_CHANNELS 4   ;# I0 Q0 I1 Q1

ad_connect axi_ad9361/adc_enable_i0 cpack/enable_0
ad_connect axi_ad9361/adc_data_q0   cpack/fifo_wr_data_1
ad_connect axi_ad9361/l_clk         cpack/clk
ad_connect axi_ad9361/rst            cpack/reset
ad_connect axi_ad9361_adc_dma/fifo_wr cpack/packed_fifo_wr

ad_connect axi_ad9361/l_clk         tx_upack/clk
ad_connect axi_ad9361/rst            tx_upack/reset
ad_connect tx_upack/s_axis           axi_ad9361_dac_dma/m_axis

ad_ip_instance util_vector_logic logic_or [list C_OPERATION {or} C_SIZE 1]
ad_connect logic_or/Op1  axi_ad9361/dac_valid_i0
ad_connect logic_or/Op2  axi_ad9361/dac_valid_i1
ad_connect logic_or/Res  tx_upack/fifo_rd_en
ad_connect tx_upack/fifo_rd_underflow axi_ad9361/dac_dunf

ad_connect axi_ad9361/l_clk          axi_ad9361_adc_dma/fifo_wr_clk
ad_connect axi_ad9361/l_clk          axi_ad9361_dac_dma/m_axis_aclk
ad_connect cpack/fifo_wr_overflow     axi_ad9361/adc_dovf

ad_connect sys_cpu_resetn axi_ad9361_adc_dma/m_dest_axi_aresetn
ad_connect sys_cpu_resetn axi_ad9361_dac_dma/m_src_axi_aresetn

# 8-bit / 16-bit RX mux (CS8 / CS16 selection)

ad_ip_instance xlslice shiftslicei
ad_ip_parameter shiftslicei CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftslicei CONFIG.DIN_FROM    7
ad_ip_parameter shiftslicei CONFIG.DIN_TO      0
ad_ip_parameter shiftslicei CONFIG.DOUT_WIDTH  8
ad_connect shiftslicei/Din axi_ad9361/adc_data_i0

ad_ip_instance xlslice shiftsliceq
ad_ip_parameter shiftsliceq CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceq CONFIG.DIN_FROM    7
ad_ip_parameter shiftsliceq CONFIG.DIN_TO      0
ad_ip_parameter shiftsliceq CONFIG.DOUT_WIDTH  8
ad_connect shiftsliceq/Din axi_ad9361/adc_data_q0

ad_ip_instance xlconcat concatslice_iq
ad_connect concatslice_iq/In0 shiftslicei/Dout
ad_connect concatslice_iq/In1 shiftsliceq/Dout

ad_ip_instance util_vector_logic logic_no_q0 [list C_OPERATION {not} C_SIZE 1]
ad_connect axi_ad9361/adc_enable_q0 logic_no_q0/Op1

add_files -norecurse $ad_hdl_dir/library/common/ad_bus_mux.v
create_bd_cell -type module -reference ad_bus_mux muxcs8
ad_connect muxcs8/select_path  logic_no_q0/Res
ad_connect axi_ad9361/adc_data_i0  muxcs8/data_in_0
ad_connect axi_ad9361/adc_valid_i0 muxcs8/valid_in_0
ad_connect axi_ad9361/adc_enable_q0 muxcs8/enable_in_0
ad_connect concatslice_iq/Dout muxcs8/data_in_1
ad_connect axi_ad9361/adc_valid_i0 muxcs8/valid_in_1
ad_connect GND muxcs8/enable_in_1
ad_connect muxcs8/valid_out  cpack/fifo_wr_en
ad_connect muxcs8/data_out   cpack/fifo_wr_data_0
ad_connect muxcs8/enable_out cpack/enable_1

# 8-bit / 16-bit TX mux

ad_ip_instance xlslice shiftsliceitx
ad_ip_parameter shiftsliceitx CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceitx CONFIG.DIN_FROM   15
ad_ip_parameter shiftsliceitx CONFIG.DIN_TO      8
ad_ip_parameter shiftsliceitx CONFIG.DOUT_WIDTH  8
ad_connect tx_upack/fifo_rd_data_0 shiftsliceitx/Din

ad_ip_instance xlconcat concatslicetx_i
ad_ip_parameter concatslicetx_i CONFIG.NUM_PORTS 3
ad_ip_parameter concatslicetx_i CONFIG.IN0_WIDTH 4
ad_ip_parameter concatslicetx_i CONFIG.IN1_WIDTH 8
ad_ip_parameter concatslicetx_i CONFIG.IN2_WIDTH 4
ad_connect shiftsliceitx/Dout concatslicetx_i/In1

ad_ip_instance xlslice shiftsliceqtx
ad_ip_parameter shiftsliceqtx CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceqtx CONFIG.DIN_FROM    7
ad_ip_parameter shiftsliceqtx CONFIG.DIN_TO      0
ad_ip_parameter shiftsliceqtx CONFIG.DOUT_WIDTH  8
ad_connect tx_upack/fifo_rd_data_0 shiftsliceqtx/Din

ad_ip_instance xlconcat concatslicetx_q
ad_ip_parameter concatslicetx_q CONFIG.NUM_PORTS 3
ad_ip_parameter concatslicetx_q CONFIG.IN0_WIDTH 4
ad_ip_parameter concatslicetx_q CONFIG.IN1_WIDTH 8
ad_ip_parameter concatslicetx_q CONFIG.IN2_WIDTH 4
ad_connect shiftsliceqtx/Dout concatslicetx_q/In1

ad_ip_instance util_vector_logic logic_no_q0_tx [list C_OPERATION {not} C_SIZE 1]
ad_connect axi_ad9361/dac_enable_q0 logic_no_q0_tx/Op1

create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_i
ad_connect muxcs8_tx_i/select_path    logic_no_q0_tx/Res
ad_connect muxcs8_tx_i/enable_in_0   axi_ad9361/dac_enable_i0
ad_connect tx_upack/fifo_rd_data_0   muxcs8_tx_i/data_in_0
ad_connect concatslicetx_i/Dout      muxcs8_tx_i/data_in_1
ad_connect muxcs8_tx_i/enable_in_1   axi_ad9361/dac_enable_i0
ad_connect muxcs8_tx_i/data_out      axi_ad9361/dac_data_i0
ad_connect muxcs8_tx_i/enable_out    tx_upack/enable_0

create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_q
ad_connect muxcs8_tx_q/select_path    logic_no_q0_tx/Res
ad_connect muxcs8_tx_q/enable_in_0   axi_ad9361/dac_enable_q0
ad_connect tx_upack/fifo_rd_data_1   muxcs8_tx_q/data_in_0
ad_connect concatslicetx_q/Dout      muxcs8_tx_q/data_in_1
ad_connect muxcs8_tx_q/enable_in_1   axi_ad9361/dac_enable_i0
ad_connect muxcs8_tx_q/data_out      axi_ad9361/dac_data_q0
ad_connect muxcs8_tx_q/enable_out    tx_upack/enable_1

# 2nd channel (RX2/TX2)

ad_ip_instance xlslice shiftslicei2
ad_ip_parameter shiftslicei2 CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftslicei2 CONFIG.DIN_FROM    7
ad_ip_parameter shiftslicei2 CONFIG.DIN_TO      0
ad_ip_parameter shiftslicei2 CONFIG.DOUT_WIDTH  8
ad_connect shiftslicei2/Din axi_ad9361/adc_data_i1

ad_ip_instance xlslice shiftsliceq2
ad_ip_parameter shiftsliceq2 CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceq2 CONFIG.DIN_FROM    7
ad_ip_parameter shiftsliceq2 CONFIG.DIN_TO      0
ad_ip_parameter shiftsliceq2 CONFIG.DOUT_WIDTH  8
ad_connect shiftsliceq2/Din axi_ad9361/adc_data_q1

ad_ip_instance xlconcat concatslice_iq2
ad_connect concatslice_iq2/In0 shiftslicei2/Dout
ad_connect concatslice_iq2/In1 shiftsliceq2/Dout

ad_ip_instance util_vector_logic logic_no_q02 [list C_OPERATION {not} C_SIZE 1]
ad_connect axi_ad9361/adc_enable_q0 logic_no_q02/Op1

create_bd_cell -type module -reference ad_bus_mux muxcs82
ad_connect muxcs82/select_path        logic_no_q02/Res
ad_connect axi_ad9361/adc_data_i1    muxcs82/data_in_0
ad_connect axi_ad9361/adc_valid_i1   muxcs82/valid_in_0
ad_connect axi_ad9361/adc_enable_q1  muxcs82/enable_in_0
ad_connect concatslice_iq2/Dout      muxcs82/data_in_1
ad_connect axi_ad9361/adc_valid_i1   muxcs82/valid_in_1
ad_connect GND                        muxcs82/enable_in_1
ad_connect muxcs82/data_out          cpack/fifo_wr_data_2
ad_connect muxcs82/enable_out        cpack/enable_3

ad_ip_instance xlslice shiftsliceitx2
ad_ip_parameter shiftsliceitx2 CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceitx2 CONFIG.DIN_FROM   15
ad_ip_parameter shiftsliceitx2 CONFIG.DIN_TO      8
ad_ip_parameter shiftsliceitx2 CONFIG.DOUT_WIDTH  8
ad_connect tx_upack/fifo_rd_data_2 shiftsliceitx2/Din

ad_ip_instance xlconcat concatslicetx_i2
ad_ip_parameter concatslicetx_i2 CONFIG.NUM_PORTS 3
ad_ip_parameter concatslicetx_i2 CONFIG.IN0_WIDTH 4
ad_ip_parameter concatslicetx_i2 CONFIG.IN1_WIDTH 8
ad_ip_parameter concatslicetx_i2 CONFIG.IN2_WIDTH 4
ad_connect shiftsliceitx2/Dout concatslicetx_i2/In1

ad_ip_instance xlslice shiftsliceqtx2
ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_WIDTH  16
ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_FROM    7
ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_TO      0
ad_ip_parameter shiftsliceqtx2 CONFIG.DOUT_WIDTH  8
ad_connect tx_upack/fifo_rd_data_2 shiftsliceqtx2/Din

ad_ip_instance xlconcat concatslicetx_q2
ad_ip_parameter concatslicetx_q2 CONFIG.NUM_PORTS 3
ad_ip_parameter concatslicetx_q2 CONFIG.IN0_WIDTH 4
ad_ip_parameter concatslicetx_q2 CONFIG.IN1_WIDTH 8
ad_ip_parameter concatslicetx_q2 CONFIG.IN2_WIDTH 4
ad_connect shiftsliceqtx2/Dout concatslicetx_q2/In1

ad_ip_instance util_vector_logic logic_no_q0_tx2 [list C_OPERATION {not} C_SIZE 1]
ad_connect axi_ad9361/dac_enable_q1 logic_no_q0_tx2/Op1

create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_i2
ad_connect muxcs8_tx_i2/select_path   logic_no_q0_tx2/Res
ad_connect muxcs8_tx_i2/enable_in_0  axi_ad9361/dac_enable_i1
ad_connect tx_upack/fifo_rd_data_2   muxcs8_tx_i2/data_in_0
ad_connect concatslicetx_i2/Dout     muxcs8_tx_i2/data_in_1
ad_connect muxcs8_tx_i2/enable_in_1  axi_ad9361/dac_enable_i1
ad_connect muxcs8_tx_i2/data_out     axi_ad9361/dac_data_i1
ad_connect muxcs8_tx_i2/enable_out   tx_upack/enable_2

create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_q2
ad_connect muxcs8_tx_q2/select_path   logic_no_q0_tx2/Res
ad_connect muxcs8_tx_q2/enable_in_0  axi_ad9361/dac_enable_q1
ad_connect tx_upack/fifo_rd_data_3   muxcs8_tx_q2/data_in_0
ad_connect concatslicetx_q2/Dout     muxcs8_tx_q2/data_in_1
ad_connect muxcs8_tx_q2/enable_in_1  axi_ad9361/dac_enable_i1
ad_connect muxcs8_tx_q2/data_out     axi_ad9361/dac_data_q1
ad_connect muxcs8_tx_q2/enable_out   tx_upack/enable_3

# ---------------------------------------------------------------------------
# AXI interconnects
# ---------------------------------------------------------------------------

ad_cpu_interconnect 0x79020000 axi_ad9361
ad_cpu_interconnect 0x7C460000 maia_sdr
ad_cpu_interconnect 0x7C400000 axi_ad9361_adc_dma
ad_cpu_interconnect 0x7C420000 axi_ad9361_dac_dma
ad_cpu_interconnect 0x7C440000 axi_spi_jp5

# HP1 -- maia spectrometer DMA
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP1 {1}
ad_connect maia_sdr_clk/clk_out1        sys_ps7/S_AXI_HP1_ACLK
ad_connect maia_sdr/m_axi_spectrometer  sys_ps7/S_AXI_HP1

create_bd_addr_seg -range 0x20000000 -offset 0x00000000 \
    [get_bd_addr_spaces maia_sdr/m_axi_spectrometer] \
    [get_bd_addr_segs sys_ps7/S_AXI_HP1/HP1_DDR_LOWOCM] \
    SEG_sys_ps7_HP1_DDR_LOWOCM

# HP2 -- maia recorder + ADC DMA + DAC DMA
ad_mem_hp2_interconnect sys_cpu_clk sys_ps7/S_AXI_HP2
ad_mem_hp2_interconnect sys_cpu_clk maia_sdr/m_axi_recorder
ad_mem_hp2_interconnect sys_cpu_clk axi_ad9361_adc_dma/m_dest_axi
ad_mem_hp2_interconnect sys_cpu_clk axi_ad9361_dac_dma/m_src_axi

# ---------------------------------------------------------------------------
# Interrupts
# ---------------------------------------------------------------------------

ad_cpu_interrupt ps-13 mb-13 axi_ad9361_adc_dma/irq
ad_cpu_interrupt ps-12 mb-12 axi_ad9361_dac_dma/irq
ad_cpu_interrupt ps-11 mb-11 maia_sdr/interrupt_out
ad_cpu_interrupt ps-10 mb-10 axi_spi_jp5/ip2intc_irpt
