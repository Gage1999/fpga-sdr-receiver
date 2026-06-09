
.PHONY: all prog clean \
        prog_lcd_test prog_tlv_link_test \
        prog_fm_audio_test prog_fm_audio_tone_test prog_fm_audio_iq_test \
        prog_sdram_test \
        sim sim_fm sim_fft sim_audio_fifo sim_i2s_tx sim_sdram sim_sdram_bl sim_sdram_wf \
        sim_rds sim_rds_sync sim_rds_group sim_rds_demod sim_rds_chain \
        sim_spectrum_zoom_decimator \
        sim_line_cache sim_scan_out sim_arb sim_compositor sim_sdram_test \
        sim_integration sim_spi_frame_rx sim_ui_wire_rx sim_tlv_demux sim_tlv sim_tlv_all

SV_SRCS = src/top.sv \
          src/spi_ui_cmd_rx.sv \
          src/spi_backchannel.sv \
          src/ui_wire_rx.sv \
          src/ui_status_prepare.sv \
          src/control_regs.sv \
          src/audio_volume.sv \
          src/spi_frame_rx.sv \
          src/tlv_demux.sv \
          src/tlv_iq_sink.sv \
          src/async_fifo.sv \
          src/sdram_ctrl.sv \
          src/sdram_arb.sv \
          src/scan_out.sv \
          src/line_cache.sv \
          src/compositor.sv \
          src/spectrum_zoom_decimator.sv \
          src/fft256.sv \
          src/butterfly.sv \
          src/twiddle_rom.sv \
          src/fm_demod.sv \
          src/audio_fifo.sv \
          src/i2s_tx.sv \
          src/font_16x32_rom.sv \
          src/sprite_rom.sv \
          src/spectrum_bin_ram.sv \
          src/pixel_shader.sv \
          src/pixel_shader_top.sv \
          src/scan_timing.sv
TOP      = top
LPF      = top.lpf
DEVICE   = --25k --package CABGA256 --speed 6
ROMS     = build/font_16x32.mem build/sprite_rom.mem

all: build/$(TOP).bit

$(ROMS) &: ../tools/rom_to_mem.py model/src/font.c model/src/sprites.c model/src/palette.c | build
	python3 ../tools/rom_to_mem.py --out build

build/$(TOP).json: $(SV_SRCS) $(ROMS) | build
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

TLV_RX_SRCS = tests/tlv_link_test_top.sv src/spi_frame_rx.sv src/async_fifo.sv \
              src/tlv_demux.sv src/tlv_iq_sink.sv
build/tlv_link_test.bit: $(TLV_RX_SRCS) $(LPF) | build
	yosys -p "synth_ecp5 -top tlv_link_test_top -json build/tlv_link_test.json" $(TLV_RX_SRCS)
	nextpnr-ecp5 $(DEVICE) --json build/tlv_link_test.json --textcfg build/tlv_link_test.cfg --lpf $(LPF) --freq 25
	ecppack build/tlv_link_test.cfg $@

prog_tlv_link_test: build/tlv_link_test.bit
	icesprog $<

FM_AUDIO_IQ_RATE       = 260417
FM_AUDIO_I2S_RATE      = 32552
FM_AUDIO_BCLK_HALF     = 6
FM_AUDIO_IQ_FIFO_DEPTH = 8192
FM_AUDIO_IQ_PREROLL    = 4096

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

build/sdram_test.bit: tests/sdram_test_top.sv src/sdram_ctrl.sv $(LPF) | build
	yosys -p "synth_ecp5 -top sdram_test_top -json build/sdram_test.json" tests/sdram_test_top.sv src/sdram_ctrl.sv
	nextpnr-ecp5 $(DEVICE) --json build/sdram_test.json --textcfg build/sdram_test.cfg --lpf $(LPF) --freq 25
	ecppack build/sdram_test.cfg $@

prog_sdram_test: build/sdram_test.bit
	icesprog $<

sim: tb/top_tb.sv $(SV_SRCS) $(ROMS) | build
	iverilog -g2012 -DSIMULATION -o build/$(TOP).sim tb/top_tb.sv $(SV_SRCS)
	vvp build/$(TOP).sim

sim_fm: tb/tb_fm_demod.sv src/fm_demod.sv | build
	iverilog -g2012 -o build/fm_demod.sim $^
	vvp build/fm_demod.sim

sim_audio_fifo: tb/audio_fifo_tb.sv src/audio_fifo.sv | build
	iverilog -g2012 -o build/audio_fifo.sim $^
	vvp build/audio_fifo.sim

sim_i2s_tx: tb/tb_i2s_tx.sv src/i2s_tx.sv | build
	iverilog -g2012 -o build/i2s_tx.sim $^
	vvp build/i2s_tx.sim

sim_rds_sync: tb/tb_rds_sync.sv src/rds_sync.sv | build
	iverilog -g2012 -o build/rds_sync.sim $^
	vvp build/rds_sync.sim

