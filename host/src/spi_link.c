#include "spi_link.h"

#include <stdlib.h>
#include <string.h>

#define SPI_LINK_CAP 16384u

struct spi_link {
    uint8_t buf[SPI_LINK_CAP];
    size_t head;
    size_t tail;
    size_t count;
};

spi_link_t *spi_link_new_inproc(void) {
    spi_link_t *l = (spi_link_t *)calloc(1, sizeof(spi_link_t));
    return l;
}

void spi_link_free(spi_link_t *l) {
    free(l);
}

void spi_link_send(spi_link_t *l, const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (l->count >= SPI_LINK_CAP) return;  // drop on overflow; FPGA can resync on next full state
        l->buf[l->tail] = buf[i];
        l->tail = (l->tail + 1) % SPI_LINK_CAP;
        l->count++;
    }
}

size_t spi_link_recv(spi_link_t *l, uint8_t *out, size_t cap) {
    size_t n = l->count < cap ? l->count : cap;
    for (size_t i = 0; i < n; i++) {
        out[i] = l->buf[l->head];
        l->head = (l->head + 1) % SPI_LINK_CAP;
    }
    l->count -= n;
    return n;
}
