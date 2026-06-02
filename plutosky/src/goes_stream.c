/*
 * GOES-18 LRIT decoder for PlutoSky 7020 SDR.
 *
 * Pipeline: AD9361 IQ capture at 1694.1 MHz / 1 Msps
 *   -> BPSK Costas loop (phase tracking, symbol decisions)
 *   -> Symbol timing (phase accumulator, ~3.4 sps/symbol at 293 ksps symbol rate)
 *   -> Viterbi decoder (rate 1/2, k=7, CCSDS G1=0x79 G2=0x5B)
 *   -> Frame sync (search for ASM 0x1ACFFC1D, also inverted)
 *   -> CCSDS PRBS descrambler (x^8+x^7+x^5+x^3+1, init 0xFF, not applied to ASM)
 *   -> Reed-Solomon RS(255,223) I=4 interleaved, GF(2^8) poly 0x187, FCR=112
 *   -> VCDU header parse (version[2] SCID[10] VCID[6] counter[24])
 *   -> Write 892-byte decoded frames to output file
 *
 * CCSDS parameter notes (verify against NOAA GOES-R PUG Volume 3 and SatDump source
 * before trusting decoded output):
 *   - G1=0x79 (octal 171), G2=0x5B (octal 133) are standard CCSDS convolution.
 *     If frames don't lock, swap G1/G2 or negate the BPSK branch metrics.
 *   - The PRBS descrambler applies after Viterbi and before RS. If RS error counts
 *     are high but sync looks OK, check whether descrambling should be skipped or
 *     whether the PRBS initial state needs to change.
 *   - FCR=112 and primitive poly 0x187 are from the CCSDS RS specification.
 *     Verify against GOES-R PUG Vol 3 Section 3 before declaring output valid.
 *
 * Verification: run SatDump on the same IQ capture and compare VCDU counter
 * values in the output frames against this decoder's output.
 */

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define IIO_NAME_PHY  "ad9361-phy"
#define IIO_NAME_RX   "cf-ad9361-lpc"

/* CCSDS convolution parameters */
#define CONV_K        7
#define CONV_G1       0x79   /* octal 171 */
#define CONV_G2       0x5B   /* octal 133 */
#define TRACEBACK     35     /* 5 * k */
#define NUM_STATES    64     /* 2^(k-1) */

/* Frame structure */
#define ASM_WORD      0x1ACFFC1DU
#define ASM_BYTES     4
#define CODEWORD_LEN  255
#define RS_DATA_LEN   223
#define RS_ROOTS      32
#define RS_I          4      /* interleave depth */
#define FRAME_CODED   (RS_I * CODEWORD_LEN)   /* 1020 bytes */
#define FRAME_DATA    (RS_I * RS_DATA_LEN)     /* 892 bytes */
#define VCDU_HDR_LEN  6

/* GF(2^8) parameters */
#define GF_POLY       0x187  /* x^8+x^7+x^2+x+1 */
#define GF_SIZE       256
#define GF_DEGREE     255
#define RS_FCR        112

/* PRBS polynomial x^8+x^7+x^5+x^3+1 -> feedback taps at bits 7,6,4,2 (0-indexed) */
#define PRBS_INIT     0xFF

/* Symbol rate for GOES-18 LRIT */
#define LRIT_SYM_RATE 293883   /* bits/s; each viterbi output bit is one demod symbol */

struct goes_cfg {
    double   freq_mhz;
    unsigned adc_rate;
    unsigned rf_bw;
    unsigned iio_buf;
    unsigned duration_sec;
    double   rx_gain_db;
    char     gain_mode[32];
    char     output[256];
    int      dry_run;
};

/* --- GF(2^8) tables --- */
static uint8_t gf_exp[512];
static uint8_t gf_log[256];

static void gf_build_tables(void)
{
    int x = 1;
    for (int i = 0; i < GF_DEGREE; i++) {
        gf_exp[i] = (uint8_t)x;
        gf_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 256)
            x ^= GF_POLY;
    }
    for (int i = GF_DEGREE; i < 512; i++)
        gf_exp[i] = gf_exp[i - GF_DEGREE];
    gf_log[0] = 0; /* undefined but set to 0 to avoid UB in multiplies by zero */
}

