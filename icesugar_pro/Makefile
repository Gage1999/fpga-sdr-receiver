
.PHONY: all prog sim sim_i2s sim_fm sim_lcd sim_fft prog_lcd_test prog_spi_rx_test prog_i2s_tone_test prog_full_audio_tone prog_fm_chain_test prog_fm_spi12 prog_fm_spi8 clean

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

sim: tb/top_tb.sv $(SV_SRCS) build/font_8x16.mem | build
	iverilog -g2012 -o build/$(TOP).sim tb/top_tb.sv $(SV_SRCS)
	vvp build/$(TOP).sim
	gtkwave build/$(TOP).vcd

sim_i2s: tb/tb_i2s_tx.sv src/i2s_tx.sv | build
	iverilog -g2012 -o build/i2s.sim $^
	vvp build/i2s.sim

sim_fm: tb/tb_fm_demod.sv src/fm_demod.sv | build
	iverilog -g2012 -o build/fm_demod.sim $^
	vvp build/fm_demod.sim

sim_lcd: tb/tb_lcd.sv src/lcd.sv src/color_lut.sv src/font8x16_rom.sv build/font_8x16.mem | build
	iverilog -g2012 -o build/lcd.sim tb/tb_lcd.sv src/lcd.sv src/color_lut.sv src/font8x16_rom.sv
	vvp build/lcd.sim

sim_fft: tb/tb_fft256.sv src/fft256.sv src/butterfly.sv src/twiddle_rom.sv | build
	iverilog -g2012 -o build/fft256.sim $^
	vvp build/fft256.sim

build:
	mkdir -p build

clean:
	rm -rf build
