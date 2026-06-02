.PHONY: all test-build test-deploy test-run spi-reg-build spi-reg-deploy spi-reg-run stream-build stream-deploy stream-run stream-stop radio-run tlv-radio-run synth-fm-run tlv-synth-fm-run goes-build goes-deploy goes-run goes-test ads-build ads-deploy ads-run ads-test clean

CROSS   = C:/Xilinx/Vitis/2022.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc
PLUTO   ?= 192.168.2.1
SSH     = ssh root@$(PLUTO)
SCP     = scp -O

TEST_SRC = tests/test_icesugar.c
TEST_BIN = build/test_icesugar

TEST     ?= full   # null | full | tone | longtone | sine | sweep | noise | fm | slowfull | slowtone

SPI_REG_SRC = tests/test_spi_reg.c
SPI_REG_BIN = build/test_spi_reg

STREAM_SRC = src/icesugar_stream.c
STREAM_BIN = build/icesugar_stream
STREAM_ARGS ?= --mode fm --freq-mhz 95.1 --adc-rate 0 --rate 1000000
FREQ_MHZ    ?= 95.1

FM_AUDIO_IQ_RATE  ?= 260417
FM_AUDIO_ADC_RATE ?= 2604170
FM_AUDIO_CHUNK    ?= 1024
FM_AUDIO_TLV_CHUNK ?= 4096
FM_AUDIO_RF_BW    ?= 1000000
FM_AUDIO_GAIN_MODE ?= slow_attack
FM_AUDIO_IQ_SHIFT ?= 4

all: test-build

$(TEST_BIN): $(TEST_SRC) | build
	$(CROSS) -O2 -static -o $@ $< -lm

test-build: $(TEST_BIN)

test-deploy: test-build
	$(SCP) $(TEST_BIN) root@$(PLUTO):/root/test_icesugar
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/test_icesugar'

test-run: test-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/test_icesugar $(TEST)'

$(SPI_REG_BIN): $(SPI_REG_SRC) | build
	$(CROSS) -O2 -static -o $@ $<

spi-reg-build: $(SPI_REG_BIN)

spi-reg-deploy: spi-reg-build
	$(SCP) $(SPI_REG_BIN) root@$(PLUTO):/root/test_spi_reg
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/test_spi_reg'

spi-reg-run: spi-reg-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/test_spi_reg'

$(STREAM_BIN): $(STREAM_SRC) | build
	$(CROSS) -O2 -static -o $@ $< -lm

stream-build: $(STREAM_BIN)

stream-deploy: stream-build
	$(SCP) $(STREAM_BIN) root@$(PLUTO):/root/icesugar_stream
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/icesugar_stream'

stream-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream $(STREAM_ARGS)'

# Stop a running streamer over SSH (Ctrl-C on a non-TTY ssh does not reach it).
# Sends SIGTERM (which icesugar_stream handles for a clean exit), so no reboot needed.
stream-stop:
	MSYS_NO_PATHCONV=1 $(SSH) 'killall icesugar_stream || true'

# Live FM radio receive test.
# Pair with: make prog_fm_audio_test  (in icesugar_pro/)
# Override frequency:  make radio-run FREQ_MHZ=101.3
# Match the standalone FPGA audio baseline:
#   IQ rate ~= 260.417 kSPS, FM_CIC_R=8 -> 32.552 kHz I2S.
# The ADC rate is 10x the FPGA IQ rate so software decimation is uniform.
radio-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream --mode fm --freq-mhz $(FREQ_MHZ) --adc-rate $(FM_AUDIO_ADC_RATE) --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_CHUNK) --rf-bw $(FM_AUDIO_RF_BW) --gain-mode $(FM_AUDIO_GAIN_MODE) --iq-shift $(FM_AUDIO_IQ_SHIFT) --dc-shift 12'

# Live FM radio using TLV_IQ packets. Pair with `make prog_tlv` in icesugar_pro/.
tlv-radio-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream --mode tlv-radio --freq-mhz $(FREQ_MHZ) --adc-rate $(FM_AUDIO_ADC_RATE) --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_TLV_CHUNK) --rf-bw $(FM_AUDIO_RF_BW) --gain-mode $(FM_AUDIO_GAIN_MODE) --iq-shift $(FM_AUDIO_IQ_SHIFT) --dc-shift 12'

# Synthetic FM through the same Pluto->FPGA SPI path. If this is clean but
# radio-run buzzes, the artifact is coming from live RF/IIO samples rather than
# the FPGA I2S/DAC path.
synth-fm-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream --mode synth-fm --rate $(FM_AUDIO_IQ_RATE) --chunk-samples 128 --synth-amp 8000 --synth-dev 5000'

# Synthetic FM wrapped in TLV_IQ packets. Pair with `make prog_tlv`.
tlv-synth-fm-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream --mode tlv-fm --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_TLV_CHUNK) --synth-amp 8000 --synth-dev 5000'

GOES_SRC = src/goes_stream.c
GOES_BIN = build/goes_stream

$(GOES_BIN): $(GOES_SRC) | build
	$(CROSS) -O2 -static -o $@ $< -lm

goes-build: $(GOES_BIN)

goes-deploy: goes-build
	$(SCP) $(GOES_BIN) root@$(PLUTO):/root/goes_stream
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/goes_stream'

goes-run: goes-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/goes_stream --duration 0'

goes-test: goes-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/goes_stream --dry-run --duration 30'

ADS_SRC = src/ads_stream.c
ADS_BIN = build/ads_stream

$(ADS_BIN): $(ADS_SRC) | build
	$(CROSS) -O2 -static -o $@ $< -lm

ads-build: $(ADS_BIN)

ads-deploy: ads-build
	$(SCP) $(ADS_BIN) root@$(PLUTO):/root/ads_stream
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/ads_stream'

ads-run: ads-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/ads_stream --duration 0'

# Quick sanity check: configure IIO only, no streaming.
ads-test: ads-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/ads_stream --dry-run'

build:
	mkdir -p build

clean:
	rm -rf build