static uint8_t gf_mul(uint8_t a, uint8_t b)
{
    if (a == 0 || b == 0)
        return 0;
    return gf_exp[(int)gf_log[a] + (int)gf_log[b]];
}

static uint8_t gf_pow(uint8_t a, int n)
{
    if (a == 0)
        return 0;
    return gf_exp[((int)gf_log[a] * n) % GF_DEGREE];
}

static uint8_t gf_inv(uint8_t a)
{
    if (a == 0)
        return 0;
    return gf_exp[GF_DEGREE - (int)gf_log[a]];
}

/* --- Reed-Solomon RS(255,223) decoder --- */

/* Evaluate poly at x using Horner's method. poly[0] is the highest-degree term. */
static uint8_t rs_poly_eval(const uint8_t *poly, int deg, uint8_t x)
{
    uint8_t r = poly[0];
    for (int i = 1; i <= deg; i++)
        r = (uint8_t)(gf_mul(r, x) ^ poly[i]);
    return r;
}

/*
 * Decode one RS(255,223) codeword in-place (data+parity in cw[0..254]).
 * Returns number of errors corrected, or -1 if uncorrectable.
 */
static int rs_decode_codeword(uint8_t *cw)
{
    /* Compute syndromes S[i] = cw(alpha^(FCR+i)), i=0..2t-1 */
    uint8_t S[RS_ROOTS];
    int has_error = 0;
    for (int i = 0; i < RS_ROOTS; i++) {
        S[i] = rs_poly_eval(cw, CODEWORD_LEN - 1, gf_pow(2, RS_FCR + i));
        if (S[i] != 0)
            has_error = 1;
    }
    if (!has_error)
        return 0;

    /* Berlekamp-Massey to find error locator polynomial Lambda */
    uint8_t Lambda[RS_ROOTS / 2 + 1];
    uint8_t B[RS_ROOTS / 2 + 1];
    memset(Lambda, 0, sizeof(Lambda));
    memset(B, 0, sizeof(B));
    Lambda[0] = 1;
    B[0] = 1;
    int L = 0;
    uint8_t b = 1;

    for (int n = 0; n < RS_ROOTS; n++) {
        /* discrepancy */
        uint8_t d = S[n];
        for (int i = 1; i <= L; i++)
            d ^= gf_mul(Lambda[i], S[n - i]);

        if (d == 0) {
            /* shift B */
            memmove(B + 1, B, RS_ROOTS / 2);
            B[0] = 0;
            continue;
        }

        uint8_t T[RS_ROOTS / 2 + 1];
        memcpy(T, Lambda, sizeof(T));

        uint8_t coeff = gf_mul(d, gf_inv(b));
        for (int i = 1; i <= RS_ROOTS / 2; i++)
            Lambda[i] ^= gf_mul(coeff, B[i - 1]);

        if (2 * L <= n) {
            L = n + 1 - L;
            memcpy(B, T, sizeof(B));
            b = d;
        } else {
            memmove(B + 1, B, RS_ROOTS / 2);
            B[0] = 0;
        }
    }

    if (L > RS_ROOTS / 2)
        return -1; /* too many errors */

    /* Chien search: find roots of Lambda */
    int err_pos[RS_ROOTS / 2];
    int nerr = 0;
    for (int i = 0; i < CODEWORD_LEN; i++) {
        /* evaluate Lambda at alpha^(-i) = alpha^(255-i) */
        uint8_t val = Lambda[0];
        uint8_t xi = gf_pow(2, (GF_DEGREE - i) % GF_DEGREE);
        uint8_t xpow = xi;
        for (int j = 1; j <= L; j++) {
            val ^= gf_mul(Lambda[j], xpow);
            xpow = gf_mul(xpow, xi);
        }
        if (val == 0) {
            if (nerr >= RS_ROOTS / 2)
                return -1;
            err_pos[nerr++] = i;
        }
    }

    if (nerr != L)
        return -1;

    /* Forney algorithm: compute error magnitudes */
    /* Omega = S * Lambda mod x^(2t) */
    uint8_t Omega[RS_ROOTS];
    memset(Omega, 0, sizeof(Omega));
    for (int i = 0; i < RS_ROOTS; i++) {
        for (int j = 0; j <= L && i - j >= 0; j++)
            Omega[i] ^= gf_mul(S[i - j], Lambda[j]);
    }

    /* Lambda' (formal derivative of Lambda, even coefficients become 0) */
    for (int k = 0; k < nerr; k++) {
        int pos = err_pos[k];
        uint8_t Xi = gf_pow(2, pos);
        uint8_t Xi_inv = gf_inv(Xi);

        /* Omega(Xi^-1) */
        uint8_t omega_val = 0;
        uint8_t xpow = 1;
        for (int i = 0; i < RS_ROOTS; i++) {
            omega_val ^= gf_mul(Omega[i], xpow);
            xpow = gf_mul(xpow, Xi_inv);
        }

        /* Lambda'(Xi^-1): derivative zeroes even-indexed terms */
        uint8_t lambda_prime = 0;
        xpow = 1;
        for (int i = 1; i <= L; i += 2) {
            lambda_prime ^= gf_mul(Lambda[i], xpow);
            xpow = gf_mul(xpow, gf_mul(Xi_inv, Xi_inv));
        }

        if (lambda_prime == 0)
            return -1;

        uint8_t magnitude = gf_mul(Xi, gf_mul(omega_val, gf_inv(lambda_prime)));

        /* pos 0 = highest power; byte index = 254 - pos */
        int byte_idx = (CODEWORD_LEN - 1) - pos;
        if (byte_idx < 0 || byte_idx >= CODEWORD_LEN)
            return -1;
        cw[byte_idx] ^= magnitude;
    }

    return nerr;
}

