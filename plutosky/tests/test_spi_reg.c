/*
 * AXI SPI register read-back test.
 * Verifies the SPI peripheral at 0x7C440000 is accessible and responds correctly.
 *
 * Usage: ./test_spi_reg
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#define SPI_BASE  0x7C440000
#define SPI_RANGE 0x1000

#define SRR    0x40
#define SPICR  0x60
#define SPISR  0x64
#define SPIDTR 0x68
#define SPIDRR 0x6C
#define SPISSR 0x70

#define SPICR_SPE       0x002
#define SPICR_MASTER    0x004
#define SPICR_CPOL      0x008
#define SPICR_CPHA      0x010
#define SPICR_TXRST     0x020
#define SPICR_RXRST     0x040
#define SPICR_MANUAL_SS 0x080
#define SPICR_INHIBIT   0x100

#define SPISR_TX_EMPTY 0x04

static volatile uint32_t *spi;

static void spi_wr(int off, uint32_t val) { spi[off / 4] = val; }
static uint32_t spi_rd(int off)           { return spi[off / 4]; }

int main(void)
{
    int pass = 1;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    spi = mmap(NULL, SPI_RANGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SPI_BASE);
    if (spi == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    printf("AXI SPI at 0x%08X\n", SPI_BASE);

    /* Reset */
    spi_wr(SRR, 0x0000000A);

    /* Read SPICR after reset - should be 0x180 (INHIBIT | MANUAL_SS set by reset) */
    uint32_t cr = spi_rd(SPICR);
    printf("SPICR after reset: 0x%03X (expect 0x180)\n", cr);
    if (cr != 0x180) { printf("  FAIL\n"); pass = 0; }
    else              { printf("  PASS\n"); }

    /* Write a known value to SPICR and read it back */
    uint32_t cr_set = SPICR_INHIBIT | SPICR_MANUAL_SS | SPICR_RXRST | SPICR_TXRST |
                      SPICR_CPHA | SPICR_CPOL | SPICR_MASTER | SPICR_SPE;
    spi_wr(SPICR, cr_set);
    uint32_t cr_rb = spi_rd(SPICR);
    /* RXRST and TXRST self-clear, so mask them out for comparison */
    uint32_t mask = ~(SPICR_RXRST | SPICR_TXRST);
    printf("SPICR write=0x%03X readback=0x%03X (RXRST/TXRST self-clear, masked)\n",
           cr_set & mask, cr_rb & mask);
    if ((cr_rb & mask) != (cr_set & mask)) { printf("  FAIL\n"); pass = 0; }
    else                                    { printf("  PASS\n"); }

    /* Read SPISSR - bit 0 must be 1 (CS[0] deasserted, active-low).
     * C_NUM_SS_BITS=1: only bit 0 is implemented; bits [31:1] read as 0. */
    uint32_t ssr = spi_rd(SPISSR);
    printf("SPISSR: 0x%08X (expect bit 0 = 1, upper bits 0 with 1 SS)\n", ssr);
    if (!(ssr & 0x1)) { printf("  FAIL\n"); pass = 0; }
    else               { printf("  PASS\n"); }

    /* Read SPISR - TX_EMPTY should be set when TX FIFO is empty */
    uint32_t sr = spi_rd(SPISR);
    printf("SPISR: 0x%02X  TX_EMPTY=%d (expect 1)  Slave_MODF=%d (expect 0)\n",
           sr, !!(sr & SPISR_TX_EMPTY), !!(sr & 0x20));
    if (!(sr & SPISR_TX_EMPTY)) { printf("  FAIL\n"); pass = 0; }
    else                         { printf("  PASS\n"); }
    if (sr & 0x20) { printf("  NOTE: Slave_MODF set (bit 5) - harmless in master-only mode\n"); }

    printf("\n%s\n", pass ? "ALL PASS" : "SOME TESTS FAILED");

    munmap((void *)spi, SPI_RANGE);
    close(fd);
    return pass ? 0 : 1;
}
