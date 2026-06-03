/*
 * PlutoSky SDR receiver - combined entry point.
 *
 * Orchestrates three receiver modes:
 *   fm   - stream raw IQ TLV packets to iCeSugar for demod/waterfall/audio
 *   goes - GOES-18 LRIT decode on Pluto, send VCDU frames via TLV to iCeSugar
 *   adsb - ADS-B Mode S decode on Pluto, send aircraft list via TLV to iCeSugar
 *
 * Active mode and FM frequency can be changed at runtime via OP_RADIO_COMMAND
 * frames on the JP5 SPI MISO backchannel from the iCeSugar Pro ECP5.
 *
 * Build with -DSDR_MAIN_BUILD so ads_stream.c and goes_stream.c suppress their
 * standalone main() functions.
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
#include <sys/time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/* AXI Quad SPI register map (JP5 connector, base 0x7C440000)         */
/* ------------------------------------------------------------------ */

#define SPI_BASE             0x7C440000UL
#define SPI_RANGE            0x1000

#define REG_SRR              0x40
#define REG_SPICR            0x60
#define REG_SPISR            0x64
#define REG_SPIDTR           0x68
#define REG_SPIDRR           0x6C
#define REG_SPISSR           0x70

#define SPICR_SPE            0x002
#define SPICR_MASTER         0x004
#define SPICR_CPOL           0x008
#define SPICR_CPHA           0x010
#define SPICR_TXRST          0x020
#define SPICR_RXRST          0x040
#define SPICR_MANUAL_SS      0x080
#define SPICR_INHIBIT        0x100

#define SPISR_RX_EMPTY       0x01
#define SPISR_TX_FULL        0x08
#define SPISR_TX_EMPTY       0x04

/* ------------------------------------------------------------------ */
/* TLV packet types (shared with iCeSugar ECP5 tlv_demux)             */
/* ------------------------------------------------------------------ */

#define TLV_IQ               0x00
#define TLV_IMAGE_ROW        0x01
#define TLV_OBJECT_LIST      0x02
#define TLV_BACKCHANNEL_POLL 0xFF

/* ------------------------------------------------------------------ */
/* CS timing spin counts                                               */
/* ------------------------------------------------------------------ */

#define CS_LOW_DRAIN_SPINS   8000u
#define CS_HIGH_GAP_SPINS     400u

/* ------------------------------------------------------------------ */
/* Wire protocol - 0xA5 backchannel from ECP5                         */
/* ------------------------------------------------------------------ */

#define WIRE_MAGIC           0xA5u
#define OP_RADIO_COMMAND     0x06u

#define CMD_SET_MODE         0x01u
#define CMD_SET_VOLUME       0x02u
#define CMD_SET_FREQ         0x03u

#define MODE_VAL_FM          0u
#define MODE_VAL_GOES        2u
#define MODE_VAL_ADSB        3u

/* ------------------------------------------------------------------ */
/* IIO device names                                                    */
/* ------------------------------------------------------------------ */

#define IIO_NAME_PHY         "ad9361-phy"
#define IIO_NAME_RX          "cf-ad9361-lpc"

/* ------------------------------------------------------------------ */
/* Per-mode RF defaults                                                */
/* ------------------------------------------------------------------ */

#define FM_DEFAULT_FREQ_HZ   95100000UL
#define FM_ADC_RATE          2604170UL
#define FM_OUTPUT_RATE       260417UL
#define FM_RF_BW             1000000UL
#define FM_PACKET_SAMPLES    4096u
#define FM_IIO_BUF           8192u
#define FM_IQ_SHIFT          4u
#define FM_DC_SHIFT          12u

#define GOES_FREQ_HZ         1694100000UL
#define GOES_SAMPLE_RATE     1000000UL
#define GOES_RF_BW           500000UL
#define GOES_IIO_BUF         8192u

#define ADSB_FREQ_HZ         1090000000UL
#define ADSB_SAMPLE_RATE     2000000UL
#define ADSB_RF_BW           2500000UL
#define ADSB_IIO_BUF         262144u

/* ------------------------------------------------------------------ */
/* Mode enum                                                           */
/* ------------------------------------------------------------------ */

typedef enum {
    APP_MODE_FM   = 0,
    APP_MODE_GOES = 1,
    APP_MODE_ADSB = 2,
} app_mode_t;