/*
 * RS decode one 1020-byte GOES-18 LRIT coded frame (I=4 interleaved).
 * Fills out[0..891] with recovered VCDU data.
 * Returns total errors corrected, or -1 if any codeword was uncorrectable.
 */
static int rs_decode_frame(const uint8_t *in, uint8_t *out)
{
    uint8_t cw[CODEWORD_LEN];
    int total_errors = 0;

    for (int i = 0; i < RS_I; i++) {
        /* de-interleave: take every 4th byte starting at offset i */
        for (int j = 0; j < CODEWORD_LEN; j++)
            cw[j] = in[i + j * RS_I];

        int e = rs_decode_codeword(cw);
        if (e < 0)
            return -1;
        total_errors += e;

        /* copy data portion back */
        for (int j = 0; j < RS_DATA_LEN; j++)
            out[i + j * RS_I] = cw[j];
    }

    return total_errors;
}

/* --- CCSDS PRBS descrambler --- */

/*
 * Apply PRBS to buf[0..len-1] in-place.
 * Polynomial x^8+x^7+x^5+x^3+1, feedback = bit7^bit6^bit4^bit2 of shift register.
 */
static void prbs_descramble(uint8_t *buf, int len)
{
    uint8_t sr = PRBS_INIT;
    for (int i = 0; i < len; i++) {
        uint8_t out_byte = 0;
        for (int b = 7; b >= 0; b--) {
            uint8_t fb = ((sr >> 7) ^ (sr >> 6) ^ (sr >> 4) ^ (sr >> 2)) & 1;
            out_byte |= (uint8_t)(fb << b);
            sr = (uint8_t)((sr << 1) | fb);
        }
        buf[i] ^= out_byte;
    }
}

/* --- Viterbi decoder (rate 1/2, k=7, CCSDS) --- */

#define VITERBI_INF   0x7FFFFFFF

struct viterbi {
    int32_t  pm[NUM_STATES];        /* path metrics */
    int32_t  pm_new[NUM_STATES];
    uint8_t  tb[TRACEBACK][NUM_STATES];  /* traceback ring buffer, survivor choices */
    int      tb_head;
    uint8_t  out_bits[TRACEBACK];   /* decoded bits from traceback */
    int      out_head;
    int      out_count;

    /* branch tables: bm_table[sym2][state] = branch metric contribution */
    /* precomputed at init */
    int32_t  branch_out[NUM_STATES * 2][2]; /* [state*2+next_bit][0/1] = expected symbols */
};

/*
 * CCSDS convolutional code:
 *   G1 = 0x79 feeds into output 0
 *   G2 = 0x5B feeds into output 1
 * State is bits [k-2 .. 0] of the shift register (6 bits = 64 states).
 * Input bit enters at the MSB of the register.
 */
