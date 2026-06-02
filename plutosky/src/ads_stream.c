/*
 * ads_stream.c -- ADS-B / Mode S decoder for PlutoSky 7020
 *
 * Signal chain:
 *   PlutoSky ADC (1090 MHz, 2 Msps, int16 IQ, fast-attack AGC)
 *   -> magnitude: |I| + |Q| per sample
 *   -> Mode S preamble search (8 us, four pulses at 0/1/3.5/4.5 us)
 *   -> PPM bit decode (2 samples/bit, first half > second half = 1)
 *   -> CRC-24 validate (ICAO poly 0xFFF409)
 *   -> DF field parse (top 5 bits of byte 0)
 *   -> DF17/18 ME decode: TC 1-4 ident, TC 9-18/20-22 position, TC 19 velocity
 *   -> aircraft table (keyed by ICAO, TTL 60 s)
 *   -> periodic stdout report every 5 s
 *
 * Build:  make ads-build   (in plutosky/)
 * Deploy: make ads-deploy
 * Run:    make ads-run
 *
 * Caveats:
 *   - CPR position uses global airborne decode; requires even+odd frames
 *     from the same aircraft within 10 s of each other.
 *   - Gillham-coded altitude (Q bit = 0) is not decoded; shows as '?'.
 *   - Surface position (TC 5-8) is not decoded.
 *   - No MLAT.
 */

#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define SAMPLE_RATE_DEFAULT  2000000UL   /* 2 Msps -> 0.5 us/sample */
#define CENTER_FREQ_HZ       1090000000UL
#define RF_BW_HZ             2500000UL

/*
 * At 2 Msps (0.5 us/sample):
 *   preamble = 16 samples (8 us)
 *   1 data bit = 2 samples (1 us)
 */
#define PREAMBLE_LEN     16
#define SAMPLES_PER_BIT  2
#define MSG_SHORT_BITS   56
#define MSG_LONG_BITS    112
#define MSG_SHORT_SAMP   (MSG_SHORT_BITS * SAMPLES_PER_BIT)
#define MSG_LONG_SAMP    (MSG_LONG_BITS  * SAMPLES_PER_BIT)

/*
 * Overlap kept between chunks: large enough to hold one complete long message
 * starting at the last sample of the non-overlap region.
 */
#define OVERLAP_SAMP     (PREAMBLE_LEN + MSG_LONG_SAMP)   /* 240 */

/* IIO read chunk size in sample pairs */
#define IIO_CHUNK        262144   /* 256 k pairs */

#define MAG_BUF_SIZE     (IIO_CHUNK + OVERLAP_SAMP)

/* CRC-24 generator (ICAO Annex 10, Vol III) */
#define CRC24_POLY       0xFFF409U

/* Aircraft table */
#define MAX_AIRCRAFT     512
#define AC_TTL_S         60

/* Print interval */
#define PRINT_INTERVAL_S 5

/* ------------------------------------------------------------------ */
/* Aircraft state                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t icao;
    char     callsign[9];
    int32_t  altitude;    /* feet; INT32_MIN = unknown */
    double   lat, lon;
    int32_t  speed;       /* knots; -1 = unknown */
    int32_t  heading;     /* 0-359; -1 = unknown */
    int32_t  vert_rate;   /* fpm; INT32_MIN = unknown */
    int      have_pos;
    /* CPR state: [0]=even, [1]=odd */
    uint32_t cpr_lat[2], cpr_lon[2];
    int      cpr_valid[2];
    time_t   cpr_time[2];
    time_t   last_seen;
    uint64_t msg_count;
} aircraft_t;

static aircraft_t g_ac[MAX_AIRCRAFT];
static int        g_ac_count = 0;

/* ------------------------------------------------------------------ */
/* Statistics                                                          */
/* ------------------------------------------------------------------ */

static uint64_t g_frames_total = 0;
static uint64_t g_crc_ok       = 0;
static uint64_t g_df17_ok      = 0;

/* ------------------------------------------------------------------ */
/* Signal handling                                                     */
/* ------------------------------------------------------------------ */