/* ------------------------------------------------------------------ */
/* Global state                                                        */
/* ------------------------------------------------------------------ */

static volatile uint32_t    *g_spi         = NULL;
static volatile sig_atomic_t g_keep_running = 1;
static app_mode_t            g_mode         = APP_MODE_FM;
static uint32_t              g_fm_freq_hz   = FM_DEFAULT_FREQ_HZ;
static volatile int          g_mode_changed = 0;
static unsigned              g_spi_tx_count = 0;

/* ------------------------------------------------------------------ */
/* Signal handling                                                     */
/* ------------------------------------------------------------------ */

static void on_signal(int sig)
{
    (void)sig;
    g_keep_running = 0;
}

/* ------------------------------------------------------------------ */
/* SPI register access                                                 */
/* ------------------------------------------------------------------ */

static void spi_wr(unsigned off, uint32_t val)
{
    g_spi[off / 4] = val;
}

static uint32_t spi_rd(unsigned off)
{
    return g_spi[off / 4];
}

static void backchannel_drain(void);

static void spi_init(void)
{
    spi_wr(REG_SRR,   0x0000000Au);
    spi_wr(REG_SPICR, SPICR_INHIBIT | SPICR_MANUAL_SS | SPICR_RXRST | SPICR_TXRST |
                      SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
    spi_wr(REG_SPISSR, 0xFFFFFFFFu);
    spi_wr(REG_SPICR,  SPICR_MANUAL_SS | SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE);
}

static void spi_select(void)
{
    spi_wr(REG_SPISSR, 0xFFFFFFFEu);
}

static void spi_deselect(void)
{
    while (!(spi_rd(REG_SPISR) & SPISR_TX_EMPTY))
        ;
    for (volatile unsigned i = 0; i < CS_LOW_DRAIN_SPINS; i++)
        ;
    spi_wr(REG_SPISSR, 0xFFFFFFFFu);
    for (volatile unsigned i = 0; i < CS_HIGH_GAP_SPINS; i++)
        ;
}

static void spi_send_byte(uint8_t b)
{
    while (spi_rd(REG_SPISR) & SPISR_TX_FULL)
        ;
    spi_wr(REG_SPIDTR, b);
    g_spi_tx_count++;
}

static void spi_send_iq(int16_t i_val, int16_t q_val)
{
    uint32_t w = (((uint32_t)(uint16_t)i_val) << 16) | (uint16_t)q_val;
    spi_send_byte((uint8_t)((w >> 24) & 0xffu));
    spi_send_byte((uint8_t)((w >> 16) & 0xffu));
    spi_send_byte((uint8_t)((w >>  8) & 0xffu));
    spi_send_byte((uint8_t)( w        & 0xffu));
}

/* Generic TLV packet sender used as callback by adsb_run / goes_run. */
static void spi_send_tlv(uint8_t type, const uint8_t *payload, uint16_t len)
{
    spi_select();
    spi_send_byte(type);
    spi_send_byte((uint8_t)((len >> 8) & 0xffu));
    spi_send_byte((uint8_t)(len & 0xffu));
    for (uint16_t i = 0; i < len; i++)
        spi_send_byte(payload[i]);
    spi_deselect();
}

static void spi_send_tlv_iq_packet(const int16_t *iq, unsigned samples)
{
    unsigned len = samples * 4u;
    spi_select();
    spi_send_byte(TLV_IQ);
    spi_send_byte((uint8_t)((len >> 8) & 0xffu));
    spi_send_byte((uint8_t)(len & 0xffu));
    for (unsigned n = 0; n < samples; n++)
        spi_send_iq(iq[2 * n], iq[2 * n + 1]);
    spi_deselect();
}

/* ------------------------------------------------------------------ */
/* Backchannel: drain AXI SPI RX FIFO and parse 0xA5 frames           */
/* ------------------------------------------------------------------ */

/*
 * Frame format from spi_backchannel.sv:
 *   [0xA5] [opcode] [len_lo] [len_hi] [payload...] [crc_lo] [crc_hi]
 * CRC-16/CCITT covers [opcode .. last payload byte], init=0xFFFF, poly=0x1021.
 * For OP_RADIO_COMMAND: len=5, payload=[cmd:u8][arg:u32_LE].
 */

#define BCHAN_MAX_PAYLOAD 32

typedef enum {
    BS_MAGIC = 0,
    BS_OPCODE,
    BS_LEN_LO,
    BS_LEN_HI,
    BS_PAYLOAD,
    BS_CRC_LO,
    BS_CRC_HI,
} bchan_state_t;

static bchan_state_t bc_state   = BS_MAGIC;
static uint8_t       bc_opcode  = 0;
static uint16_t      bc_len     = 0;
static uint16_t      bc_filled  = 0;
static uint8_t       bc_payload[BCHAN_MAX_PAYLOAD];
static uint8_t       bc_crc_lo  = 0;
static unsigned      bc_rx_bytes = 0;
static unsigned      bc_nonzero_bytes = 0;
static unsigned      bc_magic_bytes = 0;
static unsigned      bc_frames_ok = 0;
static unsigned      bc_frames_crc_bad = 0;
static unsigned      bc_frames_len_bad = 0;
static unsigned      bc_last_report_tx = 0;
static uint8_t       bc_last_cmd = 0;
static uint32_t      bc_last_arg = 0;

static uint16_t bchan_crc16(const uint8_t *data, uint16_t len)
{
    uint16_t crc = 0xFFFFu;
    for (uint16_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; b++)
            crc = (crc & 0x8000u)
                  ? (uint16_t)((crc << 1) ^ 0x1021u)
                  : (uint16_t)(crc << 1);
    }
    return crc;
}