static void viterbi_init(struct viterbi *v)
{
    memset(v, 0, sizeof(*v));
    for (int s = 0; s < NUM_STATES; s++)
        v->pm[s] = VITERBI_INF;
    v->pm[0] = 0;
    v->tb_head = 0;
    v->out_head = 0;
    v->out_count = 0;

    /* precompute expected output symbols for each (state, input_bit) pair */
    for (int s = 0; s < NUM_STATES; s++) {
        for (int bit = 0; bit < 2; bit++) {
            /* shift register: new state has input bit at top */
            int sr = (bit << (CONV_K - 1)) | (s >> 1);
            /* full k-bit register includes current input */
            int reg = (bit << (CONV_K - 1)) | s;
            (void)sr;
            int out0 = __builtin_popcount(reg & CONV_G1) & 1;
            int out1 = __builtin_popcount(reg & CONV_G2) & 1;
            v->branch_out[s * 2 + bit][0] = out0;
            v->branch_out[s * 2 + bit][1] = out1;
        }
    }
}

/*
 * Feed one soft-decision symbol pair (s0, s1) in the range [-128..127] into
 * the Viterbi decoder and return one decoded bit, or -1 if the output buffer
 * is not yet filled (first TRACEBACK symbols produce no output).
 *
 * s0 and s1 are the soft decisions for the two code bits of one encoded pair.
 * Positive = likely 1, negative = likely 0.
 */
static int viterbi_step(struct viterbi *v, int s0, int s1)
{
    int head = v->tb_head;

    for (int s = 0; s < NUM_STATES; s++)
        v->pm_new[s] = VITERBI_INF;

    for (int s = 0; s < NUM_STATES; s++) {
        if (v->pm[s] == VITERBI_INF)
            continue;

        for (int bit = 0; bit < 2; bit++) {
            int ns = (int)(((unsigned)s >> 1) | ((unsigned)bit << (CONV_K - 2)));
            int e0 = v->branch_out[s * 2 + bit][0];
            int e1 = v->branch_out[s * 2 + bit][1];

            /* hard-decision branch metric: number of bit disagreements */
            int hard_s0 = (s0 >= 0) ? 1 : 0;
            int hard_s1 = (s1 >= 0) ? 1 : 0;
            int bm = (hard_s0 ^ e0) + (hard_s1 ^ e1);

            int32_t new_pm = v->pm[s] + bm;
            if (new_pm < v->pm_new[ns]) {
                v->pm_new[ns] = new_pm;
                v->tb[head][ns] = (uint8_t)s;
            }
        }
    }

    memcpy(v->pm, v->pm_new, sizeof(v->pm));
    v->tb_head = (head + 1) % TRACEBACK;

    /* normalize path metrics every step */
    int32_t min_pm = VITERBI_INF;
    for (int s = 0; s < NUM_STATES; s++)
        if (v->pm[s] < min_pm)
            min_pm = v->pm[s];
    if (min_pm != VITERBI_INF)
        for (int s = 0; s < NUM_STATES; s++)
            if (v->pm[s] != VITERBI_INF)
                v->pm[s] -= min_pm;

    if (v->out_count < TRACEBACK) {
        v->out_count++;
        return -1;
    }

    /* traceback: find best state */
    int best = 0;
    for (int s = 1; s < NUM_STATES; s++)
        if (v->pm[s] < v->pm[best])
            best = s;

    /* trace back TRACEBACK steps */
    int cur = best;
    int tb_pos = head;
    for (int i = 0; i < TRACEBACK - 1; i++) {
        int prev = v->tb[tb_pos][cur];
        tb_pos = (tb_pos - 1 + TRACEBACK) % TRACEBACK;
        cur = prev;
    }

    /* the oldest survivor gives us the decoded bit */
    int prev_state = v->tb[tb_pos][cur];
    /* the bit that caused the transition from prev_state to cur */
    int decoded_bit = (cur >> (CONV_K - 2)) & 1;
    (void)prev_state;

    return decoded_bit;
}

/* --- Frame synchronizer --- */

#define SYNC_SEARCH   0
#define SYNC_LOCKED   1

struct frame_sync {
    uint32_t shift_reg;     /* bit shift register for ASM search */
    int      state;
    int      bit_count;     /* bits since last ASM */
    int      frame_bits;    /* bits per coded frame including ASM = 32 + 1020*8 */
    uint8_t  frame_buf[FRAME_CODED];
    int      frame_bit_idx;
    int      inverted;      /* 1 if we locked on inverted ASM */
};

