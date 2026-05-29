/*
 * PlutoSky to iCeSugar Pro IQ streamer.
 *
 * FM mode configures the AD9361, reads IQ from iio_readdev, and streams
 * packed 16-bit I/Q words to the JP5 AXI SPI controller.
 */

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
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

#define IIO_NAME_PHY "ad9361-phy"
#define IIO_NAME_RX  "cf-ad9361-lpc"

enum stream_mode {
    MODE_FM = 0,
    MODE_SYNTH_FM,
    MODE_SYNTH_TONE,
    MODE_LINK_TEST,
};

struct stream_cfg {
    enum stream_mode mode;
    double freq_mhz;
    unsigned sample_rate;
    unsigned adc_rate;
    unsigned rf_bw;
    unsigned iio_buf;
    unsigned chunk_samples;
    unsigned duration_sec;
    unsigned synth_amp;
    unsigned synth_dev_hz;
    unsigned iq_shift;
    unsigned dc_shift;
    unsigned word_delay_us;
    int dry_run;
    int synth_source;
    int per_word_cs;
    int dc_block;
};

static volatile uint32_t *spi;
static volatile sig_atomic_t keep_running = 1;

static void on_signal(int sig)
{
    (void)sig;
    keep_running = 0;
}

static void spi_wr(int off, uint32_t val)
{
    spi[off / 4] = val;
}

static uint32_t spi_rd(int off)
{
    return spi[off / 4];
}

static void spi_init(void)
{
    spi_wr(SRR, 0x0000000A);
    spi_wr(SPICR, SPICR_INHIBIT | SPICR_MANUAL_SS | SPICR_RXRST | SPICR_TXRST |
                  SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
    spi_wr(SPISSR, 0xFFFFFFFF);
    spi_wr(SPICR, SPICR_MANUAL_SS | SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
}

static void spi_select(void)
{
    spi_wr(SPISSR, 0xFFFFFFFE);
}

static void spi_deselect(void)
{
    while (!(spi_rd(SPISR) & SPISR_TX_EMPTY))
        ;
    usleep(2);
    spi_wr(SPISSR, 0xFFFFFFFF);
}

static void spi_send_byte(uint8_t byte)
{
    while (spi_rd(SPISR) & SPISR_TX_FULL)
        ;
    spi_wr(SPIDTR, byte);
}

static void spi_send_iq(int16_t i_val, int16_t q_val)
{
    uint32_t word = (((uint32_t)(uint16_t)i_val) << 16) | (uint16_t)q_val;

    spi_send_byte((word >> 24) & 0xff);
    spi_send_byte((word >> 16) & 0xff);
    spi_send_byte((word >>  8) & 0xff);
    spi_send_byte(word & 0xff);
}

static void spi_send_word32(uint32_t word)
{
    spi_send_byte((word >> 24) & 0xff);
    spi_send_byte((word >> 16) & 0xff);
    spi_send_byte((word >>  8) & 0xff);
    spi_send_byte(word & 0xff);
}

static int find_iio_device(const char *name, char *path, size_t path_len)
{
    char dev_path[128];
    char name_path[160];
    char found[128];

    for (int i = 0; i < 16; i++) {
        snprintf(dev_path, sizeof(dev_path), "/sys/bus/iio/devices/iio:device%d", i);
        snprintf(name_path, sizeof(name_path), "%s/name", dev_path);

        FILE *f = fopen(name_path, "r");
        if (!f)
            continue;

        if (fgets(found, sizeof(found), f)) {
            found[strcspn(found, "\r\n")] = '\0';
            if (strcmp(found, name) == 0) {
                fclose(f);
                snprintf(path, path_len, "%s", dev_path);
                return 0;
            }
        }

        fclose(f);
    }

    return -1;
}

static int write_attr(const char *dev, const char *attr, unsigned long long value)
{
    char path[256];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dev, attr);
    f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }

    fprintf(f, "%llu\n", value);
    if (fclose(f) != 0) {
        fprintf(stderr, "write %s: %s\n", path, strerror(errno));
        return -1;
    }

    return 0;
}

static unsigned read_attr_u32(const char *dev, const char *attr)
{
    char path[256];
    unsigned val = 0;
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dev, attr);
    f = fopen(path, "r");
    if (!f)
        return 0;

    (void)fscanf(f, "%u", &val);
    fclose(f);
    return val;
}

