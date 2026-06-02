.PHONY: all clean \
        stream-build stream-deploy stream-run stream-stop radio-run synth-fm-run \
        spi-reg-build spi-reg-deploy spi-reg-run \
        test-build test-deploy test-run \
        goes-build goes-deploy goes-run goes-test \
        ads-build ads-deploy ads-run ads-test \
        sdr-build sdr-deploy sdr-run sdr-stop

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
STREAM_ARGS ?= --mode tlv-radio --freq-mhz 95.1 --adc-rate 2604170 --rate 260417 --chunk-samples 4096 --rf-bw 1000000 --gain-mode slow_attack --iq-shift 4 --dc-shift 12
FREQ_MHZ    ?= 95.1

FM_AUDIO_IQ_RATE  ?= 260417
FM_AUDIO_ADC_RATE ?= 2604170
FM_AUDIO_TLV_CHUNK ?= 4096
FM_AUDIO_RF_BW    ?= 1000000
FM_AUDIO_GAIN_MODE ?= slow_attack
FM_AUDIO_IQ_SHIFT ?= 4

all: sdr-build

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

stream-stop:
	MSYS_NO_PATHCONV=1 $(SSH) 'killall sdr_main icesugar_stream || true'

# Live FM radio over the known-good TLV_IQ streamer. Pair with `make prog` in icesugar_pro/.
radio-run: stream-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/icesugar_stream --mode tlv-radio --freq-mhz $(FREQ_MHZ) --adc-rate $(FM_AUDIO_ADC_RATE) --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_TLV_CHUNK) --rf-bw $(FM_AUDIO_RF_BW) --gain-mode $(FM_AUDIO_GAIN_MODE) --iq-shift $(FM_AUDIO_IQ_SHIFT) --dc-shift 12'

# Synthetic FM over TLV_IQ through the same Pluto-to-iCeSugar SPI path.
synth-fm-run: stream-deploy
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

SDR_SRCS = src/main.c src/ads_stream.c src/goes_stream.c src/goes_lrit.c
SDR_BIN  = build/sdr_main
SDR_MODE ?= fm
SDR_FREQ ?= 95.1

$(SDR_BIN): $(SDR_SRCS) | build
	$(CROSS) -O2 -static -DSDR_MAIN_BUILD -o $@ $(SDR_SRCS) -lm

sdr-build: $(SDR_BIN)

sdr-deploy: sdr-build
	$(SCP) $(SDR_BIN) root@$(PLUTO):/root/sdr_main
	MSYS_NO_PATHCONV=1 $(SSH) 'chmod +x /root/sdr_main'

sdr-run: sdr-deploy
	MSYS_NO_PATHCONV=1 $(SSH) '/root/sdr_main --mode $(SDR_MODE) --freq-mhz $(SDR_FREQ)'

sdr-stop:
	MSYS_NO_PATHCONV=1 $(SSH) 'killall sdr_main || true'

build:
	mkdir -p build

clean:
	rm -rf build