static void frame_sync_init(struct frame_sync *fs)
{
    memset(fs, 0, sizeof(*fs));
    fs->state = SYNC_SEARCH;
    fs->frame_bits = ASM_BYTES * 8 + FRAME_CODED * 8;
}

/*
 * Push one decoded bit into the frame synchronizer.
 * Returns 1 when a complete coded frame (1020 bytes) is ready in fs->frame_buf.
 */
static int frame_sync_push(struct frame_sync *fs, int bit)
{
    fs->shift_reg = (fs->shift_reg << 1) | (unsigned)bit;

    if (fs->state == SYNC_SEARCH) {
        if (fs->shift_reg == ASM_WORD) {
            fs->state = SYNC_LOCKED;
            fs->frame_bit_idx = 0;
            fs->inverted = 0;
            return 0;
        }
        if (fs->shift_reg == (~ASM_WORD & 0xFFFFFFFFU)) {
            fs->state = SYNC_LOCKED;
            fs->frame_bit_idx = 0;
            fs->inverted = 1;
            return 0;
        }
        return 0;
    }

    /* SYNC_LOCKED: collect frame bits */
    int byte_idx = fs->frame_bit_idx / 8;
    int bit_pos  = 7 - (fs->frame_bit_idx % 8);
    int actual_bit = fs->inverted ? (bit ^ 1) : bit;

    if (actual_bit)
        fs->frame_buf[byte_idx] |= (uint8_t)(1 << bit_pos);
    else
        fs->frame_buf[byte_idx] &= (uint8_t)~(1 << bit_pos);

    fs->frame_bit_idx++;

    if (fs->frame_bit_idx == FRAME_CODED * 8) {
        fs->frame_bit_idx = 0;
        /* verify the next ASM is in place by returning to search temporarily */
        fs->state = SYNC_SEARCH;
        fs->bit_count = 0;
        return 1;
    }

    return 0;
}

/* --- Costas loop for BPSK --- */

struct costas {
    double phase;
    double freq;
    double alpha;    /* phase error loop gain */
    double beta;     /* frequency error loop gain */
    double sig_pow;  /* signal power estimate for SNR */
    double noise_pow;
};

static void costas_init(struct costas *c, double bw)
{
    c->phase = 0.0;
    c->freq = 0.0;
    /* 2nd-order loop; bw is normalized loop bandwidth */
    double damp = 0.707;
    double omega = 2.0 * M_PI * bw;
    c->alpha = (4.0 * damp * omega) / (1.0 + 2.0 * damp * omega + omega * omega);
    c->beta  = (4.0 * omega * omega) / (1.0 + 2.0 * damp * omega + omega * omega);
    c->sig_pow   = 1.0;
    c->noise_pow = 1.0;
}

/*
 * Process one IQ sample through the Costas loop.
 * Returns soft-decision bit value (positive = 1, negative = 0).
 */
static double costas_step(struct costas *c, double xi, double xq)
{
    /* rotate by -phase */
    double ci = xi * cos(-c->phase) - xq * sin(-c->phase);
    double cq = xi * sin(-c->phase) + xq * cos(-c->phase);

    /* BPSK phase error = sign(I) * Q */
    double err = (ci >= 0.0 ? 1.0 : -1.0) * cq;

    c->freq  += c->beta * err;
    c->phase += c->freq + c->alpha * err;

    /* wrap phase */
    while (c->phase >  M_PI) c->phase -= 2.0 * M_PI;
    while (c->phase < -M_PI) c->phase += 2.0 * M_PI;

    /* update power estimates for SNR */
    double power = ci * ci + cq * cq;
    c->sig_pow   = 0.999 * c->sig_pow   + 0.001 * ci * ci;
    c->noise_pow = 0.999 * c->noise_pow + 0.001 * (power - ci * ci + 1e-10);

    return ci;
}

/* --- Symbol timing (Mueller-Muller style phase accumulator) --- */

struct sym_timing {
    double phase;     /* 0..1, advance by sps per sample */
    double sps;       /* samples per symbol */
    double last;      /* previous sample value */
};

static void sym_timing_init(struct sym_timing *st, double sps)
{
    st->phase = 0.0;
    st->sps   = sps;
    st->last  = 0.0;
}

