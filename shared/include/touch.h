#ifndef TRIAD_TOUCH_H
#define TRIAD_TOUCH_H

#include <stdbool.h>
#include <stdint.h>

typedef enum : uint8_t {
    TOUCH_DOWN    = 0,
    TOUCH_MOVE    = 1,
    TOUCH_UP      = 2,
    TOUCH_TAP     = 3,
    TOUCH_LONG    = 4,
    TOUCH_SWIPE_L = 5,
    TOUCH_SWIPE_R = 6,
    TOUCH_SWIPE_U = 7,
    TOUCH_SWIPE_D = 8,
} touch_kind_t;

typedef struct {
    uint16_t x;
    uint16_t y;
    uint8_t  kind;
    uint8_t  reserved;
} touch_event_t;

#define TOUCH_QUEUE_CAP 32

typedef struct {
    touch_event_t buf[TOUCH_QUEUE_CAP];
    uint8_t head;
    uint8_t tail;
    uint8_t count;
    uint8_t reserved;
} touch_event_queue_t;

static inline void touch_queue_init(touch_event_queue_t *q) {
    q->head = q->tail = q->count = 0;
}

static inline bool touch_queue_push(touch_event_queue_t *q, const touch_event_t *ev) {
    if (q->count >= TOUCH_QUEUE_CAP) return false;
    q->buf[q->tail] = *ev;
    q->tail = (uint8_t)((q->tail + 1) % TOUCH_QUEUE_CAP);
    q->count++;
    return true;
}

static inline bool touch_queue_pop(touch_event_queue_t *q, touch_event_t *out) {
    if (q->count == 0) return false;
    *out = q->buf[q->head];
    q->head = (uint8_t)((q->head + 1) % TOUCH_QUEUE_CAP);
    q->count--;
    return true;
}

#endif