static volatile int keep_running = 1;
static void sigint_handler(int s) { (void)s; keep_running = 0; }

/* ------------------------------------------------------------------ */
/* IIO helpers                                                         */
/* ------------------------------------------------------------------ */

static int write_attr(const char *path, const char *val)
{
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(val, f);
    fclose(f);
    return 0;
}

static const char *find_iio_device(const char *name)
{
    static char path[256];
    for (int i = 0; i < 16; i++) {
        char tmp[256];
        snprintf(tmp, sizeof(tmp),
                 "/sys/bus/iio/devices/iio:device%d/name", i);
        FILE *f = fopen(tmp, "r");
        if (!f) continue;
        char buf[64] = {0};
        fgets(buf, sizeof(buf), f);
        fclose(f);
        buf[strcspn(buf, "\n")] = 0;
        if (strcmp(buf, name) == 0) {
            snprintf(path, sizeof(path),
                     "/sys/bus/iio/devices/iio:device%d", i);
            return path;
        }
    }
    return NULL;
}

static int configure_rx(unsigned long freq_hz, unsigned long rate,
                        unsigned long bw, const char *gain_mode)
{
    const char *dev = find_iio_device("ad9361-phy");
    if (!dev) {
        fprintf(stderr, "ad9361-phy not found\n");
        return -1;
    }

    char path[512], val[64];

#define WI(attr, v) do { \
    snprintf(path, sizeof(path), "%s/" attr, dev); \
    snprintf(val,  sizeof(val),  "%lu", (unsigned long)(v)); \
    if (write_attr(path, val)) { \
        fprintf(stderr, "write failed: %s\n", path); return -1; \
    } \
} while (0)

#define WS(attr, v) do { \
    snprintf(path, sizeof(path), "%s/" attr, dev); \
    if (write_attr(path, (v))) { \
        fprintf(stderr, "write failed: %s\n", path); return -1; \
    } \
} while (0)

    WI("out_altvoltage0_RX_LO_frequency", freq_hz);
    WI("in_voltage_sampling_frequency",   rate);
    WI("in_voltage_rf_bandwidth",         bw);
    WS("in_voltage0_gain_control_mode",   gain_mode);
    WS("in_voltage1_gain_control_mode",   gain_mode);

#undef WI
#undef WS
    return 0;
}

/* popen iio_readdev; outputs interleaved int16 I,Q pairs */
static FILE *open_iio_readdev(int buf_samp)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd),
             "iio_readdev -b %d cf-ad9361-lpc voltage0 voltage1 2>/dev/null",
             buf_samp);
    return popen(cmd, "r");
}

/* ------------------------------------------------------------------ */
/* CRC-24                                                              */
/* ------------------------------------------------------------------ */

static uint32_t crc24(const uint8_t *msg, int len)
{
    uint32_t crc = 0;
    for (int i = 0; i < len; i++) {
        crc ^= (uint32_t)msg[i] << 16;
        for (int b = 0; b < 8; b++) {
            crc <<= 1;
            if (crc & 0x1000000U)
                crc ^= CRC24_POLY;
        }
    }
    return crc & 0xFFFFFFU;
}

/* ------------------------------------------------------------------ */
/* Magnitude                                                           */
/* ------------------------------------------------------------------ */

/* L1 norm: fast, avoids sqrt, sufficient for threshold comparisons */
static inline uint32_t iq_mag(int16_t i, int16_t q)
{
    int32_t ai = (i < 0) ? -(int32_t)i : (int32_t)i;
    int32_t aq = (q < 0) ? -(int32_t)q : (int32_t)q;
    return (uint32_t)(ai + aq);
}

/* ------------------------------------------------------------------ */
/* Preamble detection                                                  */
/* ------------------------------------------------------------------ */