/*
 * Advance timing by one sample.
 * Returns 1 and sets *sym_out to the interpolated symbol value if a symbol
 * boundary was crossed; returns 0 otherwise.
 */
static int sym_timing_step(struct sym_timing *st, double sample, double *sym_out)
{
    double prev_phase = st->phase;
    st->phase += 1.0 / st->sps;

    if (st->phase >= 1.0) {
        st->phase -= 1.0;
        /* linear interpolation between last and current */
        double frac = prev_phase / (1.0 / st->sps);
        *sym_out = st->last + frac * (sample - st->last);
        st->last = sample;
        return 1;
    }

    st->last = sample;
    return 0;
}

/* --- IIO helpers (same as icesugar_stream.c) --- */

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

static int write_attr_str(const char *dev, const char *attr, const char *value)
{
    char path[256];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s", dev, attr);
    f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }

    fprintf(f, "%s\n", value);
    if (fclose(f) != 0) {
        fprintf(stderr, "write %s: %s\n", path, strerror(errno));
        return -1;
    }

    return 0;
}

static int write_attr_double(const char *dev, const char *attr, double value)
{
    char text[64];
    snprintf(text, sizeof(text), "%.2f", value);
    return write_attr_str(dev, attr, text);
}

static void try_write_attr_str(const char *dev, const char *attr, const char *value)
{
    if (write_attr_str(dev, attr, value) != 0)
        fprintf(stderr, "warning: could not set %s=%s\n", attr, value);
}

static void try_write_attr_double(const char *dev, const char *attr, double value)
{
    if (write_attr_double(dev, attr, value) != 0)
        fprintf(stderr, "warning: could not set %s=%.2f\n", attr, value);
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

/* --- AD9361 configuration --- */

static int configure_rx(const struct goes_cfg *cfg, unsigned *actual_rate)
{
    char phy[128];
    unsigned long long freq_hz = (unsigned long long)(cfg->freq_mhz * 1e6 + 0.5);

    if (find_iio_device(IIO_NAME_PHY, phy, sizeof(phy)) != 0) {
        fprintf(stderr, "IIO device '%s' not found\n", IIO_NAME_PHY);
        return -1;
    }

    if (write_attr(phy, "out_altvoltage0_RX_LO_frequency", freq_hz) != 0)
        return -1;

    if (write_attr(phy, "in_voltage_sampling_frequency", (unsigned long long)cfg->adc_rate) != 0)
        return -1;

    if (write_attr(phy, "in_voltage_rf_bandwidth", (unsigned long long)cfg->rf_bw) != 0)
        return -1;

    if (cfg->gain_mode[0]) {
        try_write_attr_str(phy, "in_voltage0_gain_control_mode", cfg->gain_mode);
        try_write_attr_str(phy, "in_voltage1_gain_control_mode", cfg->gain_mode);
    }

    if (cfg->rx_gain_db >= 0.0) {
        try_write_attr_double(phy, "in_voltage0_hardwaregain", cfg->rx_gain_db);
        try_write_attr_double(phy, "in_voltage1_hardwaregain", cfg->rx_gain_db);
    }

    *actual_rate = read_attr_u32(phy, "in_voltage_sampling_frequency");
    if (*actual_rate == 0)
        *actual_rate = cfg->adc_rate;

    fprintf(stderr, "AD9361 configured: %.4f MHz, sample_rate=%u Hz, rf_bw=%u Hz, gain_mode=%s",
            cfg->freq_mhz, *actual_rate, cfg->rf_bw,
            cfg->gain_mode[0] ? cfg->gain_mode : "unchanged");
    if (cfg->rx_gain_db >= 0.0)
        fprintf(stderr, ", rx_gain_db=%.2f", cfg->rx_gain_db);
    fprintf(stderr, "\n");

    return 0;
}

static FILE *open_iio_readdev(const struct goes_cfg *cfg, unsigned actual_rate)
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

    fprintf(stderr, "Starting: %s\n", cmd);
    return popen(cmd, "r");
}

/* --- VCDU header --- */

struct vcdu_hdr {
    unsigned version;
    unsigned scid;
    unsigned vcid;
    unsigned counter;
};

