/* goes_lrit.h -- LRIT/CCSDS/Rice parser, outputs 800-px TLV_IMAGE_ROW packets */

#ifndef GOES_LRIT_H
#define GOES_LRIT_H

#include <stdint.h>

typedef struct lrit_state lrit_state_t;

/* Allocate and initialize parser state. Returns NULL on failure. */
lrit_state_t *lrit_alloc(void);

/* Free all resources. */
void lrit_free(lrit_state_t *s);

/*
 * Feed one 892-byte decoded VCDU frame (rs_decode_frame output).
 *
 * Reassembles CCSDS Space Packets from M_PDU data, assembles LRIT image
 * files from CCSDS packet data fields, Rice-decompresses each scanline
 * (CCSDS 121.0-B-3, bpp=8, J=16), downsamples to 800 pixels, then calls:
 *   send_tlv(TLV_IMAGE_ROW, row_800, 800)
 * for each complete scanline.  drain() is called after each send_tlv.
 *
 * Non-image LRIT files and unrecognized packets are silently skipped.
 */
void lrit_ingest_vcdu(lrit_state_t *s,
                      const uint8_t *vcdu_892,
                      void (*send_tlv)(uint8_t, const uint8_t *, uint16_t),
                      void (*drain)(void));

#endif /* GOES_LRIT_H */