/*
 * Mode S preamble at 2 Msps (0.5 us/sample):
 *
 *   sample  0: HIGH  (0.0 us -- pulse 1)
 *   sample  1: LOW   (0.5 us)
 *   sample  2: HIGH  (1.0 us -- pulse 2)
 *   samples 3-6: LOW (1.5 - 3.0 us)
 *   sample  7: HIGH  (3.5 us -- pulse 3)
 *   sample  8: LOW   (4.0 us)
 *   sample  9: HIGH  (4.5 us -- pulse 4)
 *   samples 10-15: LOW (guard before data)
 *
 * Caller must ensure mag[] has at least OVERLAP_SAMP elements beyond this index.
 */
static int detect_preamble(const uint32_t *mag)
{
    uint32_t p0 = mag[0], p2 = mag[2], p7 = mag[7], p9 = mag[9];

    /* all four peaks must clear the average valley level */
    uint32_t valley = (mag[1] + mag[3] + mag[4] + mag[6] + mag[8] + mag[10]) / 6 + 1;
    if (p0 < valley || p2 < valley || p7 < valley || p9 < valley)
        return 0;

    /* individual valley checks between adjacent peaks */
    if (mag[1] >= p0 || mag[1] >= p2)   return 0;  /* between pulse 1 and 2 */
    if (mag[3] >= p2 || mag[6] >= p7)   return 0;  /* edges of the gap */
    if (mag[8] >= p7 || mag[8] >= p9)   return 0;  /* between pulse 3 and 4 */
    if (mag[10] >= p9)                   return 0;  /* guard after pulse 4 */

    return 1;
}

/* ------------------------------------------------------------------ */
/* Bit extraction                                                      */
/* ------------------------------------------------------------------ */

/* Unpack PPM bits from mag[] into out[] MSB-first; mag[] starts at preamble. */
static void extract_msg(const uint32_t *mag, uint8_t *out, int n_bits)
{
    memset(out, 0, (size_t)((n_bits + 7) / 8));
    for (int i = 0; i < n_bits; i++) {
        int s = PREAMBLE_LEN + i * SAMPLES_PER_BIT;
        if (mag[s] > mag[s + 1])
            out[i / 8] |= (uint8_t)(0x80u >> (i % 8));
    }
}

/* ------------------------------------------------------------------ */
/* Aircraft table                                                      */
/* ------------------------------------------------------------------ */

static aircraft_t *ac_find_or_add(uint32_t icao)
{
    for (int i = 0; i < g_ac_count; i++)
        if (g_ac[i].icao == icao) return &g_ac[i];

    aircraft_t *a;
    if (g_ac_count < MAX_AIRCRAFT) {
        a = &g_ac[g_ac_count++];
    } else {
        /* evict least-recently-seen entry */
        int idx = 0;
        for (int i = 1; i < g_ac_count; i++)
            if (g_ac[i].last_seen < g_ac[idx].last_seen) idx = i;
        a = &g_ac[idx];
    }

    memset(a, 0, sizeof(*a));
    a->icao      = icao;
    a->altitude  = INT32_MIN;
    a->speed     = -1;
    a->heading   = -1;
    a->vert_rate = INT32_MIN;
    return a;
}

static void ac_expire(void)
{
    time_t now = time(NULL);
    int i = 0;
    while (i < g_ac_count) {
        if (now - g_ac[i].last_seen > AC_TTL_S)
            g_ac[i] = g_ac[--g_ac_count];
        else
            i++;
    }
}

/* ------------------------------------------------------------------ */
/* ADS-B ME field decoders                                             */
/* ------------------------------------------------------------------ */

/* TC 1-4: Aircraft Identification
 * Charset index -> ASCII; '#' marks invalid/unused slots. */
static const char id_charset[] =
    "#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######";

static void decode_ident(aircraft_t *a, const uint8_t *me)
{
    /* me[1..6]: 8 x 6-bit characters, MSB first */
    char cs[9];
    cs[0] = id_charset[(me[1] >> 2) & 0x3F];
    cs[1] = id_charset[((me[1] & 0x03) << 4) | (me[2] >> 4)];
    cs[2] = id_charset[((me[2] & 0x0F) << 2) | (me[3] >> 6)];
    cs[3] = id_charset[ me[3] & 0x3F];
    cs[4] = id_charset[(me[4] >> 2) & 0x3F];
    cs[5] = id_charset[((me[4] & 0x03) << 4) | (me[5] >> 4)];
    cs[6] = id_charset[((me[5] & 0x0F) << 2) | (me[6] >> 6)];
    cs[7] = id_charset[ me[6] & 0x3F];
    cs[8] = 0;
    for (int i = 7; i >= 0 && cs[i] == ' '; i--) cs[i] = 0;
    memcpy(a->callsign, cs, sizeof(a->callsign));
}

