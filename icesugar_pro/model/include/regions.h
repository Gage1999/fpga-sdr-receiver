#ifndef TRIAD_REGIONS_H
#define TRIAD_REGIONS_H

#include <stdint.h>

#include "ui_state.h"

typedef enum : uint8_t {
    R_NONE      = 0,
    R_STATUS    = 1,
    R_SPECTRUM  = 2,
    R_WATERFALL = 3,
    R_GOES      = 4,
    R_OVERLAY   = 5,
    R_ADSB      = 6,
} region_kind_t;

typedef struct {
    uint8_t  kind;
    uint16_t x0, y0;
    uint16_t w, h;
} region_t;

#define STATUS_H     64
#define SPECTRUM_H   128
#define GOES_FULL_H  480
#define ADSB_FULL_H  480  // full-screen ADS-B map, with only a floating mode button

region_t region_at(uint16_t x, uint16_t y, uint8_t layout);
region_t region_for_kind(uint8_t kind, uint8_t layout);

#endif