static void parse_vcdu_header(const uint8_t *frame, struct vcdu_hdr *h)
{
    /* byte 0: version[2] | scid_hi[6] */
    h->version = (frame[0] >> 6) & 0x3;
    h->scid    = ((frame[0] & 0x3F) << 4) | (frame[1] >> 4);
    h->vcid    = ((frame[1] & 0x0F) << 2) | (frame[2] >> 6);
    h->counter = ((uint32_t)(frame[2] & 0x3F) << 18)
               | ((uint32_t)frame[3] << 10)
               | ((uint32_t)frame[4] <<  2)
               | ((uint32_t)frame[5] >>  6);
}

/* --- signal handler --- */

static volatile sig_atomic_t keep_running = 1;

static void on_signal(int sig)
{
    (void)sig;
    keep_running = 0;
}

/* --- main decode loop --- */

static int decode_loop(FILE *src, const struct goes_cfg *cfg,
                       unsigned actual_rate, FILE *out_fp)
{
    int16_t *buf;
    size_t buf_words = (size_t)cfg->iio_buf * 2;

    buf = malloc(buf_words * sizeof(int16_t));
    if (!buf) {
        perror("malloc");
        return -1;
    }

    uint8_t *rs_out = malloc(FRAME_DATA);
    if (!rs_out) {
        free(buf);
        perror("malloc");
        return -1;
    }

    struct costas   costas;
    struct sym_timing sym;
    struct viterbi  vit;
    struct frame_sync fsync;

    double sps = (double)actual_rate / (double)LRIT_SYM_RATE;

    costas_init(&costas, 0.002);
    sym_timing_init(&sym, sps);
    viterbi_init(&vit);
    frame_sync_init(&fsync);
    gf_build_tables();

    unsigned long long total_frames    = 0;
    unsigned long long total_rs_errors = 0;
    unsigned long long total_samples   = 0;
    struct timeval t0, t_last_stat;
    gettimeofday(&t0, NULL);
    t_last_stat = t0;

    /* double buffer for interleaved viterbi bits: two bits per encoded symbol pair */
    int vit_buf[2];
    int vit_idx = 0;

    while (keep_running) {
        size_t got = fread(buf, sizeof(int16_t), buf_words, src);
        if (got == 0)
            break;

        got &= ~(size_t)1; /* ensure pairs */

        for (size_t n = 0; n < got; n += 2) {
            double xi = (double)buf[n];
            double xq = (double)buf[n + 1];
            total_samples++;

            double soft = costas_step(&costas, xi, xq);

            double sym_val;
            if (!sym_timing_step(&sym, soft, &sym_val))
                continue;

            /* accumulate two soft bits per Viterbi step */
            vit_buf[vit_idx++] = (int)(sym_val > 0 ? 1 : -1) * 64;
            if (vit_idx < 2)
                continue;
            vit_idx = 0;

            int decoded = viterbi_step(&vit, vit_buf[0], vit_buf[1]);
            if (decoded < 0)
                continue;

            if (!frame_sync_push(&fsync, decoded))
                continue;

            /* got a complete 1020-byte coded frame */
            uint8_t *frame = fsync.frame_buf;

            /* PRBS descramble - does not apply to ASM (already stripped) */
            prbs_descramble(frame, FRAME_CODED);

            int rs_errors = rs_decode_frame(frame, rs_out);

            if (rs_errors < 0) {
                /* uncorrectable - keep searching */
                fsync.state = SYNC_SEARCH;
                continue;
            }

            total_frames++;
            total_rs_errors += (unsigned long long)rs_errors;

            struct vcdu_hdr hdr;
            parse_vcdu_header(rs_out, &hdr);

            if (!cfg->dry_run && out_fp)
                fwrite(rs_out, 1, FRAME_DATA, out_fp);
        }

        /* periodic stats every ~5 s */
        struct timeval now;
        gettimeofday(&now, NULL);
        double elapsed_stat = (double)(now.tv_sec - t_last_stat.tv_sec) +
                              (double)(now.tv_usec - t_last_stat.tv_usec) / 1e6;
        if (elapsed_stat >= 5.0) {
            t_last_stat = now;
            double snr_db = 10.0 * log10((costas.sig_pow + 1e-20) /
                                         (costas.noise_pow + 1e-20));
            fprintf(stderr,
                    "[GOES] sync=%s frames=%llu rs_errors=%llu snr_est=%.1f dB\n",
                    fsync.state == SYNC_LOCKED ? "LOCKED" : "searching",
                    total_frames, total_rs_errors, snr_db);
        }
    }

    struct timeval t1;
    gettimeofday(&t1, NULL);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_usec - t0.tv_usec) / 1e6;
    double snr_db = 10.0 * log10((costas.sig_pow + 1e-20) /
                                 (costas.noise_pow + 1e-20));

    fprintf(stderr,
            "[GOES] done: samples=%llu frames=%llu rs_errors=%llu snr_est=%.1f dB elapsed=%.1f s\n",
            total_samples, total_frames, total_rs_errors, snr_db, elapsed);

    free(buf);
    free(rs_out);
    return 0;
}

