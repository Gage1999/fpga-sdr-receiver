#include "wire_protocol.h"

#include <string.h>

_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
               "wire protocol assumes little-endian host");

// CRC16-CCITT, init 0xFFFF, poly 0x1021, no reflection.
uint16_t wire_crc16(const uint8_t *buf, size_t len) {
    uint16_t crc = 0xFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)((uint16_t)buf[i] << 8);
        for (int b = 0; b < 8; b++) {
            if (crc & 0x8000u) crc = (uint16_t)((crc << 1) ^ 0x1021u);
            else               crc = (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static void put_u16_le(uint8_t *out, uint16_t v) {
    out[0] = (uint8_t)(v & 0xFFu);
    out[1] = (uint8_t)((v >> 8) & 0xFFu);
}

static uint16_t get_u16_le(const uint8_t *in) {
    return (uint16_t)((uint16_t)in[0] | ((uint16_t)in[1] << 8));
}

// Build header [magic, opcode, len_lo, len_hi]; return offset where payload starts.
static size_t write_header(uint8_t *out, uint8_t opcode, uint16_t payload_len) {
    out[0] = WIRE_MAGIC;
    out[1] = opcode;
    put_u16_le(out + 2, payload_len);
    return WIRE_HEADER_BYTES;
}

// Append CRC16 over [opcode .. payload end] at offset; return total frame length.
static size_t finish_frame(uint8_t *out, size_t payload_len) {
    uint16_t crc = wire_crc16(out + 1, WIRE_HEADER_BYTES - 1 + payload_len);
    put_u16_le(out + WIRE_HEADER_BYTES + payload_len, crc);
    return WIRE_HEADER_BYTES + payload_len + WIRE_TRAILER_BYTES;
}

size_t wire_pack_full(uint8_t *out, size_t out_cap, const ui_state_t *st) {
    const uint16_t pl = (uint16_t)sizeof(ui_state_t);
    if (out_cap < (size_t)pl + WIRE_OVERHEAD) return 0;
    write_header(out, OP_FULL_STATE, pl);
    memcpy(out + WIRE_HEADER_BYTES, st, sizeof(*st));
    return finish_frame(out, pl);
}

// Walk prev/curr byte-by-byte; emit runs of differing bytes as [offset:u16][len:u16][bytes...]
size_t wire_pack_partial(uint8_t *out, size_t out_cap,
                         const ui_state_t *prev, const ui_state_t *curr) {
    const uint8_t *pa = (const uint8_t *)prev;
    const uint8_t *pb = (const uint8_t *)curr;
    const size_t total = sizeof(ui_state_t);

    if (out_cap < WIRE_OVERHEAD) return 0;
    uint8_t *payload = out + WIRE_HEADER_BYTES;
    size_t pl = 0;
    const size_t pl_cap = out_cap - WIRE_OVERHEAD;

    size_t i = 0;
    while (i < total) {
        if (pa[i] == pb[i]) { i++; continue; }
        size_t j = i;
        while (j < total && pa[j] != pb[j]) j++;
        const size_t run_len = j - i;
        if (pl + 4 + run_len > pl_cap || run_len > 0xFFFFu) return 0;
        put_u16_le(payload + pl, (uint16_t)i);
        put_u16_le(payload + pl + 2, (uint16_t)run_len);
        memcpy(payload + pl + 4, pb + i, run_len);
        pl += 4 + run_len;
        i = j;
    }

    if (pl == 0) return 0;  // no diffs
    write_header(out, OP_PARTIAL_STATE, (uint16_t)pl);
    return finish_frame(out, pl);
}

size_t wire_pack_touch(uint8_t *out, size_t out_cap, const touch_event_t *ev) {
    const uint16_t pl = 5;
    if (out_cap < (size_t)pl + WIRE_OVERHEAD) return 0;
    write_header(out, OP_TOUCH_EVENT, pl);
    put_u16_le(out + WIRE_HEADER_BYTES + 0, ev->x);
    put_u16_le(out + WIRE_HEADER_BYTES + 2, ev->y);
    out[WIRE_HEADER_BYTES + 4] = ev->kind;
    return finish_frame(out, pl);
}

size_t wire_pack_heartbeat(uint8_t *out, size_t out_cap) {
    if (out_cap < WIRE_OVERHEAD) return 0;
    write_header(out, OP_HEARTBEAT, 0);
    return finish_frame(out, 0);
}

size_t wire_pack_spectrum(uint8_t *out, size_t out_cap, const uint16_t bins[UI_SPECTRUM_BINS]) {
    const uint16_t pl = (uint16_t)(UI_SPECTRUM_BINS * sizeof(uint16_t));
    if (out_cap < (size_t)pl + WIRE_OVERHEAD) return 0;
    write_header(out, OP_SPECTRUM_BINS, pl);
    uint8_t *payload = out + WIRE_HEADER_BYTES;
    for (size_t i = 0; i < UI_SPECTRUM_BINS; i++) {
        put_u16_le(payload + i * 2, bins[i]);
    }
    return finish_frame(out, pl);
}

// Apply a partial state diff payload to st. Bounds-check every chunk.
static int apply_partial(ui_state_t *st, const uint8_t *payload, size_t pl) {
    uint8_t *dst = (uint8_t *)st;
    const size_t total = sizeof(ui_state_t);
    size_t i = 0;
    while (i < pl) {
        if (i + 4 > pl) return -1;
        uint16_t off = get_u16_le(payload + i);
        uint16_t len = get_u16_le(payload + i + 2);
        i += 4;
        if (i + len > pl) return -1;
        if ((size_t)off + (size_t)len > total) return -1;
        memcpy(dst + off, payload + i, len);
        i += len;
    }
    return 0;
}

wire_result_t wire_consume(const uint8_t *buf, size_t len,
                           ui_state_t *st_inout,
                           touch_event_queue_t *tq_inout) {
    wire_result_t out;

    // Hunt for magic.
    size_t skip = 0;
    while (skip < len && buf[skip] != WIRE_MAGIC) skip++;
    if (skip > 0) {
        // Caller can decide whether to log. We just report consumed-as-noise.
        out.status   = WIRE_NO_MAGIC;
        out.consumed = skip;
        return out;
    }

    if (len < WIRE_HEADER_BYTES) { out.status = WIRE_INCOMPLETE; out.consumed = 0; return out; }

    const uint8_t opcode = buf[1];
    const uint16_t pl    = get_u16_le(buf + 2);
    if (pl > WIRE_MAX_PAYLOAD) {
        out.status = WIRE_BAD_LENGTH; out.consumed = 1; return out;  // skip past magic
    }

    const size_t frame_len = WIRE_HEADER_BYTES + pl + WIRE_TRAILER_BYTES;
    if (len < frame_len) { out.status = WIRE_INCOMPLETE; out.consumed = 0; return out; }

    const uint16_t want_crc = wire_crc16(buf + 1, WIRE_HEADER_BYTES - 1 + pl);
    const uint16_t got_crc  = get_u16_le(buf + WIRE_HEADER_BYTES + pl);
    if (want_crc != got_crc) {
        out.status = WIRE_BAD_CRC; out.consumed = frame_len; return out;
    }

    const uint8_t *payload = buf + WIRE_HEADER_BYTES;

    switch (opcode) {
    case OP_FULL_STATE: {
        if (pl != sizeof(ui_state_t)) { out.status = WIRE_BAD_LENGTH; out.consumed = frame_len; return out; }
        if (payload[0] != (uint8_t)UI_STATE_VERSION) { out.status = WIRE_BAD_VERSION; out.consumed = frame_len; return out; }
        if (st_inout) memcpy(st_inout, payload, sizeof(ui_state_t));
        out.status = WIRE_OK; out.consumed = frame_len; return out;
    }
    case OP_PARTIAL_STATE: {
        if (st_inout && apply_partial(st_inout, payload, pl) != 0) {
            out.status = WIRE_BAD_LENGTH; out.consumed = frame_len; return out;
        }
        out.status = WIRE_OK; out.consumed = frame_len; return out;
    }
    case OP_TOUCH_EVENT: {
        if (pl != 5) { out.status = WIRE_BAD_LENGTH; out.consumed = frame_len; return out; }
        if (tq_inout) {
            touch_event_t ev = {
                .x = get_u16_le(payload + 0),
                .y = get_u16_le(payload + 2),
                .kind = payload[4],
                .reserved = 0,
            };
            (void)touch_queue_push(tq_inout, &ev);
        }
        out.status = WIRE_OK; out.consumed = frame_len; return out;
    }
    case OP_HEARTBEAT: {
        if (pl != 0) { out.status = WIRE_BAD_LENGTH; out.consumed = frame_len; return out; }
        out.status = WIRE_OK; out.consumed = frame_len; return out;
    }
    case OP_SPECTRUM_BINS: {
        if (pl != UI_SPECTRUM_BINS * sizeof(uint16_t)) {
            out.status = WIRE_BAD_LENGTH; out.consumed = frame_len; return out;
        }
        if (st_inout) {
            for (size_t i = 0; i < UI_SPECTRUM_BINS; i++) {
                st_inout->spectrum_bins[i] = get_u16_le(payload + i * 2);
            }
        }
        out.status = WIRE_OK; out.consumed = frame_len; return out;
    }
    default:
        out.status = WIRE_BAD_OPCODE; out.consumed = frame_len; return out;
    }
}
