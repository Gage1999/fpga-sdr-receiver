
.PHONY: all prog prog_tlv sim sim_fm sim_lcd sim_fft sim_sdram sim_sdram_bl sim_line_cache sim_scan_out sim_arb sim_compositor sim_integration sim_sdram_test sim_sdram_color prog_sdram_test prog_sdram_color prog_sdram_color75 prog_sdram_color_ci prog_sdram_cal prog_sdram_cal_guard prog_sdram_cal_bl8 prog_sdram_cal_75 prog_lcd_test prog_spi_rx_test prog_tlv_link_test sim_spi_frame_rx sim_tlv_demux sim_tlv sim_tlv_all prog_fm_audio_test prog_fm_audio_tone_test prog_fm_audio_iq_test clean

SV_SRCS = src/top.sv \
          src/spi_cmd_slave.sv \
          src/control_regs.sv \
          src/audio_volume.sv \
          src/spi_iq_slave.sv \
          src/spi_frame_rx.sv \
          src/tlv_demux.sv \
          src/tlv_iq_sink.sv \
          src/tlv_capture_sink.sv \
          src/async_fifo.sv \
          src/fft256.sv \
          src/butterfly.sv \
          src/twiddle_rom.sv \
          src/waterfall_buf.sv \
          src/cic_decimate.sv \
          src/fm_demod.sv \
          src/audio_fifo.sv \
          src/i2s_tx.sv \
          src/color_lut.sv \
          src/font8x16_rom.sv \
          src/scan_timing.sv \
          src/lcd.sv
TOP      = top
LPF      = top.lpf
DEVICE   = --25k --package CABGA256 --speed 6

all: build/$(TOP).bit

build/font_8x16.mem: ../tools/rom_to_mem.py model/src/font.c model/src/sprites.c model/src/palette.c | build
	python3 ../tools/rom_to_mem.py --out build

build/$(TOP).json: $(SV_SRCS) build/font_8x16.mem | build
	yosys -p "synth_ecp5 -top $(TOP) -json $@" $(SV_SRCS)

build/$(TOP).cfg: build/$(TOP).json $(LPF)
	nextpnr-ecp5 $(DEVICE) \
	    --json $< --textcfg $@ --lpf $(LPF) --freq 25

build/$(TOP).bit: build/$(TOP).cfg
	ecppack $< $@

prog: build/$(TOP).bit
	icesprog $<

# FM build that consumes the TLV-framed IQ link (USE_TLV=1). Same top, selected
# by parameter; the default `prog` stays raw-IQ. Pair with the Pluto sending
# TLV_IQ packets (icesugar_stream --mode tlv-radio or --mode tlv-fm).
build/tlv.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set USE_TLV 1 -set FM_CIC_R 8 -set IQ_FIFO_DEPTH $(FM_AUDIO_IQ_FIFO_DEPTH) -set IQ_PREROLL_SAMPLES $(FM_AUDIO_IQ_PREROLL) -set IQ_SAMPLE_RATE $(FM_AUDIO_IQ_RATE) -set BYTE_FIFO_DEPTH $(FM_AUDIO_BYTE_FIFO_DEPTH) -set I2S_AUDIO_RATE $(FM_AUDIO_I2S_RATE) -set I2S_BCLK_HALF_CYCLES $(FM_AUDIO_BCLK_HALF) -set AUDIO_WARMUP_SAMPLES $(FM_AUDIO_WARMUP) top; synth_ecp5 -top $(TOP) -json build/tlv.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/tlv.json --textcfg build/tlv.cfg --lpf $(LPF) --freq 25
	ecppack build/tlv.cfg $@

prog_tlv: build/tlv.bit
	icesprog $<

build/lcd_test.bit: tests/lcd_color_test_top.sv $(LPF) | build
	yosys -p "synth_ecp5 -top lcd_color_test_top -json build/lcd_test.json" $<
	nextpnr-ecp5 $(DEVICE) --json build/lcd_test.json --textcfg build/lcd_test.cfg --lpf $(LPF) --freq 25
	ecppack build/lcd_test.cfg $@

prog_lcd_test: build/lcd_test.bit
	icesprog $<

