/*
 * IQ injection test for the iCeSugar Pro.
 * Runs on the PlutoSky Linux filesystem - no Python required.
 *
 * Usage: ./test_icesugar [null|full|tone|longtone|sine|sweep|noise|fm|slowfull|slowtone]
 */

#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define SPI_BASE   0x7C440000
#define SPI_RANGE  0x1000

#define SRR    0x40
#define SPICR  0x60
#define SPISR  0x64
#define SPIDTR 0x68
#define SPIDRR 0x6C
#define SPISSR 0x70

#define SPICR_SPE       0x002
#define SPICR_MASTER    0x004
#define SPICR_CPOL      0x008
#define SPICR_CPHA      0x010
#define SPICR_TXRST     0x020
#define SPICR_RXRST     0x040
#define SPICR_MANUAL_SS 0x080
#define SPICR_INHIBIT   0x100

#define SPISR_TX_FULL  0x08
#define SPISR_TX_EMPTY 0x04

#define N_SAMPLES 10000

static volatile uint32_t *spi;

static void spi_wr(int off, uint32_t val) { spi[off / 4] = val; }
static uint32_t spi_rd(int off)           { return spi[off / 4]; }

static void spi_init(void)
{
    spi_wr(SRR, 0x0000000A);
    spi_wr(SPICR, SPICR_INHIBIT | SPICR_MANUAL_SS | SPICR_RXRST | SPICR_TXRST |
                  SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
    spi_wr(SPISSR, 0xFFFFFFFF);
    spi_wr(SPICR, SPICR_MANUAL_SS | SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
}

static void send_iq_word(int16_t i_val, int16_t q_val)
{
    uint32_t word = (((uint32_t)(uint16_t)i_val) << 16) | (uint16_t)q_val;
    uint8_t bytes[4] = {
        (word >> 24) & 0xFF,
        (word >> 16) & 0xFF,
        (word >>  8) & 0xFF,
         word        & 0xFF,
    };

    spi_wr(SPISSR, 0xFFFFFFFE);  /* assert CS */
    for (int b = 0; b < 4; b++) {
        while (spi_rd(SPISR) & SPISR_TX_FULL)
            ;
        spi_wr(SPIDTR, bytes[b]);
    }
    while (!(spi_rd(SPISR) & SPISR_TX_EMPTY))
        ;
    /* TX_EMPTY fires when FIFO is empty but the last byte is still in the
     * shift register. SCK=12.5 MHz -> 8 bits = 640 ns. Wait 2 us. */
    usleep(2);
    spi_wr(SPISSR, 0xFFFFFFFF);  /* deassert CS - iCeSugar latches IQ */
}

static void run_null(void)
{
    puts("Test: null  - expect black waterfall");
    for (int i = 0; i < N_SAMPLES; i++)
        send_iq_word(0, 0);
}

static void run_full(void)
{
    puts("Test: full  - expect solid red waterfall (max magnitude)");
    for (int i = 0; i < N_SAMPLES; i++)
        send_iq_word(32767, 0);
}

static void run_tone(void)
{
    puts("Test: tone  - f=Fs/8=125kHz, expect uniform waterfall (stub), single bin at 32 with real FFT");
    double omega = M_PI / 4.0;
    for (int k = 0; k < N_SAMPLES; k++) {
        int16_t i_val = (int16_t)(32767.0 * cos(omega * k));
        int16_t q_val = (int16_t)(32767.0 * sin(omega * k));
        send_iq_word(i_val, q_val);
    }
}

static void run_longtone(void)
{
    const int frames = 4000;
    double omega = M_PI / 4.0;

    puts("Test: longtone - longer Fs/8 tone for waterfall visibility");
    for (int frame = 0; frame < frames; frame++) {
        for (int k = 0; k < 256; k++) {
            int16_t i_val = (int16_t)(32767.0 * cos(omega * k));
            int16_t q_val = (int16_t)(32767.0 * sin(omega * k));
            send_iq_word(i_val, q_val);
        }
    }
}

static void run_sine(void)
{
    const int points = 240;
    const int hold_frames = 24;
    const double center_bin = 64.0;
    const double span_bins = 40.0;
    const double amp = 24000.0;

    puts("Test: sine - held integer-bin tone draws a sine path on the waterfall");
    for (int p = 0; p < points; p++) {
        double t = (double)p / (double)points;
        int bin = (int)(center_bin + span_bins * sin(2.0 * M_PI * t) + 0.5);
        double omega = 2.0 * M_PI * (double)bin / 256.0;

        for (int frame = 0; frame < hold_frames; frame++) {
            for (int k = 0; k < 256; k++) {
                int16_t i_val = (int16_t)(amp * cos(omega * k));
                int16_t q_val = (int16_t)(amp * sin(omega * k));
                send_iq_word(i_val, q_val);
            }
        }
    }
}

static void run_sweep(void)
{
    static const int bins[] = { 4, 8, 16, 32, 48, 64, 96, 128, 160, 192, 224 };
    const int n_bins = (int)(sizeof(bins) / sizeof(bins[0]));
    const int frames_per_bin = 1200;

    puts("Test: sweep - coherent FFT tones, expect moving vertical waterfall stripes");
    for (int b = 0; b < n_bins; b++) {
        double omega = 2.0 * M_PI * (double)bins[b] / 256.0;
        for (int frame = 0; frame < frames_per_bin; frame++) {
            for (int k = 0; k < 256; k++) {
                int16_t i_val = (int16_t)(32767.0 * cos(omega * k));
                int16_t q_val = (int16_t)(32767.0 * sin(omega * k));
                send_iq_word(i_val, q_val);
            }
        }
    }
}

static uint32_t prng_next(uint32_t *state)
{
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void run_noise(void)
{
    const int frames = 12000;
    uint32_t state = 0x12345678;

    puts("Test: noise - wideband IQ, expect filled continuous waterfall");
    for (int frame = 0; frame < frames; frame++) {
        for (int k = 0; k < 256; k++) {
            uint32_t a = prng_next(&state);
            uint32_t b = prng_next(&state);
            int16_t i_val = (int16_t)(a >> 16);
            int16_t q_val = (int16_t)(b >> 16);
            send_iq_word(i_val, q_val);
        }
    }
}

static void run_fm(void)
{
    const int frames = 12000;
    const double amp = 20000.0;
    const double sample_rate = 1000000.0;
    const double audio_hz = 1000.0;
    const double dev_hz = 25000.0;
    double phase = 0.0;
    double audio_phase = 0.0;
    double audio_step = 2.0 * M_PI * audio_hz / sample_rate;

    puts("Test: fm - narrow synthetic FM IQ, expect centered FM-like waterfall and active demod path");
    for (int frame = 0; frame < frames; frame++) {
        for (int k = 0; k < 256; k++) {
            double audio = sin(audio_phase);
            double freq = dev_hz * audio;
            phase += 2.0 * M_PI * freq / sample_rate;
            audio_phase += audio_step;

            if (phase > M_PI)
                phase -= 2.0 * M_PI;
            if (audio_phase > M_PI)
                audio_phase -= 2.0 * M_PI;

            int16_t i_val = (int16_t)(amp * cos(phase));
            int16_t q_val = (int16_t)(amp * sin(phase));
            send_iq_word(i_val, q_val);
        }
    }
}

static void run_slowfull(void)
{
    puts("Test: slowfull - repeated full-scale I words for visual SPI debug");
    for (int i = 0; i < 200000; i++) {
        send_iq_word(32767, 0);
        usleep(50);
    }
}

static void run_slowtone(void)
{
    puts("Test: slowtone - repeated Fs/8 tone for visual SPI debug");
    double omega = M_PI / 4.0;
    for (int k = 0; k < 200000; k++) {
        int16_t i_val = (int16_t)(32767.0 * cos(omega * k));
        int16_t q_val = (int16_t)(32767.0 * sin(omega * k));
        send_iq_word(i_val, q_val);
        usleep(50);
    }
}

int main(int argc, char *argv[])
{
    const char *test = (argc > 1) ? argv[1] : "full";

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    spi = mmap(NULL, SPI_RANGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SPI_BASE);
    if (spi == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    spi_init();

    if      (strcmp(test, "null") == 0) run_null();
    else if (strcmp(test, "full") == 0) run_full();
    else if (strcmp(test, "tone") == 0) run_tone();
    else if (strcmp(test, "longtone") == 0) run_longtone();
    else if (strcmp(test, "sine") == 0) run_sine();
    else if (strcmp(test, "sweep") == 0) run_sweep();
    else if (strcmp(test, "noise") == 0) run_noise();
    else if (strcmp(test, "fm") == 0) run_fm();
    else if (strcmp(test, "slowfull") == 0) run_slowfull();
    else if (strcmp(test, "slowtone") == 0) run_slowtone();
    else { fprintf(stderr, "unknown test: %s (use null|full|tone|longtone|sine|sweep|noise|fm|slowfull|slowtone)\n", test); }

    puts("Done.");
    munmap((void *)spi, SPI_RANGE);
    close(fd);
    return 0;
}