/* TC 9-18, 20-22: Airborne Position
 *
 * ME layout (56 bits):
 *   [55:51] TC   [50:48] SS   [47] NIC-B   [46:35] AC12
 *   [34] T   [33] F(CPR odd)   [32:16] CPR lat   [15:0] CPR lon
 *
 * In bytes (me[0] = bits 55:48, etc.):
 *   AC12  = me[1][7:0] + me[2][7:4]          (12 bits)
 *   F     = me[2][2]
 *   rlat  = me[2][1:0] + me[3][7:0] + me[4][7:1]   (17 bits)
 *   rlon  = me[4][0]   + me[5][7:0] + me[6][7:0]   (17 bits)
 */
static void decode_airborne_pos(aircraft_t *a, const uint8_t *me)
{
    /* Altitude: AC12 Q-bit form only */
    int ac12 = ((int)(me[1] & 0xFF) << 4) | ((int)(me[2] >> 4) & 0x0F);
    if (ac12) {
        int q = (ac12 >> 4) & 1;
        if (q) {
            int n = ((ac12 & 0xFE0) >> 1) | (ac12 & 0x00F);
            a->altitude = n * 25 - 1000;
        }
    }

    int odd = (me[2] >> 2) & 1;
    uint32_t rlat = ((uint32_t)(me[2] & 0x03) << 15) |
                    ((uint32_t) me[3]           << 7)  |
                    ((uint32_t) me[4]           >> 1);
    uint32_t rlon = ((uint32_t)(me[4] & 0x01) << 16) |
                    ((uint32_t) me[5]           << 8)  |
                     (uint32_t) me[6];

    a->cpr_lat[odd]   = rlat;
    a->cpr_lon[odd]   = rlon;
    a->cpr_valid[odd] = 1;
    a->cpr_time[odd]  = time(NULL);

    if (!a->cpr_valid[0] || !a->cpr_valid[1]) return;

    /* Discard stale frame pairs (aircraft may have moved) */
    long dt = (long)a->cpr_time[0] - (long)a->cpr_time[1];
    if (dt < 0) dt = -dt;
    if (dt > 10) return;

    /* Global airborne CPR decode (ICAO Doc 9684 Appendix C) */
    double yz = (double)a->cpr_lat[0] / 131072.0;   /* even */
    double yo = (double)a->cpr_lat[1] / 131072.0;   /* odd */

    int j = (int)floor(59.0 * yz - 60.0 * yo + 0.5);

    double lat_e = (360.0 / 60.0) * (((j % 60)  + 60)  % 60  + yz);
    double lat_o = (360.0 / 59.0) * (((j % 59)  + 59)  % 59  + yo);

    if (lat_e >= 270.0) lat_e -= 360.0;
    if (lat_o >= 270.0) lat_o -= 360.0;

    double lat = odd ? lat_o : lat_e;
    a->lat = lat;

    /* NL(lat): longitude zone count */
    double nl;
    double alat = lat < 0.0 ? -lat : lat;
    if (alat < 1e-6) {
        nl = 59.0;
    } else if (alat > 87.0) {
        nl = 1.0;
    } else {
        double c = cos(lat * (M_PI / 180.0));
        nl = floor(2.0 * M_PI / acos(1.0 - (1.0 - cos(M_PI / 30.0)) / (c * c)));
    }

    double xz  = (double)a->cpr_lon[0] / 131072.0;
    double xo  = (double)a->cpr_lon[1] / 131072.0;
    double nl_o = (nl > 1.0) ? nl - 1.0 : 1.0;
    double ni   = odd ? nl_o : nl;
    if (ni < 1.0) ni = 1.0;

    int m = (int)floor(xz * nl_o - xo * nl + 0.5);
    double dlon = 360.0 / ni;
    int ni_i = (int)ni;
    double lon = dlon * (((m % ni_i) + ni_i) % ni_i + (odd ? xo : xz));
    if (lon >= 180.0) lon -= 360.0;

    a->lon      = lon;
    a->have_pos = 1;
}

