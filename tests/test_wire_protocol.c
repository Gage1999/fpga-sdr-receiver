#include <string.h>

#include "test_helpers.h"
#include "touch.h"
#include "ui_state.h"
#include "wire_protocol.h"

T_CASE(crc_known_vector) {
    // CRC16-CCITT, init 0xFFFF over "123456789" = 0x29B1
    const uint8_t s[] = "123456789";
    T_EXPECT_EQ(wire_crc16(s, 9), 0x29B1);
    return 0;
}

T_CASE(full_state_roundtrip) {
    ui_state_t src;
    ui_state_default(&src);
    src.freq_hz = 123456789u;
    src.volume = 42;
    for (int i = 0; i < UI_SPECTRUM_BINS; i++) src.spectrum_bins[i] = (uint16_t)(i * 11);

    uint8_t frame[WIRE_MAX_FRAME];
    size_t n = wire_pack_full(frame, sizeof(frame), &src);
    T_EXPECT(n > 0);

    ui_state_t dst;
    memset(&dst, 0, sizeof(dst));
    wire_result_t r = wire_consume(frame, n, &dst, NULL);
    T_EXPECT_EQ(r.status, WIRE_OK);
    T_EXPECT_EQ(r.consumed, n);
    T_EXPECT_EQ(memcmp(&src, &dst, sizeof(src)), 0);
    return 0;
}

T_CASE(partial_diff_convergence) {
    ui_state_t prev, curr;
    ui_state_default(&prev);
    curr = prev;
    curr.freq_hz = 99999999u;
    curr.volume = 81;
    curr.spectrum_bins[10] = 0xBEEF;

    uint8_t frame[WIRE_MAX_FRAME];
    size_t n = wire_pack_partial(frame, sizeof(frame), &prev, &curr);
    T_EXPECT(n > 0);

    ui_state_t recv = prev;
    wire_result_t r = wire_consume(frame, n, &recv, NULL);
    T_EXPECT_EQ(r.status, WIRE_OK);
    T_EXPECT_EQ(memcmp(&recv, &curr, sizeof(curr)), 0);
    return 0;
}

T_CASE(no_diff_emits_nothing) {
    ui_state_t s;
    ui_state_default(&s);
    uint8_t frame[64];
    size_t n = wire_pack_partial(frame, sizeof(frame), &s, &s);
    T_EXPECT_EQ(n, 0);
    return 0;
}

T_CASE(touch_event_roundtrip) {
    touch_event_t tx = { .x = 400, .y = 240, .kind = TOUCH_TAP };
    uint8_t frame[WIRE_OVERHEAD + 5];
    size_t n = wire_pack_touch(frame, sizeof(frame), &tx);
    T_EXPECT(n > 0);

    touch_event_queue_t tq; touch_queue_init(&tq);
    ui_state_t st; ui_state_default(&st);
    wire_result_t r = wire_consume(frame, n, &st, &tq);
    T_EXPECT_EQ(r.status, WIRE_OK);
    touch_event_t rx;
    T_EXPECT(touch_queue_pop(&tq, &rx));
    T_EXPECT_EQ(rx.x, 400);
    T_EXPECT_EQ(rx.y, 240);
    T_EXPECT_EQ(rx.kind, TOUCH_TAP);
    return 0;
}

T_CASE(crc_corruption_rejected) {
    ui_state_t s; ui_state_default(&s);
    uint8_t frame[WIRE_MAX_FRAME];
    size_t n = wire_pack_full(frame, sizeof(frame), &s);
    frame[10] ^= 0x55;  // corrupt mid-payload

    ui_state_t recv;
    memset(&recv, 0xCD, sizeof(recv));
    ui_state_t before = recv;
    wire_result_t r = wire_consume(frame, n, &recv, NULL);
    T_EXPECT_EQ(r.status, WIRE_BAD_CRC);
    T_EXPECT_EQ(memcmp(&recv, &before, sizeof(recv)), 0);
    return 0;
}

T_CASE(resync_after_garbage_prefix) {
    ui_state_t s; ui_state_default(&s);
    uint8_t real[WIRE_MAX_FRAME];
    size_t n = wire_pack_full(real, sizeof(real), &s);

    uint8_t stream[WIRE_MAX_FRAME + 8];
    const uint8_t garbage[8] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    memcpy(stream, garbage, 8);
    memcpy(stream + 8, real, n);

    // First consume should skip garbage.
    wire_result_t r1 = wire_consume(stream, n + 8, NULL, NULL);
    T_EXPECT_EQ(r1.status, WIRE_NO_MAGIC);
    T_EXPECT_EQ(r1.consumed, 8);

    // Then consume the real frame.
    ui_state_t recv;
    memset(&recv, 0, sizeof(recv));
    wire_result_t r2 = wire_consume(stream + r1.consumed, n + 8 - r1.consumed, &recv, NULL);
    T_EXPECT_EQ(r2.status, WIRE_OK);
    T_EXPECT_EQ(memcmp(&recv, &s, sizeof(s)), 0);
    return 0;
}

T_CASE(incomplete_frame_reports_incomplete) {
    ui_state_t s; ui_state_default(&s);
    uint8_t frame[WIRE_MAX_FRAME];
    size_t n = wire_pack_full(frame, sizeof(frame), &s);

    wire_result_t r = wire_consume(frame, n - 1, NULL, NULL);
    T_EXPECT_EQ(r.status, WIRE_INCOMPLETE);
    T_EXPECT_EQ(r.consumed, 0);
    return 0;
}

int main(void) {
    T_RUN(crc_known_vector);
    T_RUN(full_state_roundtrip);
    T_RUN(partial_diff_convergence);
    T_RUN(no_diff_emits_nothing);
    T_RUN(touch_event_roundtrip);
    T_RUN(crc_corruption_rejected);
    T_RUN(resync_after_garbage_prefix);
    T_RUN(incomplete_frame_reports_incomplete);
    T_FINISH();
}
