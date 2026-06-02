/*
 * goes_lrit.c -- VCDU -> M_PDU -> CCSDS -> LRIT -> Rice -> 800-px pipeline
 *
 * Pipeline per 892-byte VCDU:
 *   VCDU header[6] -> VCID filter (skip VCID 63 idle/fill)
 *   M_PDU header[2] -> first_header_pointer (FHP)
 *   M_PDU data[884] -> CCSDS packet reassembler
 *   CCSDS packet data -> LRIT file accumulator
 *   LRIT primary header -> file_type / total_hdr_len / data_bits
 *   LRIT Image Structure Record -> bpp / img_cols / img_lines / comp
 *   Rice decompressor (CCSDS 121.0-B-3, bpp=8, J=16 blocks)
 *   Downsample col[0..img_cols-1] -> out[0..799]
 *   send_tlv(TLV_IMAGE_ROW, out, 800) per scanline
 */

#include "goes_lrit.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define CCSDS_HDR_LEN       6
#define CCSDS_MAX_DATA      65535u
#define CCSDS_MAX_PKT       (CCSDS_HDR_LEN + CCSDS_MAX_DATA + 1u)

#define VCID_FILL           63u

/* CCSDS PSC grouping (bits 7:6 of pkt[2]) */
#define PSC_GRP_MASK        0xC0u
#define PSC_GRP_FIRST       0x40u   /* first segment */
#define PSC_GRP_CONT        0x00u   /* continuation */
#define PSC_GRP_LAST        0x80u   /* last segment */
#define PSC_GRP_STANDALONE  0xC0u   /* standalone (unsegmented) */

/* LRIT header record types */
#define LRIT_HDR_PRIMARY    0x00u
#define LRIT_HDR_IMGSTRUCT  0x01u

/* LRIT file types */
#define LRIT_FILE_IMAGE     0x00u

/* LRIT compression flags */
#define LRIT_COMP_NONE      0u
#define LRIT_COMP_RICE      3u

/* Rice coding: fixed parameters for bpp=8 */
#define RICE_J              16      /* block size in samples */
#define RICE_BPP            8       /* bits per pixel */
/* id_bits = ceil(log2(bpp+3)) = ceil(log2(11)) = 4 */
#define RICE_ID_BITS        4
/* id=0 -> zero block; id=bpp+1=9 -> raw block; id=1..8 -> Rice k=id-1 */
#define RICE_ID_RAW         9u
#define RICE_ID_ZERO        0u

#define TLV_IMAGE_ROW       0x01u

/* Initial accumulation buffer capacity */
#define ACCUM_INIT_CAP      (64u * 1024u)

/* Maximum allowed LRIT data field (safety cap: 32 MB) */
#define LRIT_DATA_MAX_BYTES (32u * 1024u * 1024u)

/* Row buffer max width */
#define ROW_BUF_MAX         65535u

/* ------------------------------------------------------------------ */
/* Bitstream reader                                                    */
/* ------------------------------------------------------------------ */

struct bs {
    const uint8_t *data;
    uint32_t       cap;       /* data length in bytes */
    uint32_t       byte_pos;
    int            bit_pos;   /* 7 = MSB of current byte, counts down */
};

static void bs_init(struct bs *b, const uint8_t *data, uint32_t cap)
{
    b->data     = data;
    b->cap      = cap;
    b->byte_pos = 0;
    b->bit_pos  = 7;
}

/* Read n bits (MSB first) into *out. Returns 0 on success, -1 on underrun. */
static int bs_read(struct bs *b, int n, uint32_t *out)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        if (b->byte_pos >= b->cap)
            return -1;
        v = (v << 1) | ((b->data[b->byte_pos] >> b->bit_pos) & 1u);
        if (b->bit_pos == 0) {
            b->bit_pos = 7;
            b->byte_pos++;
        } else {
            b->bit_pos--;
        }
    }
    *out = v;
    return 0;
}

/* Read unary quotient: count 0 bits until a 1. Returns -1 on underrun. */
static int bs_read_unary(struct bs *b, uint32_t *q)
{
    *q = 0;
    uint32_t bit;
    for (;;) {
        if (bs_read(b, 1, &bit))
            return -1;
        if (bit)
            return 0;
        if (++(*q) > 65535u)
            return -1;  /* safety: malformed bitstream */
    }
}

