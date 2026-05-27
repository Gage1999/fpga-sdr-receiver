#ifndef TRIAD_PICO_SIM_H
#define TRIAD_PICO_SIM_H

#include "ui_logic.h"

typedef struct {
    ui_logic_t L;
} pico_sim_t;

void pico_sim_init(pico_sim_t *s);
void pico_sim_tick(pico_sim_t *s);

#endif