/* --- CLI --- */

static void usage(const char *prog)
{
    printf("Usage: %s [options]\n", prog);
    printf("  --freq-mhz FREQ      RF frequency in MHz (default 1694.1)\n");
    printf("  --adc-rate HZ        AD9361 sample rate (default 1000000)\n");
    printf("  --rf-bw HZ           RF bandwidth (default 500000)\n");
    printf("  --gain-mode MODE     slow_attack (default) | fast_attack | manual\n");
    printf("  --rx-gain-db DB      Hardware gain in dB for manual mode\n");
    printf("  --output FILE        Write raw VCDU frames here (default: goes_frames.raw)\n");
    printf("  --duration SEC       Run duration, 0 = until Ctrl-C (default 0)\n");
    printf("  --iio-buf N          iio_readdev buffer size (default 8192)\n");
    printf("  --dry-run            No output file, just print lock/frame stats\n");
}

static int parse_args(int argc, char **argv, struct goes_cfg *cfg)
{
    cfg->freq_mhz    = 1694.1;
    cfg->adc_rate    = 1000000;
    cfg->rf_bw       = 500000;
    cfg->iio_buf     = 8192;
    cfg->duration_sec = 0;
    cfg->rx_gain_db  = -1.0;
    snprintf(cfg->gain_mode, sizeof(cfg->gain_mode), "%s", "slow_attack");
    snprintf(cfg->output, sizeof(cfg->output), "%s", "goes_frames.raw");
    cfg->dry_run     = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--freq-mhz") == 0 && i + 1 < argc) {
            cfg->freq_mhz = atof(argv[++i]);
        } else if (strcmp(argv[i], "--adc-rate") == 0 && i + 1 < argc) {
            cfg->adc_rate = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--rf-bw") == 0 && i + 1 < argc) {
            cfg->rf_bw = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--gain-mode") == 0 && i + 1 < argc) {
            snprintf(cfg->gain_mode, sizeof(cfg->gain_mode), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--rx-gain-db") == 0 && i + 1 < argc) {
            cfg->rx_gain_db = atof(argv[++i]);
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            snprintf(cfg->output, sizeof(cfg->output), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            cfg->duration_sec = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--iio-buf") == 0 && i + 1 < argc) {
            cfg->iio_buf = (unsigned)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            cfg->dry_run = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            exit(0);
        } else {
            fprintf(stderr, "unknown or incomplete option: %s\n", argv[i]);
            return -1;
        }
    }

    if (cfg->iio_buf == 0)
        cfg->iio_buf = 1024;
    if (cfg->adc_rate == 0)
        cfg->adc_rate = 1000000;

    return 0;
}

int main(int argc, char **argv)
{
    struct goes_cfg cfg;
    unsigned actual_rate = 0;
    FILE *iq  = NULL;
    FILE *out = NULL;
    int ret = 1;

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    if (parse_args(argc, argv, &cfg) != 0) {
        usage(argv[0]);
        return 1;
    }

    if (configure_rx(&cfg, &actual_rate) != 0)
        return 1;

    if (!cfg.dry_run) {
        out = fopen(cfg.output, "wb");
        if (!out) {
            fprintf(stderr, "open %s: %s\n", cfg.output, strerror(errno));
            return 1;
        }
        fprintf(stderr, "Writing VCDU frames to %s\n", cfg.output);
    }

    iq = open_iio_readdev(&cfg, actual_rate);
    if (!iq) {
        perror("popen iio_readdev");
        goto out;
    }

    ret = decode_loop(iq, &cfg, actual_rate, out) == 0 ? 0 : 1;

out:
    if (iq)
        pclose(iq);
    if (out)
        fclose(out);

    return ret;
}
