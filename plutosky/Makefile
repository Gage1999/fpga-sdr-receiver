.PHONY: all clean \
        sdr-build sdr-deploy sdr-run sdr-stop \
stream-build stream-deploy stream-run synth-fm-run stream-stop radio-run \
        spi-reg-build spi-reg-deploy spi-reg-run \
        goes-build goes-deploy goes-run goes-test \
        ads-build ads-deploy ads-run ads-test

CROSS ?= C:/Xilinx/Vitis/2022.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc
PLUTO ?= 192.168.2.1
SSH = ssh root@$(PLUTO)
SCP = scp -O
REMOTE = root@$(PLUTO)
REMOTE_DIR = /root
MSYS_SSH = MSYS_NO_PATHCONV=1 $(SSH)

CFLAGS ?= -O2 -static
LDLIBS ?= -lm

all: sdr-build

# Final presentation runtime.
SDR_SRCS = src/main.c src/ads_stream.c src/goes_stream.c src/goes_lrit.c
SDR_BIN = build/sdr_main
SDR_MODE ?= fm
SDR_FREQ ?= 95.1

$(SDR_BIN): $(SDR_SRCS) | build
	$(CROSS) $(CFLAGS) -DSDR_MAIN_BUILD -o $@ $(SDR_SRCS) $(LDLIBS)

sdr-build: $(SDR_BIN)

sdr-deploy: sdr-build
	$(SCP) $(SDR_BIN) $(REMOTE):$(REMOTE_DIR)/sdr_main
	$(MSYS_SSH) 'chmod +x $(REMOTE_DIR)/sdr_main'

sdr-run: sdr-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/sdr_main --mode $(SDR_MODE) --freq-mhz $(SDR_FREQ)'

sdr-stop:
	$(MSYS_SSH) 'killall sdr_main || true'

# Standalone TLV streamer diagnostics.
STREAM_SRC = src/icesugar_stream.c
STREAM_BIN = build/icesugar_stream
FREQ_MHZ ?= 95.1
FM_AUDIO_ADC_RATE ?= 2604170
FM_AUDIO_IQ_RATE ?= 260417
FM_AUDIO_TLV_CHUNK ?= 4096
FM_AUDIO_RF_BW ?= 1000000
FM_AUDIO_GAIN_MODE ?= slow_attack
FM_AUDIO_IQ_SHIFT ?= 4
STREAM_ARGS ?= --mode tlv-radio --freq-mhz $(FREQ_MHZ) --adc-rate $(FM_AUDIO_ADC_RATE) --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_TLV_CHUNK) --rf-bw $(FM_AUDIO_RF_BW) --gain-mode $(FM_AUDIO_GAIN_MODE) --iq-shift $(FM_AUDIO_IQ_SHIFT) --dc-shift 12

$(STREAM_BIN): $(STREAM_SRC) | build
	$(CROSS) $(CFLAGS) -o $@ $< $(LDLIBS)

stream-build: $(STREAM_BIN)

stream-deploy: stream-build
	$(SCP) $(STREAM_BIN) $(REMOTE):$(REMOTE_DIR)/icesugar_stream
	$(MSYS_SSH) 'chmod +x $(REMOTE_DIR)/icesugar_stream'

stream-run: stream-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/icesugar_stream $(STREAM_ARGS)'

synth-fm-run: stream-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/icesugar_stream --mode tlv-fm --rate $(FM_AUDIO_IQ_RATE) --chunk-samples $(FM_AUDIO_TLV_CHUNK) --synth-amp 8000 --synth-dev 5000'

stream-stop:
	$(MSYS_SSH) 'killall icesugar_stream sdr_main || true'

radio-run: sdr-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/sdr_main --mode fm --freq-mhz $(FREQ_MHZ)'

# Low-level SPI register sanity check.
SPI_REG_SRC = tests/test_spi_reg.c
SPI_REG_BIN = build/test_spi_reg

$(SPI_REG_BIN): $(SPI_REG_SRC) | build
	$(CROSS) $(CFLAGS) -o $@ $<

spi-reg-build: $(SPI_REG_BIN)

spi-reg-deploy: spi-reg-build
	$(SCP) $(SPI_REG_BIN) $(REMOTE):$(REMOTE_DIR)/test_spi_reg
	$(MSYS_SSH) 'chmod +x $(REMOTE_DIR)/test_spi_reg'

spi-reg-run: spi-reg-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/test_spi_reg'

# Standalone mode diagnostics. The final app builds these into sdr_main.
GOES_SRCS = src/goes_stream.c src/goes_lrit.c
GOES_BIN = build/goes_stream

$(GOES_BIN): $(GOES_SRCS) | build
	$(CROSS) $(CFLAGS) -o $@ $(GOES_SRCS) $(LDLIBS)

goes-build: $(GOES_BIN)

goes-deploy: goes-build
	$(SCP) $(GOES_BIN) $(REMOTE):$(REMOTE_DIR)/goes_stream
	$(MSYS_SSH) 'chmod +x $(REMOTE_DIR)/goes_stream'

goes-run: goes-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/goes_stream --duration 0'

goes-test: goes-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/goes_stream --dry-run --duration 30'

ADS_SRC = src/ads_stream.c
ADS_BIN = build/ads_stream

$(ADS_BIN): $(ADS_SRC) | build
	$(CROSS) $(CFLAGS) -o $@ $< $(LDLIBS)

ads-build: $(ADS_BIN)

ads-deploy: ads-build
	$(SCP) $(ADS_BIN) $(REMOTE):$(REMOTE_DIR)/ads_stream
	$(MSYS_SSH) 'chmod +x $(REMOTE_DIR)/ads_stream'

ads-run: ads-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/ads_stream --duration 0'

ads-test: ads-deploy
	$(MSYS_SSH) '$(REMOTE_DIR)/ads_stream --dry-run'

build:
	mkdir -p build

clean:
	rm -rf build
