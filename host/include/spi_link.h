#ifndef TRIAD_SPI_LINK_H
#define TRIAD_SPI_LINK_H

#include <stddef.h>
#include <stdint.h>

// In-process Pico->FPGA SPI link. The harness uses one of these to ferry the
// exact wire bytes between sim halves. No memcpy(struct) shortcuts - bytes
// match what real SPI will see, which is the discipline that catches
// endianness and packing bugs before hardware bring-up.

typedef struct spi_link spi_link_t;

spi_link_t *spi_link_new_inproc(void);
void spi_link_free(spi_link_t *l);

void spi_link_send(spi_link_t *l, const uint8_t *buf, size_t len);

// Non-blocking; returns bytes copied (0 if empty).
size_t spi_link_recv(spi_link_t *l, uint8_t *out, size_t cap);

#endif