sim_rds_group: tb/tb_rds_group.sv src/rds_group.sv | build
	iverilog -g2012 -o build/rds_group.sim $^
	vvp build/rds_group.sim

sim_rds_demod: tb/tb_rds_demod.sv src/rds_demod.sv | build
	iverilog -g2012 -o build/rds_demod.sim $^
	vvp build/rds_demod.sim

# Full RDS receive chain: synthesized MPX -> demod -> sync -> group -> PS name.
sim_rds_chain: tb/tb_rds_chain.sv src/rds_demod.sv src/rds_sync.sv src/rds_group.sv | build
	iverilog -g2012 -o build/rds_chain.sim $^
	vvp build/rds_chain.sim

sim_rds: sim_rds_sync sim_rds_group sim_rds_demod sim_rds_chain

sim_fft: tb/tb_fft256.sv src/fft256.sv src/butterfly.sv src/twiddle_rom.sv | build
	iverilog -g2012 -o build/fft256.sim $^
	vvp build/fft256.sim

sim_sdram: tb/sdram_ctrl_tb.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/sdram_ctrl.sim tb/sdram_ctrl_tb.sv src/sdram_ctrl.sv
	vvp build/sdram_ctrl.sim

sim_spectrum_zoom_decimator: tb/spectrum_zoom_decimator_tb.sv src/spectrum_zoom_decimator.sv | build
	iverilog -g2012 -o build/spectrum_zoom_decimator.sim $^
	vvp build/spectrum_zoom_decimator.sim

sim_sdram_bl: tb/sdram_ctrl_bl_tb.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/sdram_ctrl_bl.sim tb/sdram_ctrl_bl_tb.sv src/sdram_ctrl.sv
	vvp build/sdram_ctrl_bl.sim

SDRAM_WF_SRCS = tests/top_sdram_wf.sv src/sdram_ctrl.sv src/sdram_arb.sv src/scan_out.sv \
                src/compositor.sv src/line_cache.sv src/scan_timing.sv src/async_fifo.sv
sim_sdram_wf: tb/sdram_wf_tb.sv $(SDRAM_WF_SRCS) | build
	iverilog -g2012 -DSIMULATION -o build/sdram_wf.sim tb/sdram_wf_tb.sv $(SDRAM_WF_SRCS)
	vvp build/sdram_wf.sim

sim_line_cache: tb/line_cache_tb.sv src/line_cache.sv | build
	iverilog -g2012 -o build/line_cache.sim tb/line_cache_tb.sv src/line_cache.sv
	vvp build/line_cache.sim

sim_scan_out: tb/scan_out_tb.sv src/scan_out.sv src/sdram_ctrl.sv src/line_cache.sv | build
	iverilog -g2012 -o build/scan_out.sim tb/scan_out_tb.sv src/scan_out.sv src/sdram_ctrl.sv src/line_cache.sv
	vvp build/scan_out.sim

sim_arb: tb/sdram_arb_tb.sv src/sdram_arb.sv | build
	iverilog -g2012 -o build/sdram_arb.sim tb/sdram_arb_tb.sv src/sdram_arb.sv
	vvp build/sdram_arb.sim

sim_compositor: tb/compositor_tb.sv src/compositor.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -o build/compositor.sim tb/compositor_tb.sv src/compositor.sv src/sdram_ctrl.sv
	vvp build/compositor.sim

sim_sdram_test: tb/sdram_test_top_tb.sv tests/sdram_test_top.sv src/sdram_ctrl.sv | build
	iverilog -g2012 -DSIMULATION -o build/sdram_test_top.sim tb/sdram_test_top_tb.sv tests/sdram_test_top.sv src/sdram_ctrl.sv
	vvp build/sdram_test_top.sim

sim_integration: sim_sdram sim_line_cache sim_scan_out sim_arb sim_compositor sim_sdram_test sim_sdram_wf

sim_spi_frame_rx: tb/spi_frame_rx_tb.sv src/spi_frame_rx.sv | build
	iverilog -g2012 -o build/spi_frame_rx.sim $^
	vvp build/spi_frame_rx.sim

sim_ui_wire_rx: tb/ui_wire_rx_tb.sv src/ui_wire_rx.sv src/spi_frame_rx.sv | build
	iverilog -g2012 -o build/ui_wire_rx.sim $^
	vvp build/ui_wire_rx.sim

sim_tlv_demux: tb/tlv_demux_tb.sv src/tlv_demux.sv | build
	iverilog -g2012 -o build/tlv_demux.sim $^
	vvp build/tlv_demux.sim

sim_tlv: tb/tlv_rx_tb.sv src/spi_frame_rx.sv src/async_fifo.sv src/tlv_demux.sv src/tlv_iq_sink.sv | build
	iverilog -g2012 -o build/tlv_rx.sim $^
	vvp build/tlv_rx.sim

sim_tlv_all: sim_spi_frame_rx sim_tlv_demux sim_tlv
build:
	mkdir -p build

clean:
	rm -rf build