/* TC 19: Airborne Velocity (subtypes 1 and 2 -- ground speed)
 *
 * ME layout:
 *   me[0]: TC + ST
 *   me[1]: ICF[7] IFR[6] NAC[5:3] DEW[2] VEW[9:8]
 *   me[2]: VEW[7:0]
 *   me[3]: DNS[7] VNS[9:3]... wait, VNS is 10 bits:
 *           DNS[7] VNS[6:0] from me[3], VNS[2:0] from me[4][7:5]
 *   me[4]: VNS lower 3 bits [7:5], VrSrc[4], Svr[3], Vr[2:0]
 *   me[5]: Vr[8:2], reserved[1:0]   -- Vr is 9 bits total
 */
static void decode_airborne_vel(aircraft_t *a, const uint8_t *me)
{
    int st = (me[1] >> 3) & 0x07;   /* subtype from me[0] bits 2:0 */

    /* re-read ST from me[0] (TC occupies bits 7:3) */
    st = me[0] & 0x07;
    if (st != 1 && st != 2) return;   /* only ground-speed subtypes */

    int dew = (me[1] >> 2) & 1;
    int vew = ((me[1] & 0x03) << 8) | me[2];
    int dns = (me[3] >> 7) & 1;
    int vns = ((me[3] & 0x7F) << 3) | (me[4] >> 5);

    if (vew != 0 && vns != 0) {
        double vx = dew ? -(double)(vew - 1) : (double)(vew - 1);  /* E positive */
        double vy = dns ? -(double)(vns - 1) : (double)(vns - 1);  /* N positive */
        a->speed = (int32_t)round(sqrt(vx * vx + vy * vy));
        double hdg = atan2(vx, vy) * (180.0 / M_PI);
        if (hdg < 0.0) hdg += 360.0;
        a->heading = (int32_t)round(hdg);
    }

    int svr = (me[4] >> 3) & 1;
    int vr  = ((me[4] & 0x07) << 6) | (me[5] >> 2);
    if (vr != 0)
        a->vert_rate = (int32_t)((svr ? -(vr - 1) : (vr - 1)) * 64);
}

/* ------------------------------------------------------------------ */
/* Message processing                                                  */
/* ------------------------------------------------------------------ */

static void process_message(const uint8_t *msg, int nbytes)
{
    g_frames_total++;
    if (nbytes < 7) return;

    int df   = (msg[0] >> 3) & 0x1F;
    int elen = (df == 17 || df == 18 || df == 19 || df == 21) ? 14 : 7;
    if (nbytes < elen) return;

    uint32_t crc_calc = crc24(msg, elen - 3);
    uint32_t crc_msg  = ((uint32_t)msg[elen - 3] << 16) |
                        ((uint32_t)msg[elen - 2] << 8)  |
                         (uint32_t)msg[elen - 1];

    /* For DF17/18 the parity field is a pure CRC (no address overlay) */
    if (df == 17 || df == 18) {
        if (crc_calc != crc_msg) return;
    } else {
        return;  /* cannot validate without interrogator ID */
    }

    g_crc_ok++;
    g_df17_ok++;

    uint32_t icao = ((uint32_t)msg[1] << 16) |
                    ((uint32_t)msg[2] << 8)  |
                     (uint32_t)msg[3];

    aircraft_t *a = ac_find_or_add(icao);
    a->last_seen  = time(NULL);
    a->msg_count++;

    const uint8_t *me = &msg[4];
    int tc = (me[0] >> 3) & 0x1F;

    if      (tc >= 1  && tc <= 4)  decode_ident(a, me);
    else if (tc >= 9  && tc <= 18) decode_airborne_pos(a, me);
    else if (tc >= 20 && tc <= 22) decode_airborne_pos(a, me);
    else if (tc == 19)             decode_airborne_vel(a, me);
}