static void bchan_dispatch(void)
{
    if (bc_opcode != OP_RADIO_COMMAND || bc_len < 5)
        return;

    uint8_t  cmd = bc_payload[0];
    uint32_t arg = (uint32_t)bc_payload[1]
                 | ((uint32_t)bc_payload[2] << 8)
                 | ((uint32_t)bc_payload[3] << 16)
                 | ((uint32_t)bc_payload[4] << 24);
    static uint8_t  have_cmd[256] = {0};
    static uint32_t last_arg_by_cmd[256] = {0};

    bc_last_cmd = cmd;
    bc_last_arg = arg;

    if (have_cmd[cmd] && arg == last_arg_by_cmd[cmd])
        return;
    have_cmd[cmd] = 1;
    last_arg_by_cmd[cmd] = arg;

    switch (cmd) {
    case CMD_SET_MODE:
        switch (arg & 0xFFu) {
        case MODE_VAL_FM:
            if (g_mode != APP_MODE_FM) {
                g_mode = APP_MODE_FM;
                g_mode_changed = 1;
                fprintf(stderr, "[bchan] mode -> FM\n");
            }
            break;
        case MODE_VAL_GOES:
            if (g_mode != APP_MODE_GOES) {
                g_mode = APP_MODE_GOES;
                g_mode_changed = 1;
                fprintf(stderr, "[bchan] mode -> GOES\n");
            }
            break;
        case MODE_VAL_ADSB:
            if (g_mode != APP_MODE_ADSB) {
                g_mode = APP_MODE_ADSB;
                g_mode_changed = 1;
                fprintf(stderr, "[bchan] mode -> ADS-B\n");
            }
            break;
        default:
            break;
        }
        break;

    case CMD_SET_FREQ:
        if (arg > 0) {
            g_fm_freq_hz = arg;
            if (g_mode == APP_MODE_FM) {
                g_mode_changed = 1;
                fprintf(stderr, "[bchan] freq -> %u Hz\n", arg);
            }
        }
        break;

    case CMD_SET_VOLUME:
        /* volume is managed locally by ECP5; log and ignore */
        fprintf(stderr, "[bchan] volume=%u mute=%u (handled by ECP5)\n",
                (unsigned)(arg & 0xffu), (unsigned)((arg >> 8) & 1u));
        break;

    default:
        break;
    }
}