/* ------------------------------------------------------------------ */
/* Parser state                                                        */
/* ------------------------------------------------------------------ */

struct lrit_state {
    /* ---- CCSDS packet reassembly ---- */
    uint8_t  *ccsds_buf;     /* CCSDS_MAX_PKT bytes, allocated at init */
    uint32_t  ccsds_fill;    /* bytes in buffer so far */
    uint32_t  ccsds_need;    /* total bytes expected (0 = idle) */

    /* ---- LRIT file accumulation ---- */
    int        in_file;       /* 1 = assembling a file */
    uint8_t   *accum_buf;     /* grows as needed */
    uint32_t   accum_cap;
    uint32_t   accum_fill;
    uint32_t   accum_need;    /* total_hdr_len + data_need (0 = not known) */

    /* Parsed from LRIT primary header */
    int        prim_parsed;
    uint8_t    file_type;
    uint32_t   total_hdr_len;
    uint64_t   data_bits;

    /* Parsed from Image Structure Record */
    int        img_parsed;
    uint16_t   img_cols;
    uint16_t   img_lines;
    uint8_t    bpp;
    uint8_t    comp;

    /* Row scratch buffer */
    uint8_t   *row_buf;       /* img_cols bytes, reallocated as needed */
    uint32_t   row_buf_cap;
    uint8_t    out_row[800];
};

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static void lrit_reset(lrit_state_t *s)
{
    s->in_file      = 0;
    s->accum_fill   = 0;
    s->accum_need   = 0;
    s->prim_parsed  = 0;
    s->img_parsed   = 0;
    s->file_type    = 0;
    s->total_hdr_len = 0;
    s->data_bits    = 0;
    s->img_cols     = 0;
    s->img_lines    = 0;
    s->bpp          = 0;
    s->comp         = 0;
}

