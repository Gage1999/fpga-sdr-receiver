
.PHONY: all prog sim sim_i2s sim_fm sim_lcd sim_fft sim_sdram sim_line_cache sim_scan_out sim_arb sim_compositor sim_integration sim_sdram_test sim_sdram_color prog_sdram_test prog_sdram_color prog_sdram_color75 prog_sdram_color_ci prog_sdram_cal prog_lcd_test prog_spi_rx_test prog_i2s_tone_test prog_full_audio_tone prog_fm_chain_test prog_fm_spi12 prog_fm_spi8 prog_fm_spi8_paced clean

SV_SRCS = src/top.sv \
          src/spi_cmd_slave.sv \
          src/control_regs.sv \
          src/audio_volume.sv \
          src/spi_iq_slave.sv \
          src/async_fifo.sv \
          src/fft256.sv \
          src/butterfly.sv \
          src/twiddle_rom.sv \
          src/waterfall_buf.sv \
          src/cic_decimate.sv \
          src/fm_demod.sv \
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

build/i2s_tone_test.bit: tests/i2s_tone_test_top.sv src/i2s_tx.sv $(LPF) | build
	yosys -p "synth_ecp5 -top i2s_tone_test_top -json build/i2s_tone_test.json" tests/i2s_tone_test_top.sv src/i2s_tx.sv
	nextpnr-ecp5 $(DEVICE) --json build/i2s_tone_test.json --textcfg build/i2s_tone_test.cfg --lpf $(LPF) --freq 25
	ecppack build/i2s_tone_test.cfg $@

prog_i2s_tone_test: build/i2s_tone_test.bit
	icesprog $<

build/full_audio_tone.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set AUDIO_TEST_TONE 1 top; synth_ecp5 -top $(TOP) -json build/full_audio_tone.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/full_audio_tone.json --textcfg build/full_audio_tone.cfg --lpf $(LPF) --freq 25
	ecppack build/full_audio_tone.cfg $@

prog_full_audio_tone: build/full_audio_tone.bit
	icesprog $<

build/fm_chain_test.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set FM_CHAIN_TEST 1 top; synth_ecp5 -top $(TOP) -json build/fm_chain_test.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_chain_test.json --textcfg build/fm_chain_test.cfg --lpf $(LPF) --freq 25
	ecppack build/fm_chain_test.cfg $@

prog_fm_chain_test: build/fm_chain_test.bit
	icesprog $<

build/fm_spi12.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set FM_CIC_R 12 top; synth_ecp5 -top $(TOP) -json build/fm_spi12.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_spi12.json --textcfg build/fm_spi12.cfg --lpf $(LPF) --freq 25
	ecppack build/fm_spi12.cfg $@

prog_fm_spi12: build/fm_spi12.bit
	icesprog $<

build/fm_spi8.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set FM_CIC_R 8 top; synth_ecp5 -top $(TOP) -json build/fm_spi8.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_spi8.json --textcfg build/fm_spi8.cfg --lpf $(LPF) --freq 25
	ecppack build/fm_spi8.cfg $@

prog_fm_spi8: build/fm_spi8.bit
	icesprog $<

build/fm_spi8_paced.bit: $(SV_SRCS) $(LPF) build/font_8x16.mem | build
	yosys -p "chparam -set FM_CIC_R 8 -set IQ_PACED 1 -set IQ_SAMPLE_RATE 349000 -set IQ_FIFO_DEPTH 64 top; synth_ecp5 -top $(TOP) -json build/fm_spi8_paced.json" $(SV_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/fm_spi8_paced.json --textcfg build/fm_spi8_paced.cfg --lpf $(LPF) --freq 25
	ecppack build/fm_spi8_paced.cfg $@

prog_fm_spi8_paced: build/fm_spi8_paced.bit
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

sim_i2s: tb/tb_i2s_tx.sv src/i2s_tx.sv | build
	iverilog -g2012 -o build/i2s.sim $^
	vvp build/i2s.sim

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

build:
	mkdir -p build

clean:
	rm -rf build