static void bchan_push_byte(uint8_t b)
{
    bc_rx_bytes++;
    if (b != 0)
        bc_nonzero_bytes++;
    if (b == WIRE_MAGIC)
        bc_magic_bytes++;

    switch (bc_state) {
    case BS_MAGIC:
        if (b == WIRE_MAGIC)
            bc_state = BS_OPCODE;
        break;

    case BS_OPCODE:
        bc_opcode = b;
        bc_state  = BS_LEN_LO;
        break;

    case BS_LEN_LO:
        bc_len   = b;
        bc_state = BS_LEN_HI;
        break;

    case BS_LEN_HI:
        bc_len  |= (uint16_t)b << 8;
        bc_filled = 0;
        if (bc_len == 0)
            bc_state = BS_CRC_LO;
        else if (bc_len > BCHAN_MAX_PAYLOAD) {
            bc_frames_len_bad++;
            bc_state = BS_MAGIC;  /* oversized frame, re-sync */
        } else {
            bc_state = BS_PAYLOAD;
        }
        break;

    case BS_PAYLOAD:
        bc_payload[bc_filled++] = b;
        if (bc_filled == bc_len)
            bc_state = BS_CRC_LO;
        break;

    case BS_CRC_LO:
        bc_crc_lo = b;
        bc_state  = BS_CRC_HI;
        break;

    case BS_CRC_HI: {
        uint16_t rx_crc   = (uint16_t)bc_crc_lo | ((uint16_t)b << 8);
        uint8_t  crc_in[BCHAN_MAX_PAYLOAD + 3];
        crc_in[0] = bc_opcode;
        crc_in[1] = (uint8_t)(bc_len & 0xffu);
        crc_in[2] = (uint8_t)((bc_len >> 8) & 0xffu);
        memcpy(&crc_in[3], bc_payload, bc_filled);
        uint16_t calc_crc = bchan_crc16(crc_in, (uint16_t)(3u + bc_filled));
        if (rx_crc == calc_crc) {
            bc_frames_ok++;
            bchan_dispatch();
        } else {
            bc_frames_crc_bad++;
        }
        bc_state = BS_MAGIC;
        break;
    }
    }
}

static void backchannel_report_if_due(void)
{
    if (g_spi_tx_count - bc_last_report_tx < 250000u)
        return;
    bc_last_report_tx = g_spi_tx_count;
    fprintf(stderr,
            "[bchan] stats bytes=%u nonzero=%u magic=%u ok=%u crc_bad=%u len_bad=%u last_cmd=0x%02x last_arg=%u\n",
            bc_rx_bytes, bc_nonzero_bytes, bc_magic_bytes,
            bc_frames_ok, bc_frames_crc_bad, bc_frames_len_bad,
            bc_last_cmd, bc_last_arg);
}

/* Drain the RX FIFO into the backchannel parser. Called after each SPI transaction. */
static void backchannel_drain(void)
{
    if (!g_spi)
        return;
    while (!(spi_rd(REG_SPISR) & SPISR_RX_EMPTY))
        bchan_push_byte((uint8_t)(spi_rd(REG_SPIDRR) & 0xFFu));
}

static void backchannel_poll(void)
{
    if (!g_spi)
        return;

    backchannel_drain();

    spi_select();
    spi_send_byte(TLV_BACKCHANNEL_POLL);
    spi_send_byte(0);
    spi_send_byte(8);
    for (unsigned i = 0; i < 8; i++)
        spi_send_byte(0);
    spi_deselect();
    backchannel_drain();
    backchannel_report_if_due();
}

static void pace_samples(unsigned long long total, unsigned rate, const struct timeval *t0)
{
    if (rate == 0 || total == 0)
        return;

    for (;;) {
        struct timeval now;
        gettimeofday(&now, NULL);

        double target_s = (double)total / (double)rate;
        double elapsed_s = (double)(now.tv_sec - t0->tv_sec) +
                           (double)(now.tv_usec - t0->tv_usec) / 1000000.0;
        double sleep_s = target_s - elapsed_s;

        if (sleep_s <= 0.001)
            break;

        if (sleep_s > 0.020)
            sleep_s = 0.020;
        usleep((useconds_t)(sleep_s * 1000000.0));
    }
}

/* ------------------------------------------------------------------ */
/* IIO helpers                                                         */
/* ------------------------------------------------------------------ */