static int accum_grow(lrit_state_t *s, uint32_t need)
{
    if (need <= s->accum_cap)
        return 0;
    uint32_t new_cap = s->accum_cap ? s->accum_cap : ACCUM_INIT_CAP;
    while (new_cap < need)
        new_cap *= 2u;
    uint8_t *p = realloc(s->accum_buf, new_cap);
    if (!p)
        return -1;
    s->accum_buf = p;
    s->accum_cap = new_cap;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Rice decompressor                                                   */
/* ------------------------------------------------------------------ */

static void rice_decompress_and_send(
        lrit_state_t *s,
        const uint8_t *data, uint32_t data_len,
        void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
        void (*drain)(void))
{
    uint16_t cols  = s->img_cols;
    uint16_t lines = s->img_lines;
    uint8_t  bpp   = s->bpp;

    /* id_bits = ceil(log2(bpp + 3)) */
    int id_bits = 1;
    while ((1 << id_bits) < (bpp + 3))
        id_bits++;

    uint32_t id_raw = (uint32_t)(bpp + 1);  /* option ID for uncoded block */
    uint32_t mask   = (uint32_t)((1u << bpp) - 1u);

    struct bs bs;
    bs_init(&bs, data, data_len);

    uint8_t *row = s->row_buf;

    for (int line = 0; line < (int)lines; line++) {
        /* Reference sample: bpp raw bits */
        uint32_t ref;
        if (bs_read(&bs, bpp, &ref))
            goto done;
        row[0] = (uint8_t)(ref & mask);

        uint32_t prev = ref & mask;
        int      col  = 1;

        while (col < (int)cols) {
            /* Option ID */
            uint32_t id;
            if (bs_read(&bs, id_bits, &id))
                goto done;

            /* Always process J samples per block, even if last block is partial.
             * Padded samples have mapped_residual=0 (delta=0) and are discarded
             * after bit consumption. */
            for (int b = 0; b < RICE_J; b++) {
                int keep = (col < (int)cols);

                if (id == RICE_ID_ZERO) {
                    /* Entire block has zero mapped_residual -> delta = 0 */
                    if (keep)
                        row[col++] = (uint8_t)prev;
                    /* No bits to consume */
                } else if (id == id_raw) {
                    /* Raw: bpp bits per sample */
                    uint32_t raw;
                    if (bs_read(&bs, bpp, &raw))
                        goto done;
                    raw &= mask;
                    if (keep) {
                        row[col++] = (uint8_t)raw;
                        prev = raw;
                    }
                } else {
                    /* Rice coding, k = id - 1 */
                    int      k = (int)id - 1;
                    uint32_t q;
                    if (bs_read_unary(&bs, &q))
                        goto done;
                    uint32_t r = 0;
                    if (k > 0 && bs_read(&bs, k, &r))
                        goto done;
                    uint32_t m = (q << k) | r;
                    /* Zigzag: even -> +delta, odd -> -delta */
                    int32_t delta = (m & 1u)
                                  ? -((int32_t)(m + 1u) / 2)
                                  :  (int32_t)(m / 2u);
                    prev = (uint32_t)((int32_t)prev + delta) & mask;
                    if (keep)
                        row[col++] = (uint8_t)prev;
                }
            }
        }

        /* Downsample from cols to 800 pixels */
        for (int x = 0; x < 800; x++)
            s->out_row[x] = row[(uint32_t)x * cols / 800u];

        send_tlv(TLV_IMAGE_ROW, s->out_row, 800);
        if (drain)
            drain();
    }

done:
    return;
}

/* ------------------------------------------------------------------ */
/* LRIT header parser                                                  */
/* ------------------------------------------------------------------ */

static void parse_lrit_headers(lrit_state_t *s)
{
    uint32_t pos = 16u;  /* skip primary header already parsed */

    while (pos + 3u <= s->total_hdr_len) {
        uint8_t  htype = s->accum_buf[pos];
        uint16_t hlen  = ((uint16_t)s->accum_buf[pos + 1] << 8)
                       |  (uint16_t)s->accum_buf[pos + 2];

        if (hlen < 3u || pos + hlen > s->total_hdr_len)
            break;

        if (htype == LRIT_HDR_IMGSTRUCT && hlen >= 9u) {
            s->bpp       = s->accum_buf[pos + 3];
            s->img_cols  = ((uint16_t)s->accum_buf[pos + 4] << 8)
                         |  (uint16_t)s->accum_buf[pos + 5];
            s->img_lines = ((uint16_t)s->accum_buf[pos + 6] << 8)
                         |  (uint16_t)s->accum_buf[pos + 7];
            s->comp      = s->accum_buf[pos + 8];
            s->img_parsed = 1;
        }

        pos += hlen;
    }
}

/* ------------------------------------------------------------------ */
/* File completion check                                               */
/* ------------------------------------------------------------------ */

static void lrit_try_complete(lrit_state_t *s,
                               void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                               void (*drain)(void))
{
    if (!s->prim_parsed || !s->accum_need || s->accum_fill < s->accum_need)
        return;

    parse_lrit_headers(s);

    if (!s->img_parsed) {
        fprintf(stderr, "[LRIT] no image structure record found\n");
        lrit_reset(s);
        return;
    }

    if (s->comp != LRIT_COMP_RICE) {
        if (s->comp != LRIT_COMP_NONE)
            fprintf(stderr, "[LRIT] unsupported compression %u, skipping\n",
                    s->comp);
        lrit_reset(s);
        return;
    }

    if (s->bpp != RICE_BPP) {
        fprintf(stderr, "[LRIT] bpp=%u not supported (expected 8)\n", s->bpp);
        lrit_reset(s);
        return;
    }

    if (s->img_cols == 0 || s->img_lines == 0) {
        fprintf(stderr, "[LRIT] zero image dimensions\n");
        lrit_reset(s);
        return;
    }

    /* Ensure row buffer is large enough */
    if (s->img_cols > s->row_buf_cap) {
        free(s->row_buf);
        s->row_buf = malloc(s->img_cols);
        if (!s->row_buf) {
            s->row_buf_cap = 0;
            lrit_reset(s);
            return;
        }
        s->row_buf_cap = s->img_cols;
    }

    uint32_t data_need = (uint32_t)((s->data_bits + 7u) / 8u);
    const uint8_t *data_ptr = s->accum_buf + s->total_hdr_len;

    fprintf(stderr, "[LRIT] image %ux%u bpp=%u comp=Rice, decompressing\n",
            s->img_cols, s->img_lines, s->bpp);

    rice_decompress_and_send(s, data_ptr, data_need, send_tlv, drain);
    lrit_reset(s);
}

/* ------------------------------------------------------------------ */
/* LRIT accumulation                                                   */
/* ------------------------------------------------------------------ */

static void lrit_accumulate(lrit_state_t *s,
                             const uint8_t *data, uint32_t len,
                             void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                             void (*drain)(void))
{
    if (!s->in_file || len == 0)
        return;

    uint32_t need = s->accum_need ? s->accum_need : s->accum_fill + len;
    if (accum_grow(s, s->accum_fill + len)) {
        lrit_reset(s);
        return;
    }

    memcpy(s->accum_buf + s->accum_fill, data, len);
    s->accum_fill += len;

    /* Once we have the 16-byte primary header, parse it */
    if (!s->prim_parsed && s->accum_fill >= 16u) {
        uint8_t *h = s->accum_buf;
        s->file_type     = h[3];
        s->total_hdr_len = ((uint32_t)h[4] << 24) | ((uint32_t)h[5] << 16)
                         | ((uint32_t)h[6] <<  8) |  (uint32_t)h[7];
        s->data_bits = 0;
        for (int i = 0; i < 8; i++)
            s->data_bits = (s->data_bits << 8) | h[8 + i];

        if (s->file_type != LRIT_FILE_IMAGE) {
            s->in_file = 0;
            lrit_reset(s);
            return;
        }

        if (s->total_hdr_len < 16u || s->data_bits == 0 ||
            s->data_bits > (uint64_t)LRIT_DATA_MAX_BYTES * 8u) {
            s->in_file = 0;
            lrit_reset(s);
            return;
        }

        uint32_t data_need  = (uint32_t)((s->data_bits + 7u) / 8u);
        s->accum_need = s->total_hdr_len + data_need;
        s->prim_parsed = 1;

        /* Grow to final size now that we know it */
        if (accum_grow(s, s->accum_need)) {
            lrit_reset(s);
            return;
        }
    }

    (void)need;
    lrit_try_complete(s, send_tlv, drain);
}

/* ------------------------------------------------------------------ */
/* CCSDS packet handler                                                */
/* ------------------------------------------------------------------ */

static void on_ccsds_packet(lrit_state_t *s,
                             const uint8_t *pkt, uint32_t pkt_len,
                             void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                             void (*drain)(void))
{
    if (pkt_len < (uint32_t)CCSDS_HDR_LEN)
        return;

    uint8_t grouping = pkt[2] & PSC_GRP_MASK;
    int is_new = (grouping == PSC_GRP_FIRST) || (grouping == PSC_GRP_STANDALONE);

    if (is_new) {
        lrit_reset(s);
        s->in_file = 1;
    }

    if (!s->in_file)
        return;

    uint32_t data_len = pkt_len - CCSDS_HDR_LEN;
    if (data_len == 0)
        return;

    lrit_accumulate(s, pkt + CCSDS_HDR_LEN, data_len, send_tlv, drain);
}

/* ------------------------------------------------------------------ */
/* CCSDS / M_PDU reassembly                                           */
/* ------------------------------------------------------------------ */

static void ccsds_process_mpdu(lrit_state_t *s,
                                const uint8_t *data, /* 884 bytes */
                                uint16_t fhp,
                                void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                                void (*drain)(void))
{
    const uint32_t MPDU_DATA_LEN = 884u;

    if (fhp != 0x7FFu) {
        /* fhp = byte offset within this M_PDU data field where a new
         * CCSDS packet header starts.  Any bytes before fhp are the tail
         * of the previous packet. */

        if (s->ccsds_need > 0) {
            uint32_t remaining = s->ccsds_need - s->ccsds_fill;
            uint32_t tail      = (fhp < remaining) ? fhp : remaining;
            if (s->ccsds_fill + tail <= CCSDS_MAX_PKT) {
                memcpy(s->ccsds_buf + s->ccsds_fill, data, tail);
                s->ccsds_fill += tail;
            }
            if (s->ccsds_fill >= s->ccsds_need) {
                on_ccsds_packet(s, s->ccsds_buf, s->ccsds_need,
                                send_tlv, drain);
                s->ccsds_need = 0;
            }
        }

        /* Process new packet(s) starting at fhp */
        uint32_t pos = fhp;
        while (pos < MPDU_DATA_LEN) {
            if (s->ccsds_need == 0) {
                /* Need 6-byte CCSDS primary header */
                if (MPDU_DATA_LEN - pos < (uint32_t)CCSDS_HDR_LEN)
                    break;
                uint32_t data_field_len =
                        ((uint32_t)data[pos + 4] << 8 | data[pos + 5]) + 1u;
                uint32_t pkt_len = (uint32_t)CCSDS_HDR_LEN + data_field_len;
                if (pkt_len > CCSDS_MAX_PKT) {
                    /* Oversized: skip to next M_PDU */
                    s->ccsds_need = 0;
                    break;
                }
                s->ccsds_need = pkt_len;
                s->ccsds_fill = 0;
            }

            uint32_t available = MPDU_DATA_LEN - pos;
            uint32_t want      = s->ccsds_need - s->ccsds_fill;
            uint32_t to_copy   = (available < want) ? available : want;

            memcpy(s->ccsds_buf + s->ccsds_fill, data + pos, to_copy);
            s->ccsds_fill += to_copy;
            pos           += to_copy;

            if (s->ccsds_fill >= s->ccsds_need) {
                on_ccsds_packet(s, s->ccsds_buf, s->ccsds_need,
                                send_tlv, drain);
                s->ccsds_need = 0;
            }
        }
    } else {
        /* Pure continuation: no new packet starts here */
        if (s->ccsds_need > 0) {
            uint32_t want    = s->ccsds_need - s->ccsds_fill;
            uint32_t to_copy = (MPDU_DATA_LEN < want) ? MPDU_DATA_LEN : want;
            if (s->ccsds_fill + to_copy <= CCSDS_MAX_PKT) {
                memcpy(s->ccsds_buf + s->ccsds_fill, data, to_copy);
                s->ccsds_fill += to_copy;
            }
            if (s->ccsds_fill >= s->ccsds_need) {
                on_ccsds_packet(s, s->ccsds_buf, s->ccsds_need,
                                send_tlv, drain);
                s->ccsds_need = 0;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

lrit_state_t *lrit_alloc(void)
{
    lrit_state_t *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;

    s->ccsds_buf = malloc(CCSDS_MAX_PKT);
    if (!s->ccsds_buf) {
        free(s);
        return NULL;
    }

    s->accum_buf = malloc(ACCUM_INIT_CAP);
    if (!s->accum_buf) {
        free(s->ccsds_buf);
        free(s);
        return NULL;
    }
    s->accum_cap = ACCUM_INIT_CAP;

    return s;
}

void lrit_free(lrit_state_t *s)
{
    if (!s)
        return;
    free(s->ccsds_buf);
    free(s->accum_buf);
    free(s->row_buf);
    free(s);
}

void lrit_ingest_vcdu(lrit_state_t *s,
                      const uint8_t *vcdu_892,
                      void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                      void (*drain)(void))
{
    /* Extract VCID: bits [9:4] of the Transfer Frame Primary Header */
    unsigned vcid = ((unsigned)(vcdu_892[1] & 0x0Fu) << 2)
                  | ((unsigned)(vcdu_892[2] >> 6));

    /* Skip idle/fill frames */
    if (vcid == VCID_FILL)
        return;

    /* M_PDU header: bytes 6-7 */
    uint16_t fhp = (uint16_t)(((unsigned)(vcdu_892[6] & 0x07u) << 8)
                             |  (unsigned)vcdu_892[7]);

    /* M_PDU data field: bytes 8..891 (884 bytes) */
    ccsds_process_mpdu(s, vcdu_892 + 8, fhp, send_tlv, drain);
}
