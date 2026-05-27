#ifndef TRIAD_WIRE_PROTOCOL_H
#define TRIAD_WIRE_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#include "touch.h"
#include "ui_state.h"

#define WIRE_MAGIC 0xA5u

typedef enum : uint8_t {
    OP_FULL_STATE     = 0x01u,
    OP_PARTIAL_STATE  = 0x02u,
    OP_TOUCH_EVENT    = 0x03u,
    OP_HEARTBEAT      = 0x04u,
    OP_SPECTRUM_BINS  = 0x05u,
} wire_opcode_t;

#define WIRE_HEADER_BYTES 4
#define WIRE_TRAILER_BYTES 2
#define WIRE_OVERHEAD (WIRE_HEADER_BYTES + WIRE_TRAILER_BYTES)
#define WIRE_MAX_PAYLOAD 1024
#define WIRE_MAX_FRAME (WIRE_OVERHEAD + WIRE_MAX_PAYLOAD)

uint16_t wire_crc16(const uint8_t *buf, size_t len);

size_t wire_pack_full(uint8_t *out, size_t out_cap, const ui_state_t *st);
size_t wire_pack_partial(uint8_t *out, size_t out_cap,
                         const ui_state_t *prev, const ui_state_t *curr);
size_t wire_pack_touch(uint8_t *out, size_t out_cap, const touch_event_t *ev);
size_t wire_pack_heartbeat(uint8_t *out, size_t out_cap);
size_t wire_pack_spectrum(uint8_t *out, size_t out_cap, const uint16_t bins[UI_SPECTRUM_BINS]);

typedef enum {
    WIRE_OK             = 0,
    WIRE_INCOMPLETE     = 1,
    WIRE_NO_MAGIC       = 2,
    WIRE_BAD_CRC        = 3,
    WIRE_BAD_OPCODE     = 4,
    WIRE_BAD_VERSION    = 5,
    WIRE_BAD_LENGTH     = 6,
} wire_status_t;

typedef struct {
    wire_status_t status;
    size_t        consumed;
} wire_result_t;

wire_result_t wire_consume(const uint8_t *buf, size_t len,
                           ui_state_t *st_inout,
                           touch_event_queue_t *tq_inout);

#endif