static int configure_fm(const struct stream_cfg *cfg, unsigned *actual_rate)
{
    char phy[128];
    unsigned long long freq_hz = (unsigned long long)(cfg->freq_mhz * 1000000.0 + 0.5);
    static const unsigned fallback_rates[] = {
        2500000,
        2083333,
        2000000,
        1536000,
        1250000,
        1000000,
        833333
    };
    const unsigned *rates = fallback_rates;
    unsigned one_rate = cfg->adc_rate;
    int n_rates = (int)(sizeof(fallback_rates) / sizeof(fallback_rates[0]));
    int configured = 0;

    if (find_iio_device(IIO_NAME_PHY, phy, sizeof(phy)) != 0) {
        fprintf(stderr, "IIO device '%s' not found\n", IIO_NAME_PHY);
        return -1;
    }

    if (write_attr(phy, "out_altvoltage0_RX_LO_frequency", freq_hz) != 0)
        return -1;

    if (cfg->adc_rate != 0) {
        rates = &one_rate;
        n_rates = 1;
    }

    for (int i = 0; i < n_rates; i++) {
        if (write_attr(phy, "in_voltage_sampling_frequency", rates[i]) == 0) {
            configured = 1;
            break;
        }
        fprintf(stderr, "sample_rate %u rejected, trying next\n", rates[i]);
    }

    if (!configured) {
        fprintf(stderr, "no requested sample rate was accepted\n");
        return -1;
    }

    if (write_attr(phy, "in_voltage_rf_bandwidth", cfg->rf_bw) != 0)
        return -1;

    *actual_rate = read_attr_u32(phy, "in_voltage_sampling_frequency");
    if (*actual_rate == 0)
        *actual_rate = rates[0];

    printf("FM configured: %.4f MHz, sample_rate=%u Hz, rf_bw=%u Hz\n",
           cfg->freq_mhz, *actual_rate, cfg->rf_bw);
    return 0;
}

static FILE *open_iio_readdev(const struct stream_cfg *cfg, unsigned actual_rate)
{
    char cmd[256];
    unsigned long long samples = 0;

    if (cfg->duration_sec)
        samples = (unsigned long long)actual_rate * cfg->duration_sec;

    if (samples) {
        snprintf(cmd, sizeof(cmd),
                 "iio_readdev -u local: -b %u -s %llu %s voltage0 voltage1",
                 cfg->iio_buf, samples, IIO_NAME_RX);
    } else {
        snprintf(cmd, sizeof(cmd),
                 "iio_readdev -u local: -b %u %s voltage0 voltage1",
                 cfg->iio_buf, IIO_NAME_RX);
    }

    printf("Starting: %s\n", cmd);
    return popen(cmd, "r");
}

static int16_t scale_iio_sample(int32_t x, unsigned shift)
{
    int32_t y = x;

    if (shift > 15)
        shift = 15;
    y <<= shift;

    if (y > 32767)
        y = 32767;
    if (y < -32768)
        y = -32768;

    return (int16_t)y;
}

static int stream_iq(FILE *src, const struct stream_cfg *cfg, unsigned actual_rate)
{
    int16_t *buf;
    size_t words_per_chunk = (size_t)cfg->chunk_samples * 2;
    unsigned long long total = 0;
    unsigned long long input_total = 0;
    unsigned phase = 0;
    unsigned out_rate = cfg->sample_rate;
    unsigned in_rate = actual_rate;
    int32_t dc_i = 0;
    int32_t dc_q = 0;
    struct timeval t0, t1;

    buf = malloc(words_per_chunk * sizeof(int16_t));
    if (!buf) {
        perror("malloc");
        return -1;
    }

    gettimeofday(&t0, NULL);

    printf("Live stream: output_rate=%u Hz, chunk=%u, iq_shift=%u, dc_block=%s\n",
           out_rate ? out_rate : in_rate, cfg->chunk_samples, cfg->iq_shift,
           cfg->dc_block ? "on" : "off");

    while (keep_running) {
        size_t got = fread(buf, sizeof(int16_t), words_per_chunk, src);
        if (got == 0)
            break;

        got &= ~(size_t)1;
        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_select();

        for (size_t n = 0; n < got; n += 2) {
            int32_t raw_i = buf[n];
            int32_t raw_q = buf[n + 1];
            int16_t i_val;
            int16_t q_val;
            int send_sample = 1;

            input_total++;

            if (cfg->dc_block) {
                dc_i += (raw_i - dc_i) >> cfg->dc_shift;
                dc_q += (raw_q - dc_q) >> cfg->dc_shift;
                raw_i -= dc_i;
                raw_q -= dc_q;
            }

            i_val = scale_iio_sample(raw_i, cfg->iq_shift);
            q_val = scale_iio_sample(raw_q, cfg->iq_shift);

            if (out_rate != 0 && in_rate != 0 && out_rate < in_rate) {
                phase += out_rate;
                if (phase >= in_rate) {
                    phase -= in_rate;
                    send_sample = 1;
                } else {
                    send_sample = 0;
                }
            }

            if (send_sample && !cfg->dry_run && cfg->per_word_cs)
                spi_select();
            if (send_sample && !cfg->dry_run)
                spi_send_iq(i_val, q_val);
            if (send_sample && !cfg->dry_run && cfg->per_word_cs)
                spi_deselect();
            if (send_sample && cfg->word_delay_us)
                usleep(cfg->word_delay_us);
            if (send_sample)
                total++;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_deselect();

        if (got < words_per_chunk)
            break;
    }

    gettimeofday(&t1, NULL);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_usec - t0.tv_usec) / 1000000.0;
    double rate = elapsed > 0.0 ? (double)total / elapsed : 0.0;

    printf("Read %llu IQ samples, streamed %llu in %.3f s (%.0f samples/s)\n",
           input_total, total, elapsed, rate);

    free(buf);
    return 0;
}