build/spi_rx_test.bit: tests/spi_rx_lcd_test_top.sv src/spi_iq_slave.sv $(LPF) | build
	yosys -p "synth_ecp5 -top spi_rx_lcd_test_top -json build/spi_rx_test.json" tests/spi_rx_lcd_test_top.sv src/spi_iq_slave.sv
	nextpnr-ecp5 $(DEVICE) --json build/spi_rx_test.json --textcfg build/spi_rx_test.cfg --lpf $(LPF) --freq 25
	ecppack build/spi_rx_test.cfg $@

prog_spi_rx_test: build/spi_rx_test.bit
	icesprog $<

# TLV functional test: Pluto sends an incrementing counter wrapped in TLV_IQ
# packets (icesugar_stream --mode tlv-test). This build runs the real TLV RX
# chain (spi_frame_rx -> tlv_demux -> tlv_iq_sink) and shows on the LCD:
# green banner = IQ words reassembled correctly (prev+1), cyan/yellow/magenta
# rows = iq/image/object packet counts (routing), bottom band red = framing slip.
TLV_RX_SRCS = tests/tlv_link_test_top.sv src/spi_frame_rx.sv src/async_fifo.sv \
              src/tlv_demux.sv src/tlv_iq_sink.sv
build/tlv_link_test.bit: $(TLV_RX_SRCS) $(LPF) | build
	yosys -p "synth_ecp5 -top tlv_link_test_top -json build/tlv_link_test.json" $(TLV_RX_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/tlv_link_test.json --textcfg build/tlv_link_test.cfg --lpf $(LPF) --freq 25
	ecppack build/tlv_link_test.cfg $@

prog_tlv_link_test: build/tlv_link_test.bit
	icesprog $<

# Minimal FM audio path: SPI IQ -> paced FIFO -> FM demod -> audio FIFO -> I2S.
# No LCD, FFT, or waterfall; this is the hardware-proven audio baseline.
FM_AUDIO_IQ_RATE       = 260417
FM_AUDIO_I2S_RATE      = 32552
FM_AUDIO_BCLK_HALF     = 6
FM_AUDIO_IQ_FIFO_DEPTH = 8192
FM_AUDIO_IQ_PREROLL    = 4096
FM_AUDIO_BYTE_FIFO_DEPTH = 4096
FM_AUDIO_WARMUP        = 512

FM_AUDIO_TEST_SRCS = tests/fm_audio_test_top.sv \
                     src/spi_iq_slave.sv \
                     src/async_fifo.sv \
                     src/fm_demod.sv \
                     src/audio_fifo.sv \
                     src/i2s_tx.sv

build/fm_audio_test.bit: $(FM_AUDIO_TEST_SRCS) $(LPF) | build
	yosys -p "chparam -set IQ_FIFO_DEPTH $(FM_AUDIO_IQ_FIFO_DEPTH) -set IQ_PREROLL_SAMPLES $(FM_AUDIO_IQ_PREROLL) -set IQ_SAMPLE_RATE $(FM_AUDIO_IQ_RATE) -set I2S_AUDIO_RATE $(FM_AUDIO_I2S_RATE) -set I2S_BCLK_HALF_CYCLES $(FM_AUDIO_BCLK_HALF) fm_audio_test_top; synth_ecp5 -top fm_audio_test_top -json build/fm_audio_test.json" $(FM_AUDIO_TEST_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_audio_test.json --textcfg build/fm_audio_test.cfg --lpf $(LPF) --placer heap
	ecppack build/fm_audio_test.cfg $@

prog_fm_audio_test: build/fm_audio_test.bit
	icesprog $<

# Diagnostics for isolating the audio path:
# - tone: bypasses SPI and FM demod, exercises I2S/DAC only.
# - iq: generates FM IQ in fabric, exercises FPGA demod/audio without Pluto SPI.
build/fm_audio_tone_test.bit: $(FM_AUDIO_TEST_SRCS) $(LPF) | build
	yosys -p "chparam -set AUDIO_TEST_TONE 1 -set I2S_AUDIO_RATE $(FM_AUDIO_I2S_RATE) -set I2S_BCLK_HALF_CYCLES $(FM_AUDIO_BCLK_HALF) fm_audio_test_top; synth_ecp5 -top fm_audio_test_top -json build/fm_audio_tone_test.json" $(FM_AUDIO_TEST_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_audio_tone_test.json --textcfg build/fm_audio_tone_test.cfg --lpf $(LPF) --placer heap
	ecppack build/fm_audio_tone_test.cfg $@

prog_fm_audio_tone_test: build/fm_audio_tone_test.bit
	icesprog $<

build/fm_audio_iq_test.bit: $(FM_AUDIO_TEST_SRCS) $(LPF) | build
	yosys -p "chparam -set IQ_TEST_FM 1 -set IQ_SAMPLE_RATE $(FM_AUDIO_IQ_RATE) -set I2S_AUDIO_RATE $(FM_AUDIO_I2S_RATE) -set I2S_BCLK_HALF_CYCLES $(FM_AUDIO_BCLK_HALF) fm_audio_test_top; synth_ecp5 -top fm_audio_test_top -json build/fm_audio_iq_test.json" $(FM_AUDIO_TEST_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_audio_iq_test.json --textcfg build/fm_audio_iq_test.cfg --lpf $(LPF) --placer heap
	ecppack build/fm_audio_iq_test.cfg $@

prog_fm_audio_iq_test: build/fm_audio_iq_test.bit
	icesprog $<

# SDRAM bring-up test: write/read pattern, whole LCD green=pass / red=fail / blue=running
build/sdram_test.bit: src/sdram_test_top.sv src/sdram_ctrl.sv $(LPF) | build
	yosys -p "synth_ecp5 -top sdram_test_top -json build/sdram_test.json" src/sdram_test_top.sv src/sdram_ctrl.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_test.json --textcfg build/sdram_test.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_test.cfg $@

prog_sdram_test: build/sdram_test.bit
	icesprog $<

# Phase 3: fill the framebuffer with colour bars at startup, display via scan_out + line_cache
SDRAM_COLOR_SRCS = src/top_sdram_color.sv src/sdram_ctrl.sv src/scan_out.sv src/line_cache.sv src/scan_timing.sv
build/sdram_color.bit: $(SDRAM_COLOR_SRCS) $(LPF) | build
	yosys -p "synth_ecp5 -top top_sdram_color -json build/sdram_color.json" $(SDRAM_COLOR_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_color.json --textcfg build/sdram_color.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_color.cfg $@

# Phase 4+5 integration: live waterfall (generator -> FIFO -> compositor -> arb -> ctrl;
# scan_out -> line_cache -> LCD). Half-page layout throughout.
build/sdram_wf.bit: $(SDRAM_WF_SRCS) $(LPF) | build
	yosys -p "synth_ecp5 -top top_sdram_wf -json build/sdram_wf.json" $(SDRAM_WF_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_wf.json --textcfg build/sdram_wf.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_wf.cfg $@

prog_sdram_wf: build/sdram_wf.bit
	icesprog $<

# Diagnostic: compositor tied off (read path + arbiter only). If the streaks vanish here,
# they come from the compositor writes / read-write interleaving, not the read path.
build/sdram_wf_nowr.bit: $(SDRAM_WF_SRCS) $(LPF) | build
	yosys -p "chparam -set WRITE_EN 0 top_sdram_wf; synth_ecp5 -top top_sdram_wf -json build/sdram_wf_nowr.json" $(SDRAM_WF_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_wf_nowr.json --textcfg build/sdram_wf_nowr.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_wf_nowr.cfg $@

prog_sdram_wf_nowr: build/sdram_wf_nowr.bit
	icesprog $<

# Diagnostic: writes happen but the display doesn't scroll (wf_base_row held 0). Removes
# scroll tearing as a confound -- you should see the static grey gradient if writes are clean.
build/sdram_wf_static.bit: $(SDRAM_WF_SRCS) $(LPF) | build
	yosys -p "chparam -set FREEZE_SCROLL 1 top_sdram_wf; synth_ecp5 -top top_sdram_wf -json build/sdram_wf_static.json" $(SDRAM_WF_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_wf_static.json --textcfg build/sdram_wf_static.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_wf_static.cfg $@

prog_sdram_wf_static: build/sdram_wf_static.bit
	icesprog $<

prog_sdram_color: build/sdram_color.bit
	icesprog $<

# Same as sdram_color but with the 2D diagnostic pattern (R/B by line, G by column)
build/sdram_diag.bit: $(SDRAM_COLOR_SRCS) $(LPF) | build
	yosys -p "chparam -set DIAG 1 top_sdram_color; synth_ecp5 -top top_sdram_color -json build/sdram_diag.json" $(SDRAM_COLOR_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_diag.json --textcfg build/sdram_diag.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_diag.cfg $@

prog_sdram_diag: build/sdram_diag.bit
	icesprog $<

# Same as sdram_color but clk_sdram = 75 MHz (clk_pix stays 30 MHz, refresh = 585 cyc).
# Diagnostic: if the stray streaks vanish at 75 MHz, the cause is SDRAM read-capture margin.
build/sdram_color75.bit: $(SDRAM_COLOR_SRCS) $(LPF) | build
	yosys -p "chparam -set CLKFB_DIV 3 -set CLKOP_DIV 8 -set CLKOS_DIV 20 -set CLKOP_CPHASE 4 -set CLKOS_CPHASE 4 -set TREF 585 top_sdram_color; synth_ecp5 -top top_sdram_color -json build/sdram_color75.json" $(SDRAM_COLOR_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_color75.json --textcfg build/sdram_color75.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_color75.cfg $@

prog_sdram_color75: build/sdram_color75.bit
	icesprog $<

# 100 MHz, but with the SDRAM clock pin inverted (180 deg) to add read-capture margin
build/sdram_color_ci.bit: $(SDRAM_COLOR_SRCS) $(LPF) | build
	yosys -p "chparam -set SDRAM_CLK_INV 1 top_sdram_color; synth_ecp5 -top top_sdram_color -json build/sdram_color_ci.json" $(SDRAM_COLOR_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_color_ci.json --textcfg build/sdram_color_ci.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_color_ci.cfg $@

prog_sdram_color_ci: build/sdram_color_ci.bit
	icesprog $<

# Read-capture phase sweep: same colour-bar display, but the SDRAM read data is sampled
# on phase 0/90/180/270 deg. Flash p0 (baseline), p1, p2, p3 and see which clears the
# streaks; that phase is the calibrated read-capture point.
build/sdram_color_p%.bit: $(SDRAM_COLOR_SRCS) $(LPF) | build
	yosys -p "chparam -set CAP_PHASE $* top_sdram_color; synth_ecp5 -top top_sdram_color -json build/sdram_color_p$*.json" $(SDRAM_COLOR_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/sdram_color_p$*.json --textcfg build/sdram_color_p$*.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_color_p$*.cfg $@

prog_sdram_color_p%: build/sdram_color_p%.bit
	icesprog $<

# Read-capture calibration: bar per phase (0/45/90/180/225/270 deg), red height = error count.
# Shortest bar = best phase; all-green = 0 errors. Also shows read-vs-write (see top_sdram_cal.sv).
build/sdram_cal.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "synth_ecp5 -top top_sdram_cal -json build/sdram_cal.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal.json --textcfg build/sdram_cal.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal.cfg $@

prog_sdram_cal: build/sdram_cal.bit
	icesprog $<

# Write-clock-phase sweep: same 4-band error display, but the clock to the SDRAM chip is
# shifted 0/90/180/270 deg (w0/w1/w2/w3) to centre the chip's write-data sampling.
# Flash each and look at the error floor (the short bars): whichever build makes them go
# green has clean writes -> that is the write-clock phase to lock in.
build/sdram_cal_w%.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set WR_CLK_PHASE $* top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_w$*.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_w$*.json --textcfg build/sdram_cal_w$*.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_w$*.cfg $@

prog_sdram_cal_w%: build/sdram_cal_w%.bit
	icesprog $<

# Page-split calibration: same 4-band error display, but the access crosses an SDRAM row
# boundary (512 words in row 0 + 88 in row 1) like the framebuffer path. If this shows
# errors while the single-row cal was clean, the streaks are in the page-crossing path.
build/sdram_cal_split.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set SPLIT 1 top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_split.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_split.json --textcfg build/sdram_cal_split.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_split.cfg $@

prog_sdram_cal_split: build/sdram_cal_split.bit
	icesprog $<

# Isolate length vs page-edge: 256-word read that ENDS at column 511 (page edge).
# If this is broken like the 512 read -> the page-edge column is the problem.
# If it is clean like the col0/256 baseline -> the full 512-word length is the problem.
build/sdram_cal_edge.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set TEST_COL 256 -set TEST_LEN 256 top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_edge.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_edge.json --textcfg build/sdram_cal_edge.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_edge.cfg $@

prog_sdram_cal_edge: build/sdram_cal_edge.bit
	icesprog $<

# ===========================================================================
# Doc-preserving fix candidates. All use the page-crossing SPLIT access (the
# framebuffer-like case that streaks). 4 bands = the 4 read-capture phases;
# all-green = that variant read+wrote the boundary with 0 errors -> the fix
# preserves the contiguous layout. Still red = that variant does not help.
# ===========================================================================

# (1) Guard cycles: full-page burst, but defer PRECHARGE a couple of NOPs after the
# last beat. Tests whether the boundary marginality is just burst-termination timing.
build/sdram_cal_guard.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set SPLIT 1 -set RD_GUARD 2 -set WR_GUARD 2 top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_guard.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_guard.json --textcfg build/sdram_cal_guard.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_guard.cfg $@

prog_sdram_cal_guard: build/sdram_cal_guard.bit
	icesprog $<

# (2) BL=8 chunks: never use full-page streaming/wrap; issue a fresh READ/WRITE per 8
# words. Tests whether the full-page burst mode itself is the unreliable part.
build/sdram_cal_bl8.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set SPLIT 1 -set BURST_MODE 1 top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_bl8.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_bl8.json --textcfg build/sdram_cal_bl8.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_bl8.cfg $@

prog_sdram_cal_bl8: build/sdram_cal_bl8.bit
	icesprog $<

# (3) Lower clock: same full-page design at 75 MHz (CLKFB 3, CLKOP 8 -> VCO 600, pixel 30).
# Tests whether the boundary is a pure setup/hold or signal-integrity margin issue.
build/sdram_cal_75.bit: src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv $(LPF) | build
	yosys -p "chparam -set SPLIT 1 -set CLKFB_DIV 3 -set CLKOP_DIV 8 -set CLKOS_DIV 20 -set CLKOS2_DIV 8 top_sdram_cal; synth_ecp5 -top top_sdram_cal -json build/sdram_cal_75.json" src/top_sdram_cal.sv src/sdram_ctrl.sv src/scan_timing.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_cal_75.json --textcfg build/sdram_cal_75.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_cal_75.cfg $@

prog_sdram_cal_75: build/sdram_cal_75.bit
	icesprog $<

# WSL-friendly flash: copy the bitstream onto the iCELink mass-storage drive.
# No USB passthrough needed. Set ICELINK to wherever Windows mounted the iCELink
# drive (e.g. make prog_sdram_test_drive ICELINK=/mnt/g).
ICELINK ?= /mnt/e
prog_sdram_test_drive: build/sdram_test.bit
	@test -d "$(ICELINK)" || { echo "ICELINK drive '$(ICELINK)' not found — plug in the board and pass ICELINK=/mnt/<letter>"; exit 1; }
	cp build/sdram_test.bit "$(ICELINK)/"
	@echo "Copied sdram_test.bit to $(ICELINK) — the board should reprogram and the LCD should turn green (pass)."

sim: tb/top_tb.sv $(SV_SRCS) build/font_8x16.mem | build
	iverilog -g2012 -DSIMULATION -o build/$(TOP).sim tb/top_tb.sv $(SV_SRCS)
	vvp build/$(TOP).sim
	gtkwave build/$(TOP).vcd

sim_fm: tb/tb_fm_demod.sv src/fm_demod.sv | build
	iverilog -g2012 -o build/fm_demod.sim $^
	vvp build/fm_demod.sim

sim_lcd: tb/tb_lcd.sv src/lcd.sv src/color_lut.sv src/font8x16_rom.sv src/scan_timing.sv build/font_8x16.mem | build
	iverilog -g2012 -o build/lcd.sim tb/tb_lcd.sv src/lcd.sv src/color_lut.sv src/font8x16_rom.sv src/scan_timing.sv
	vvp build/lcd.sim

sim_fft: tb/tb_fft256.sv src/fft256.sv src/butterfly.sv src/twiddle_rom.sv | build
	iverilog -g2012 -o build/fft256.sim $^
	vvp build/fft256.sim

sim_sdram: tests/sdram_ctrl_tb.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/sdram_ctrl.sim tests/sdram_ctrl_tb.sv src/sdram_ctrl.sv
	vvp build/sdram_ctrl.sim

sim_sdram_bl: tests/sdram_ctrl_bl_tb.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/sdram_ctrl_bl.sim tests/sdram_ctrl_bl_tb.sv src/sdram_ctrl.sv
	vvp build/sdram_ctrl_bl.sim

SDRAM_WF_SRCS = src/top_sdram_wf.sv src/sdram_ctrl.sv src/sdram_arb.sv src/scan_out.sv \
                src/compositor.sv src/line_cache.sv src/scan_timing.sv src/async_fifo.sv
sim_sdram_wf: tests/sdram_wf_tb.sv $(SDRAM_WF_SRCS) | build
	iverilog -g2012 -DSIMULATION -o build/sdram_wf.sim tests/sdram_wf_tb.sv $(SDRAM_WF_SRCS)
	vvp build/sdram_wf.sim

sim_line_cache: tests/line_cache_tb.sv src/line_cache.sv | build
	iverilog -g2012 -o build/line_cache.sim tests/line_cache_tb.sv src/line_cache.sv
	vvp build/line_cache.sim

sim_scan_out: tests/scan_out_tb.sv src/scan_out.sv src/sdram_ctrl.sv src/line_cache.sv | build
	iverilog -g2012 -o build/scan_out.sim tests/scan_out_tb.sv src/scan_out.sv src/sdram_ctrl.sv src/line_cache.sv
	vvp build/scan_out.sim

sim_arb: tests/sdram_arb_tb.sv src/sdram_arb.sv | build
	iverilog -g2012 -o build/sdram_arb.sim tests/sdram_arb_tb.sv src/sdram_arb.sv
	vvp build/sdram_arb.sim

sim_compositor: tests/compositor_tb.sv src/compositor.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/compositor.sim tests/compositor_tb.sv src/compositor.sv src/sdram_ctrl.sv
	vvp build/compositor.sim

sim_sdram_test: tests/sdram_test_top_tb.sv src/sdram_test_top.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -DSIMULATION -o build/sdram_test_top.sim tests/sdram_test_top_tb.sv src/sdram_test_top.sv src/sdram_ctrl.sv
	vvp build/sdram_test_top.sim

sim_sdram_color: tests/sdram_color_tb.sv $(SDRAM_COLOR_SRCS) | build
	iverilog -g2012 -DSIMULATION -o build/sdram_color.sim tests/sdram_color_tb.sv $(SDRAM_COLOR_SRCS)
	vvp build/sdram_color.sim

# Run every SDRAM-integration sim
sim_integration: sim_sdram sim_line_cache sim_scan_out sim_arb sim_compositor sim_sdram_test sim_sdram_color

# TLV receive-path unit sims (copied from the TLV bring-up)
sim_spi_frame_rx: tests/spi_frame_rx_tb.sv src/spi_frame_rx.sv | build
	iverilog -g2012 -o build/spi_frame_rx.sim $^
	vvp build/spi_frame_rx.sim

sim_tlv_demux: tests/tlv_demux_tb.sv src/tlv_demux.sv | build
	iverilog -g2012 -o build/tlv_demux.sim $^
	vvp build/tlv_demux.sim

sim_tlv: tests/tlv_rx_tb.sv src/spi_frame_rx.sv src/async_fifo.sv src/tlv_demux.sv src/tlv_iq_sink.sv | build
	iverilog -g2012 -o build/tlv_rx.sim $^
	vvp build/tlv_rx.sim

sim_tlv_all: sim_spi_frame_rx sim_tlv_demux sim_tlv
# ── Standalone synthesis of the pixel-shader block (budget / clean-build check).
#    Not yet wired into top.sv — that is integration #18, blocked on the SDRAM
#    stack. This measures the shader's area in isolation against the EBR/LUT
#    budget now. font_16x32.mem + sprite_rom.mem come from the rom_to_mem rule
#    below (build/font_8x16.mem), which emits every ROM in one pass.
SHADER_SRCS = src/pixel_shader_top.sv \
              src/pixel_shader.sv \
              src/font_16x32_rom.sv \
              src/sprite_rom.sv \
              src/spectrum_bin_ram.sv

.PHONY: synth_shader
synth_shader: build/shader.json

build/shader.json: $(SHADER_SRCS) build/font_8x16.mem | build
	yosys -l build/shader_synth.log \
	    -p "synth_ecp5 -top pixel_shader_top -json $@" $(SHADER_SRCS)

build:
	mkdir -p build

clean:
	rm -rf build
