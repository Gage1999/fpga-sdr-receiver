#!/usr/bin/env python3
"""
test_gpio.py — Interactive GPIO probe for PlutoSky 7020 (fishball7020)

Drives each JP5 pin HIGH then LOW in sequence, pausing between each so you
can measure the voltage with a multimeter.

Run from the project root:
    python3 tests/test_gpio.py

Requirements:
    - Board reachable via SSH (configure ~/.ssh/config with a 'pluto-usb' host,
      or set PLUTO_SSH_KEY to override the key path)
    - fishball7020_rf bitstream loaded (Bank 13 IOBUFs on JP5)
    - gpioset available on the board
"""

import subprocess
import sys
import os

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BOARD_HOST = "192.168.2.1"
BOARD_USER = "root"

GPIO_LINES = [
    (71, "JP5-7   3V3_IO1  EMIO[17]  V10"),
    (72, "JP5-9   3V3_IO2  EMIO[18]  U9"),
    (73, "JP5-11  3V3_IO3  EMIO[19]  U10"),
    (74, "JP5-13  3V3_IO4  EMIO[20]  T9"),
]

_key = os.environ.get("PLUTO_SSH_KEY")
SSH_OPTS = [
    *([ "-i", _key ] if _key else []),
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "-o", "BatchMode=yes",
]

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

def main() -> None:
    print("=" * 62)
    print("  PlutoSky 7020 — GPIO Interactive Probe")
    print(f"  Board : {BOARD_HOST}")
    print("  Press Enter after each measurement.")
    print("=" * 62)
    print()

    proc = subprocess.Popen(
        ["ssh"] + SSH_OPTS + [f"{BOARD_USER}@{BOARD_HOST}", "sh"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    def board(cmd: str) -> None:
        sentinel = b"___DONE___\n"
        proc.stdin.write(f"{cmd}\necho ___DONE___\n".encode())
        proc.stdin.flush()
        while proc.stdout.readline() != sentinel:
            pass

    board("killall gpioset 2>/dev/null; true")

    for line, label in GPIO_LINES:
        jp_pin = label.split()[0]
        phys   = jp_pin.replace("JP5-", "JP5 pin ")

        board(f"killall gpioset 2>/dev/null; sleep 0.15; gpioset --mode=signal gpiochip0 {line}=1 &")
        input(f"  [ HIGH ]  {label}  →  probe {phys}  (expect ~3.3 V)  [Enter]")

        board(f"killall gpioset 2>/dev/null; sleep 0.15; gpioset --mode=signal gpiochip0 {line}=0 &")
        input(f"  [  LOW ]  {label}  →  probe {phys}  (expect ~0.0 V)  [Enter]")

        print()

    board("killall gpioset 2>/dev/null; sleep 0.2; "
          "gpioset --mode=signal gpiochip0 71=0 72=0 73=0 74=0 & sleep 0.2; killall gpioset 2>/dev/null")
    proc.stdin.close()
    proc.wait()
    print("All pins released (high-Z). Probe done.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(1)