/* ------------------------------------------------------------------ */
/* Magnitude buffer and scanner                                        */
/* ------------------------------------------------------------------ */

static uint32_t g_magbuf[MAG_BUF_SIZE];
static int      g_maglen = 0;

/*
 * Scan g_magbuf[0..g_maglen-1] for Mode S messages.
 * Only considers preambles at indices < g_maglen - OVERLAP_SAMP so that
 * any message starting there is guaranteed to fit within the buffer.
 * After scanning, keeps the last OVERLAP_SAMP samples for the next chunk.
 */
static void scan_magnitude(void)
{
    int safe_end = g_maglen - OVERLAP_SAMP;
    if (safe_end <= 0) return;

    for (int i = 0; i < safe_end; i++) {
        if (!detect_preamble(&g_magbuf[i])) continue;

        /* Determine message length from DF (first 5 data bits) */
        int b[5];
        for (int k = 0; k < 5; k++) {
            int s = i + PREAMBLE_LEN + k * SAMPLES_PER_BIT;
            b[k] = (g_magbuf[s] > g_magbuf[s + 1]) ? 1 : 0;
        }
        int df    = (b[0]<<4)|(b[1]<<3)|(b[2]<<2)|(b[3]<<1)|b[4];
        int nbits = (df==17||df==18||df==19||df==21) ? MSG_LONG_BITS : MSG_SHORT_BITS;

        uint8_t msg[14];
        extract_msg(&g_magbuf[i], msg, nbits);
        process_message(msg, nbits / 8);

        /* Jump past the decoded message (-1 for the loop's i++) */
        i += PREAMBLE_LEN + nbits * SAMPLES_PER_BIT - 1;
    }

    /* Keep last OVERLAP_SAMP samples as overlap for the next chunk */
    int keep = (g_maglen > OVERLAP_SAMP) ? OVERLAP_SAMP : g_maglen;
    if (g_maglen > OVERLAP_SAMP)
        memmove(g_magbuf, &g_magbuf[g_maglen - keep],
                (size_t)keep * sizeof(uint32_t));
    g_maglen = keep;
}

/* ------------------------------------------------------------------ */
/* Display                                                             */
/* ------------------------------------------------------------------ */

static void print_table(void)
{
    ac_expire();
    time_t now = time(NULL);

    printf("\033[2J\033[H");
    printf("ADS-B -- %s", ctime(&now));
    printf("Frames seen: %llu   CRC OK: %llu   DF17/18: %llu   Aircraft tracked: %d\n\n",
           (unsigned long long)g_frames_total,
           (unsigned long long)g_crc_ok,
           (unsigned long long)g_df17_ok,
           g_ac_count);

    if (g_ac_count == 0) {
        printf("No aircraft yet.\n");
        fflush(stdout);
        return;
    }

    printf("%-6s  %-8s  %7s  %9s  %10s  %5s  %3s  %6s  %5s\n",
           "ICAO", "Call", "Alt(ft)", "Lat", "Lon", "Spd", "Hdg", "VRate", "Msgs");
    printf("------  --------  -------  ---------  ----------  -----  ---  ------  -----\n");

    for (int i = 0; i < g_ac_count; i++) {
        aircraft_t *a = &g_ac[i];
        if (now - a->last_seen > AC_TTL_S) continue;

        char alt[12], lat[12], lon[12], spd[8], hdg[6], vr[10];

        if (a->altitude != INT32_MIN)
            snprintf(alt, sizeof(alt), "%d",  a->altitude);
        else
            snprintf(alt, sizeof(alt), "?");

        if (a->have_pos) {
            snprintf(lat, sizeof(lat), "%.4f", a->lat);
            snprintf(lon, sizeof(lon), "%.4f", a->lon);
        } else {
            snprintf(lat, sizeof(lat), "?");
            snprintf(lon, sizeof(lon), "?");
        }

        if (a->speed >= 0) snprintf(spd, sizeof(spd), "%d",  a->speed);
        else               snprintf(spd, sizeof(spd), "?");

        if (a->heading >= 0) snprintf(hdg, sizeof(hdg), "%d",  a->heading);
        else                 snprintf(hdg, sizeof(hdg), "?");

        if (a->vert_rate != INT32_MIN)
            snprintf(vr, sizeof(vr), "%+d", a->vert_rate);
        else
            snprintf(vr, sizeof(vr), "?");

        printf("%06X  %-8s  %7s  %9s  %10s  %5s  %3s  %6s  %5llu\n",
               a->icao,
               a->callsign[0] ? a->callsign : "?",
               alt, lat, lon, spd, hdg, vr,
               (unsigned long long)a->msg_count);
    }
    fflush(stdout);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  --freq-mhz F    center frequency MHz (default 1090.0)\n"
            "  --rate R        sample rate Hz (default 2000000)\n"
            "  --gain-mode M   fast_attack | slow_attack | manual (default fast_attack)\n"
            "  --duration S    run S seconds then exit; 0 = forever (default 0)\n"
            "  --dry-run       configure IIO only, do not stream\n",
            prog);
}

