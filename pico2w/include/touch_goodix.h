#ifndef TRIAD_TOUCH_GOODIX_H
#define TRIAD_TOUCH_GOODIX_H

#include <stdbool.h>

#include "touch.h"

void touch_goodix_init(void);
bool touch_goodix_poll(touch_event_t *out);

#endif
