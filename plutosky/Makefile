.PHONY: all test-build test-deploy test-run spi-reg-build spi-reg-deploy spi-reg-run stream-build stream-deploy stream-run clean

CROSS   = C:/Xilinx/Vitis/2022.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc
PLUTO   ?= 192.168.2.1
SSH     = ssh root@$(PLUTO)
SCP     = scp -O

TEST_SRC = tests/test_icesugar.c
TEST_BIN = build/test_icesugar

TEST     ?= full   # null | full | tone | sweep | noise | fm | slowfull | slowtone

SPI_REG_SRC = tests/test_spi_reg.c
SPI_REG_BIN = build/test_spi_reg

STREAM_SRC = src/icesugar_stream.c
STREAM_BIN = build/icesugar_stream
STREAM_ARGS ?= --mode fm --freq-mhz 95.1 --adc-rate 0 --rate 1000000

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

build:
	mkdir -p build

clean:
	rm -rf build
