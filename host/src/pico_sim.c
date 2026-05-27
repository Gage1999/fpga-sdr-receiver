#include "pico_sim.h"

#include "ui_logic.h"

void pico_sim_init(pico_sim_t *s) {
    ui_logic_init(&s->L);
}

void pico_sim_tick(pico_sim_t *s) {
    (void)ui_logic_tick(&s->L);
}