int main(int argc, char **argv)
{
    double        freq_mhz  = (double)CENTER_FREQ_HZ / 1e6;
    unsigned long rate      = SAMPLE_RATE_DEFAULT;
    const char   *gain_mode = "fast_attack";
    int           duration  = 0;
    int           dry_run   = 0;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--freq-mhz")  && i+1 < argc) freq_mhz  = atof(argv[++i]);
        else if (!strcmp(argv[i], "--rate")       && i+1 < argc) rate      = (unsigned long)atol(argv[++i]);
        else if (!strcmp(argv[i], "--gain-mode")  && i+1 < argc) gain_mode = argv[++i];
        else if (!strcmp(argv[i], "--duration")   && i+1 < argc) duration  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dry-run"))                   dry_run   = 1;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(argv[0]); return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            usage(argv[0]); return 1;
        }
    }

    signal(SIGINT,  sigint_handler);
    signal(SIGTERM, sigint_handler);

    unsigned long freq_hz = (unsigned long)(freq_mhz * 1e6 + 0.5);
    fprintf(stderr, "ads_stream: %.3f MHz  %lu sps  gain=%s\n",
            freq_mhz, rate, gain_mode);

    if (configure_rx(freq_hz, rate, RF_BW_HZ, gain_mode)) {
        fprintf(stderr, "IIO configure failed\n");
        return 1;
    }

    if (dry_run) {
        fprintf(stderr, "dry-run: IIO configured OK\n");
        return 0;
    }

    FILE *iio = open_iio_readdev(IIO_CHUNK);
    if (!iio) {
        fprintf(stderr, "iio_readdev open failed\n");
        return 1;
    }

    /* heap-allocate the raw read buffer (IIO_CHUNK * 2 int16 = 1 MB) */
    int16_t *raw = malloc((size_t)IIO_CHUNK * 2 * sizeof(int16_t));
    if (!raw) {
        fprintf(stderr, "malloc failed\n");
        pclose(iio);
        return 1;
    }

    time_t t_start     = time(NULL);
    time_t t_last_print = t_start - PRINT_INTERVAL_S;  /* print on first chunk */

    while (keep_running) {
        if (duration > 0 && (int)(time(NULL) - t_start) >= duration) break;

        size_t nr = fread(raw, sizeof(int16_t) * 2, (size_t)IIO_CHUNK, iio);
        if (nr == 0) {
            if (feof(iio)) break;
            continue;
        }

        /* compute magnitude and append to sliding buffer */
        for (size_t k = 0; k < nr; k++)
            g_magbuf[g_maglen++] = iq_mag(raw[k * 2], raw[k * 2 + 1]);

        scan_magnitude();

        time_t now = time(NULL);
        if (now - t_last_print >= PRINT_INTERVAL_S) {
            print_table();
            t_last_print = now;
        }
    }

    pclose(iio);
    free(raw);
    print_table();
    return 0;
}
