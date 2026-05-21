#!/usr/bin/env python3
# Run from the host: python3 tests/test_spi.py
# Sends devmem commands to the board over SSH to probe the AXI SPI controller.
#
# JP5 wiring: pin7=CS(V10)  pin9=SCK(U9)  pin11=MOSI(U10)  pin13=MISO(T9)

import os, subprocess, sys

BOARD_HOST = "192.168.2.1"
BOARD_USER = "root"

# AXI Quad SPI register addresses (base 0x7C440000)
SRR    = 0x7C440040   # Software Reset Register - write-only, write 0x0000000A to reset
SPICR  = 0x7C440060
SPISR  = 0x7C440064
SPIDTR = 0x7C440068
SPIDRR = 0x7C44006C
SPISSR = 0x7C440070

# SPICR values (PG153 bit map: inhibit=0x100 manual_ss=0x080 rxrst=0x040 txrst=0x020 cpha=0x010 cpol=0x008 master=0x004 spe=0x002)
SPICR_INIT  = 0x1FE   # inhibit + manual_ss + rx/tx reset + cpha + cpol + master + spe
SPICR_RUN   = 0x09E   # manual_ss + cpha + cpol + master + spe (no inhibit)
SRR_RESET   = 0x0000000A

_key = os.environ.get("PLUTO_SSH_KEY")
SSH_OPTS = [
    *([ "-i", _key ] if _key else []),
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "-o", "BatchMode=yes",
]


def pause(msg):
    try:
        input(f"  {msg}  [Enter]")
    except EOFError:
        pass


def main():
    proc = subprocess.Popen(
        ["ssh"] + SSH_OPTS + [f"{BOARD_USER}@{BOARD_HOST}", "sh"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    def board(cmd):
        sentinel = b"___DONE___\n"
        proc.stdin.write(f"{cmd}\necho ___DONE___\n".encode())
        proc.stdin.flush()
        lines = []
        while True:
            line = proc.stdout.readline()
            if line == sentinel:
                break
            lines.append(line.decode().rstrip())
        return lines

    def wr(addr, val):
        board(f"devmem 0x{addr:08X} 32 0x{val:08X}")

    def rd(addr):
        out = board(f"devmem 0x{addr:08X} 32")
        return int(out[0], 16) if out else None

    print("=" * 60)
    print("  PlutoSky AXI SPI Probe  (axi_spi1 @ 0x7C440000)")
    print("  JP5: pin7=CS  pin9=SCK  pin11=MOSI  pin13=MISO")
    print("=" * 60)
    print()

    # Reset then init SPI controller
    wr(SRR, SRR_RESET)
    wr(SPICR, SPICR_INIT)
    wr(SPISSR, 0xFFFFFFFF)
    wr(SPICR, SPICR_RUN)

    # Verify register access
    spicr = rd(SPICR)
    print(f"  SPICR read back: 0x{spicr:08X}", end="  ")
    if spicr == SPICR_RUN:
        print("OK")
    else:
        print(f"WARNING: expected 0x{SPICR_RUN:08X}")
    print()

    # CS test
    print("--- CS (JP5 pin 7, V10) ---")
    wr(SPISSR, 0xFFFFFFFF)
    pause("CS deasserted - expect ~3.3 V on pin 7")
    wr(SPISSR, 0xFFFFFFFE)
    pause("CS asserted   - expect ~0.0 V on pin 7")
    wr(SPISSR, 0xFFFFFFFF)
    print()

    # SCK idle test
    print("--- SCK (JP5 pin 9, U9) ---")
    print("  SCK idles HIGH in Mode 3 (CPOL=1) when no transfer is active.")
    pause("No transfer active - expect ~3.3 V on pin 9")
    print()

    # MOSI test - send bytes with CS asserted, check idle level after last bit
    print("--- MOSI (JP5 pin 11, U10) ---")
    wr(SPISSR, 0xFFFFFFFE)

    # 0xFF: last bit sent is 1 -> MOSI idles high after transfer
    for _ in range(4):
        wr(SPIDTR, 0xFF)
    pause("Sent 0xFF bytes - expect ~3.3 V on pin 11 (last bit = 1)")

    # 0x00: last bit sent is 0 -> MOSI idles low after transfer
    for _ in range(4):
        wr(SPIDTR, 0x00)
    pause("Sent 0x00 bytes - expect ~0.0 V on pin 11 (last bit = 0)")

    wr(SPISSR, 0xFFFFFFFF)
    print()

    # MISO
    print("--- MISO (JP5 pin 13, T9) ---")
    print("  Input only. To verify: connect pin 13 to 3.3V and run apt_tx.py.")
    print()

    proc.stdin.close()
    proc.wait()
    print("Done.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(1)