static int find_iio_device(const char *name, char *path, size_t path_len)
{
    char dev_path[128], name_path[160], found[128];

    for (int i = 0; i < 16; i++) {
        snprintf(dev_path,  sizeof(dev_path),  "/sys/bus/iio/devices/iio:device%d", i);
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

static int iio_write_u64(const char *dev, const char *attr, unsigned long long val)
{
    char path[256];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dev, attr);
    f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(f, "%llu\n", val);
    if (fclose(f) != 0) {
        fprintf(stderr, "write %s: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

static int iio_write_str(const char *dev, const char *attr, const char *val)
{
    char path[256];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dev, attr);
    f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(f, "%s\n", val);
    if (fclose(f) != 0) {
        fprintf(stderr, "write %s: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

static unsigned iio_read_u32(const char *dev, const char *attr)
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

/* ------------------------------------------------------------------ */
/* AD9361 configuration per mode                                       */
/* ------------------------------------------------------------------ */

static int configure_fm(double freq_mhz, unsigned *actual_rate)
{
    char phy[128];
    static const unsigned fallback_rates[] = {
        FM_ADC_RATE, 2500000, 2083333, 2000000, 1536000, 1250000, 1000000, 833333
    };
    unsigned long long freq_hz = (unsigned long long)(freq_mhz * 1e6 + 0.5);
    int ok = 0;

    if (find_iio_device(IIO_NAME_PHY, phy, sizeof(phy)) != 0) {
        fprintf(stderr, "IIO '%s' not found\n", IIO_NAME_PHY);
        return -1;
    }
    if (iio_write_u64(phy, "out_altvoltage0_RX_LO_frequency", freq_hz) != 0)
        return -1;
    for (unsigned i = 0; i < sizeof(fallback_rates) / sizeof(fallback_rates[0]); i++) {
        if (iio_write_u64(phy, "in_voltage_sampling_frequency", fallback_rates[i]) == 0) {
            ok = 1;
            break;
        }
    }
    if (!ok) {
        fprintf(stderr, "no FM sample rate accepted\n");
        return -1;
    }
    if (iio_write_u64(phy, "in_voltage_rf_bandwidth", FM_RF_BW) != 0)
        return -1;
    iio_write_str(phy, "in_voltage0_gain_control_mode", "slow_attack");
    iio_write_str(phy, "in_voltage1_gain_control_mode", "slow_attack");

    *actual_rate = iio_read_u32(phy, "in_voltage_sampling_frequency");
    if (*actual_rate == 0)
        *actual_rate = 1000000u;

    fprintf(stderr, "FM: %.4f MHz  adc_rate=%u Hz  tlv_rate=%u Hz\n",
            freq_mhz, *actual_rate, (unsigned)FM_OUTPUT_RATE);
    return 0;
}

static int configure_goes(unsigned *actual_rate)
{
    char phy[128];

    if (find_iio_device(IIO_NAME_PHY, phy, sizeof(phy)) != 0) {
        fprintf(stderr, "IIO '%s' not found\n", IIO_NAME_PHY);
        return -1;
    }
    if (iio_write_u64(phy, "out_altvoltage0_RX_LO_frequency", (unsigned long long)GOES_FREQ_HZ) != 0)
        return -1;
    if (iio_write_u64(phy, "in_voltage_sampling_frequency",   (unsigned long long)GOES_SAMPLE_RATE) != 0)
        return -1;
    if (iio_write_u64(phy, "in_voltage_rf_bandwidth",         (unsigned long long)GOES_RF_BW) != 0)
        return -1;
    iio_write_str(phy, "in_voltage0_gain_control_mode", "slow_attack");
    iio_write_str(phy, "in_voltage1_gain_control_mode", "slow_attack");

    *actual_rate = iio_read_u32(phy, "in_voltage_sampling_frequency");
    if (*actual_rate == 0)
        *actual_rate = GOES_SAMPLE_RATE;

    fprintf(stderr, "GOES: 1694.1 MHz  rate=%u Hz\n", *actual_rate);
    return 0;
}

static int configure_adsb(unsigned *actual_rate)
{
    char phy[128];

    if (find_iio_device(IIO_NAME_PHY, phy, sizeof(phy)) != 0) {
        fprintf(stderr, "IIO '%s' not found\n", IIO_NAME_PHY);
        return -1;
    }
    if (iio_write_u64(phy, "out_altvoltage0_RX_LO_frequency", (unsigned long long)ADSB_FREQ_HZ) != 0)
        return -1;
    if (iio_write_u64(phy, "in_voltage_sampling_frequency",   (unsigned long long)ADSB_SAMPLE_RATE) != 0)
        return -1;
    if (iio_write_u64(phy, "in_voltage_rf_bandwidth",         (unsigned long long)ADSB_RF_BW) != 0)
        return -1;
    iio_write_str(phy, "in_voltage0_gain_control_mode", "fast_attack");
    iio_write_str(phy, "in_voltage1_gain_control_mode", "fast_attack");

    *actual_rate = iio_read_u32(phy, "in_voltage_sampling_frequency");
    if (*actual_rate == 0)
        *actual_rate = ADSB_SAMPLE_RATE;

    fprintf(stderr, "ADS-B: 1090.0 MHz  rate=%u Hz\n", *actual_rate);
    return 0;
}

static FILE *open_iio_readdev(unsigned buf_samples)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd),
             "iio_readdev -u local: -b %u %s voltage0 voltage1",
             buf_samples, IIO_NAME_RX);
    fprintf(stderr, "iio: %s\n", cmd);
    return popen(cmd, "r");
}

/* ------------------------------------------------------------------ */
/* FM mode                                                             */
/* ------------------------------------------------------------------ */

static int16_t scale_sample(int32_t x, unsigned shift)
{
    int32_t y = x;
    if (shift > 15u) shift = 15u;
    y <<= shift;
    if (y >  32767) y =  32767;
    if (y < -32768) y = -32768;
    return (int16_t)y;
}

static void run_fm(double freq_mhz)
{
    unsigned  actual_rate = 0;
    FILE     *iq          = NULL;
    int16_t  *buf         = NULL;
    int16_t  *pkt         = NULL;
    unsigned  pkt_used    = 0;
    unsigned  phase       = 0;
    unsigned long long total_out = 0;
    int32_t   dc_i        = 0;
    int32_t   dc_q        = 0;
    unsigned  read_spp    = FM_IIO_BUF;
    unsigned  pkt_spp     = FM_PACKET_SAMPLES;
    struct timeval t0;

    buf = malloc(read_spp * 2u * sizeof(int16_t));
    pkt = malloc(pkt_spp * 2u * sizeof(int16_t));
    if (!buf || !pkt) {
        perror("malloc");
        goto out;
    }

    if (configure_fm(freq_mhz, &actual_rate) != 0)
        goto out;

    iq = open_iio_readdev(FM_IIO_BUF);
    if (!iq) {
        perror("popen iio_readdev");
        goto out;
    }

    g_mode_changed = 0;
    gettimeofday(&t0, NULL);

    while (g_keep_running && !g_mode_changed) {
        size_t got = fread(buf, sizeof(int16_t) * 2u, read_spp, iq);
        if (got == 0)
            break;

        for (size_t n = 0; n < got; n++) {
            int32_t raw_i = buf[2 * n];
            int32_t raw_q = buf[2 * n + 1];

            dc_i += (raw_i - dc_i) >> FM_DC_SHIFT;
            dc_q += (raw_q - dc_q) >> FM_DC_SHIFT;
            raw_i -= dc_i;
            raw_q -= dc_q;

            if (FM_OUTPUT_RATE < actual_rate && actual_rate != 0) {
                phase += (unsigned)FM_OUTPUT_RATE;
                if (phase >= actual_rate) {
                    phase -= actual_rate;
                } else {
                    continue;
                }
            }

            pkt[2 * pkt_used]     = scale_sample(raw_i, FM_IQ_SHIFT);
            pkt[2 * pkt_used + 1] = scale_sample(raw_q, FM_IQ_SHIFT);
            pkt_used++;

            if (pkt_used == pkt_spp) {
                spi_send_tlv_iq_packet(pkt, pkt_used);
                total_out += pkt_used;
                pkt_used = 0;
                backchannel_poll();
                pace_samples(total_out, (unsigned)FM_OUTPUT_RATE, &t0);
            }
        }
    }

    if (pkt_used > 0) {
        spi_send_tlv_iq_packet(pkt, pkt_used);
        backchannel_drain();
    }

out:
    if (iq) pclose(iq);
    free(buf);
    free(pkt);
}

/* ------------------------------------------------------------------ */
/* Forward declarations for mode runners defined in ads_stream.c and  */
/* goes_stream.c. Each is compiled with -DSDR_MAIN_BUILD which        */
/* suppresses those files' standalone main() functions.               */
/* ------------------------------------------------------------------ */

void adsb_run(void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
              void (*drain)(void),
              FILE *iio,
              volatile int *mode_changed,
              volatile sig_atomic_t *keep_running);

void goes_run(void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
              void (*drain)(void),
              FILE *iio,
              unsigned actual_rate,
              volatile int *mode_changed,
              volatile sig_atomic_t *keep_running);

/* ------------------------------------------------------------------ */
/* GOES mode                                                           */
/* ------------------------------------------------------------------ */

static void run_goes(void)
{
    unsigned actual_rate = 0;
    FILE    *iq          = NULL;

    if (configure_goes(&actual_rate) != 0)
        return;

    iq = open_iio_readdev(GOES_IIO_BUF);
    if (!iq) {
        perror("popen iio_readdev");
        return;
    }

    g_mode_changed = 0;
    goes_run(spi_send_tlv, backchannel_poll, iq, actual_rate,
             &g_mode_changed, &g_keep_running);

    pclose(iq);
}

/* ------------------------------------------------------------------ */
/* ADS-B mode                                                          */
/* ------------------------------------------------------------------ */

static void run_adsb(void)
{
    unsigned actual_rate = 0;
    FILE    *iq          = NULL;

    if (configure_adsb(&actual_rate) != 0)
        return;

    iq = open_iio_readdev(ADSB_IIO_BUF);
    if (!iq) {
        perror("popen iio_readdev");
        return;
    }

    (void)actual_rate;
    g_mode_changed = 0;
    adsb_run(spi_send_tlv, backchannel_poll, iq,
             &g_mode_changed, &g_keep_running);

    pclose(iq);
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    printf("Usage: %s [options]\n", prog);
    printf("  --mode <fm|goes|adsb>  initial mode (default: fm)\n");
    printf("  --freq-mhz FREQ        FM center frequency in MHz (default 95.1)\n");
    printf("  --dry-run              configure IIO only, skip SPI init\n");
}

int main(int argc, char **argv)
{
    int    dry_run  = 0;
    double freq_mhz = (double)FM_DEFAULT_FREQ_HZ / 1e6;

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            i++;
            if      (strcmp(argv[i], "fm")   == 0) g_mode = APP_MODE_FM;
            else if (strcmp(argv[i], "goes") == 0) g_mode = APP_MODE_GOES;
            else if (strcmp(argv[i], "adsb") == 0) g_mode = APP_MODE_ADSB;
            else {
                fprintf(stderr, "unknown mode: %s\n", argv[i]);
                usage(argv[0]);
                return 1;
            }
        } else if (strcmp(argv[i], "--freq-mhz") == 0 && i + 1 < argc) {
            freq_mhz     = atof(argv[++i]);
            g_fm_freq_hz = (uint32_t)(freq_mhz * 1e6 + 0.5);
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!dry_run) {
        int fd = open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) {
            perror("open /dev/mem");
            return 1;
        }
        g_spi = mmap(NULL, SPI_RANGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SPI_BASE);
        close(fd);
        if (g_spi == MAP_FAILED) {
            perror("mmap SPI");
            return 1;
        }
        spi_init();
    } else {
        unsigned actual_rate = 0;
        switch (g_mode) {
        case APP_MODE_FM:
            return configure_fm((double)g_fm_freq_hz / 1e6, &actual_rate) == 0 ? 0 : 1;
        case APP_MODE_GOES:
            return configure_goes(&actual_rate) == 0 ? 0 : 1;
        case APP_MODE_ADSB:
            return configure_adsb(&actual_rate) == 0 ? 0 : 1;
        }
    }

    while (g_keep_running) {
        switch (g_mode) {
        case APP_MODE_FM:
            run_fm((double)g_fm_freq_hz / 1e6);
            break;
        case APP_MODE_GOES:
            run_goes();
            break;
        case APP_MODE_ADSB:
            run_adsb();
            break;
        }
    }

    if (g_spi && g_spi != MAP_FAILED)
        munmap((void *)g_spi, SPI_RANGE);

    return 0;
}