static int stream_synth_fm(const struct stream_cfg *cfg)
{
    unsigned rate = cfg->sample_rate ? cfg->sample_rate : 1000000;
    unsigned long long total = 0;
    double phase = 0.0;
    double audio_phase = 0.0;
    double audio_step = 2.0 * M_PI * 1000.0 / (double)rate;
    double amp = cfg->synth_amp;
    double dev_hz = cfg->synth_dev_hz;
    struct timeval t0, t1;

    gettimeofday(&t0, NULL);

    while (keep_running) {
        unsigned chunk = cfg->chunk_samples;
        struct timeval now;

        if (cfg->duration_sec) {
            gettimeofday(&now, NULL);
            if ((unsigned)(now.tv_sec - t0.tv_sec) >= cfg->duration_sec)
                break;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_select();

        for (unsigned n = 0; n < chunk; n++) {
            double audio = sin(audio_phase);
            double freq = dev_hz * audio;
            int16_t i_val, q_val;

            phase += 2.0 * M_PI * freq / (double)rate;
            audio_phase += audio_step;

            if (phase > M_PI)
                phase -= 2.0 * M_PI;
            if (phase < -M_PI)
                phase += 2.0 * M_PI;
            if (audio_phase > M_PI)
                audio_phase -= 2.0 * M_PI;

            i_val = (int16_t)(amp * cos(phase));
            q_val = (int16_t)(amp * sin(phase));

            if (!cfg->dry_run && cfg->per_word_cs)
                spi_select();
            if (!cfg->dry_run)
                spi_send_iq(i_val, q_val);
            if (!cfg->dry_run && cfg->per_word_cs)
                spi_deselect();
            if (cfg->word_delay_us)
                usleep(cfg->word_delay_us);
            total++;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_deselect();
    }

    gettimeofday(&t1, NULL);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_usec - t0.tv_usec) / 1000000.0;
    double out_rate = elapsed > 0.0 ? (double)total / elapsed : 0.0;

    printf("Synthetic FM streamed %llu IQ samples in %.3f s (%.0f samples/s)\n",
           total, elapsed, out_rate);
    return 0;
}

static int stream_synth_tone(const struct stream_cfg *cfg)
{
    unsigned rate = cfg->sample_rate ? cfg->sample_rate : 390625;
    unsigned long long total = 0;
    double phase = 0.0;
    double step = 2.0 * M_PI * 32000.0 / (double)rate;
    double amp = cfg->synth_amp;
    struct timeval t0, t1;

    gettimeofday(&t0, NULL);

    while (keep_running) {
        unsigned chunk = cfg->chunk_samples;
        struct timeval now;

        if (cfg->duration_sec) {
            gettimeofday(&now, NULL);
            if ((unsigned)(now.tv_sec - t0.tv_sec) >= cfg->duration_sec)
                break;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_select();

        for (unsigned n = 0; n < chunk; n++) {
            int16_t i_val = (int16_t)(amp * cos(phase));
            int16_t q_val = (int16_t)(amp * sin(phase));

            phase += step;
            if (phase > M_PI)
                phase -= 2.0 * M_PI;

            if (!cfg->dry_run && cfg->per_word_cs)
                spi_select();
            if (!cfg->dry_run)
                spi_send_iq(i_val, q_val);
            if (!cfg->dry_run && cfg->per_word_cs)
                spi_deselect();
            if (cfg->word_delay_us)
                usleep(cfg->word_delay_us);
            total++;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_deselect();
    }

    gettimeofday(&t1, NULL);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_usec - t0.tv_usec) / 1000000.0;
    double out_rate = elapsed > 0.0 ? (double)total / elapsed : 0.0;

    printf("Synthetic tone streamed %llu IQ samples in %.3f s (%.0f samples/s)\n",
           total, elapsed, out_rate);
    return 0;
}

/*
 * Signal-integrity / link test: stream an incrementing 32-bit counter over the
 * same JP5 SPI path the IQ stream uses, framed identically (CS per chunk, or
 * per word with --per-word-cs). The iCESugar link_test_top bitstream checks each
 * received word is prev+1 and counts errors. Compare error counts before/after
 * SI changes (slew/drive, grounding, series R) or while flexing the wires.
 */
static int stream_link_test(const struct stream_cfg *cfg)
{
    uint32_t counter = 0;
    unsigned long long total = 0;
    struct timeval t0, t1;

    gettimeofday(&t0, NULL);

    printf("Link test: incrementing 32-bit counter, chunk=%u, per_word_cs=%d\n",
           cfg->chunk_samples, cfg->per_word_cs);

    while (keep_running) {
        unsigned chunk = cfg->chunk_samples;
        struct timeval now;

        if (cfg->duration_sec) {
            gettimeofday(&now, NULL);
            if ((unsigned)(now.tv_sec - t0.tv_sec) >= cfg->duration_sec)
                break;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_select();

        for (unsigned n = 0; n < chunk; n++) {
            if (!cfg->dry_run && cfg->per_word_cs)
                spi_select();
            if (!cfg->dry_run)
                spi_send_word32(counter);
            if (!cfg->dry_run && cfg->per_word_cs)
                spi_deselect();
            if (cfg->word_delay_us)
                usleep(cfg->word_delay_us);
            counter++;
            total++;
        }

        if (!cfg->dry_run && !cfg->per_word_cs)
            spi_deselect();
    }

    gettimeofday(&t1, NULL);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_usec - t0.tv_usec) / 1000000.0;
    double rate = elapsed > 0.0 ? (double)total / elapsed : 0.0;

    printf("Link test sent %llu words in %.3f s (%.0f words/s)\n",
           total, elapsed, rate);
    return 0;
}

static void usage(const char *prog)
{
    printf("Usage: %s [options]\n", prog);
    printf("  --mode fm              Stream FM IQ (default)\n");
    printf("  --mode synth-fm        Stream generated FM IQ over the same SPI path\n");
    printf("  --mode synth-tone      Stream a strong generated IQ tone\n");
    printf("  --mode link-test       Stream an incrementing 32-bit counter (SI/link test)\n");
    printf("  --freq-mhz FREQ        RF frequency in MHz (default 95.1)\n");
    printf("  --adc-rate HZ          AD9361 sample rate; 0 tries fallbacks (default 0)\n");
    printf("  --rate HZ              Output IQ rate to FPGA; 0 uses ADC rate (default 1000000)\n");
    printf("  --rf-bw HZ             AD9361 RF bandwidth (default 1000000)\n");
    printf("  --duration SEC         Run length; 0 means until Ctrl-C (default 0)\n");
    printf("  --iio-buf N            iio_readdev buffer size (default 8192)\n");
    printf("  --chunk-samples N      SPI CS chunk size in IQ samples (default 1024)\n");
    printf("  --iq-shift N           Live IQ left shift before SPI (default 4)\n");
    printf("  --dc-shift N           Live IQ DC block shift (default 12)\n");
    printf("  --no-dc-block          Disable live IQ DC blocking\n");
    printf("  --synth-amp N          Synthetic IQ amplitude (default 30000)\n");
    printf("  --synth-dev HZ         Synthetic FM deviation (default 50000)\n");
    printf("  --per-word-cs          Toggle CS around each IQ word\n");
    printf("  --word-delay-us N      Delay after each IQ word (default 0)\n");
    printf("  --dry-run              Read IQ and measure rate without driving SPI\n");
}

static int parse_args(int argc, char **argv, struct stream_cfg *cfg)
{
    cfg->mode = MODE_FM;
    cfg->freq_mhz = 95.1;
    cfg->sample_rate = 1000000;
    cfg->adc_rate = 0;
    cfg->rf_bw = 1000000;
    cfg->iio_buf = 8192;
    cfg->chunk_samples = 1024;
    cfg->duration_sec = 0;
    cfg->synth_amp = 30000;
    cfg->synth_dev_hz = 50000;
    cfg->iq_shift = 4;
    cfg->dc_shift = 12;
    cfg->word_delay_us = 0;
    cfg->dry_run = 0;
    cfg->per_word_cs = 0;
    cfg->dc_block = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            i++;
            if (strcmp(argv[i], "fm") == 0)
                cfg->mode = MODE_FM;
            else if (strcmp(argv[i], "synth-fm") == 0)
                cfg->mode = MODE_SYNTH_FM;
            else if (strcmp(argv[i], "synth-tone") == 0)
                cfg->mode = MODE_SYNTH_TONE;
            else if (strcmp(argv[i], "link-test") == 0)
                cfg->mode = MODE_LINK_TEST;
            else {
                fprintf(stderr, "unsupported mode: %s\n", argv[i]);
                return -1;
            }
        } else if (strcmp(argv[i], "--freq-mhz") == 0 && i + 1 < argc) {
            cfg->freq_mhz = atof(argv[++i]);
        } else if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc) {
            cfg->sample_rate = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--adc-rate") == 0 && i + 1 < argc) {
            cfg->adc_rate = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--rf-bw") == 0 && i + 1 < argc) {
            cfg->rf_bw = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            cfg->duration_sec = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--iio-buf") == 0 && i + 1 < argc) {
            cfg->iio_buf = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--chunk-samples") == 0 && i + 1 < argc) {
            cfg->chunk_samples = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--iq-shift") == 0 && i + 1 < argc) {
            cfg->iq_shift = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--dc-shift") == 0 && i + 1 < argc) {
            cfg->dc_shift = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--no-dc-block") == 0) {
            cfg->dc_block = 0;
        } else if (strcmp(argv[i], "--synth-amp") == 0 && i + 1 < argc) {
            cfg->synth_amp = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--synth-dev") == 0 && i + 1 < argc) {
            cfg->synth_dev_hz = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--word-delay-us") == 0 && i + 1 < argc) {
            cfg->word_delay_us = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            cfg->dry_run = 1;
        } else if (strcmp(argv[i], "--per-word-cs") == 0) {
            cfg->per_word_cs = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            exit(0);
        } else {
            fprintf(stderr, "unknown or incomplete option: %s\n", argv[i]);
            return -1;
        }
    }

    if (cfg->chunk_samples == 0)
        cfg->chunk_samples = 1;
    if (cfg->iio_buf == 0)
        cfg->iio_buf = 1024;
    if (cfg->synth_amp > 32767)
        cfg->synth_amp = 32767;
    if (cfg->synth_dev_hz == 0)
        cfg->synth_dev_hz = 1;
    if (cfg->dc_shift == 0)
        cfg->dc_shift = 1;
    if (cfg->dc_shift > 20)
        cfg->dc_shift = 20;

    return 0;
}

int main(int argc, char **argv)
{
    struct stream_cfg cfg;
    unsigned actual_rate = 0;
    int fd = -1;
    FILE *iq = NULL;
    int ret = 1;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (parse_args(argc, argv, &cfg) != 0) {
        usage(argv[0]);
        return 1;
    }

    if (cfg.mode == MODE_FM) {
        if (configure_fm(&cfg, &actual_rate) != 0)
            return 1;
    } else if (cfg.mode == MODE_SYNTH_FM || cfg.mode == MODE_SYNTH_TONE ||
               cfg.mode == MODE_LINK_TEST) {
        actual_rate = cfg.sample_rate ? cfg.sample_rate : 1000000;
        printf("Synthetic source: output_rate=%u Hz\n", actual_rate);
    } else {
        fprintf(stderr, "mode not implemented\n");
        return 1;
    }

    if (!cfg.dry_run) {
        fd = open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) {
            perror("open /dev/mem");
            return 1;
        }

        spi = mmap(NULL, SPI_RANGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SPI_BASE);
        if (spi == MAP_FAILED) {
            perror("mmap SPI");
            close(fd);
            return 1;
        }

        spi_init();
    }

    if (cfg.mode == MODE_SYNTH_FM) {
        ret = stream_synth_fm(&cfg) == 0 ? 0 : 1;
    } else if (cfg.mode == MODE_SYNTH_TONE) {
        ret = stream_synth_tone(&cfg) == 0 ? 0 : 1;
    } else if (cfg.mode == MODE_LINK_TEST) {
        ret = stream_link_test(&cfg) == 0 ? 0 : 1;
    } else {
        iq = open_iio_readdev(&cfg, actual_rate);
        if (!iq) {
            perror("popen iio_readdev");
            goto out;
        }

        ret = stream_iq(iq, &cfg, actual_rate) == 0 ? 0 : 1;
    }

out:
    if (iq)
        pclose(iq);
    if (!cfg.dry_run && spi && spi != MAP_FAILED) {
        spi_deselect();
        munmap((void *)spi, SPI_RANGE);
    }
    if (fd >= 0)
        close(fd);

    return ret;
}
