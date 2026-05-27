#!/usr/bin/env python3
"""
spi_capture.py - Capture and decode SPI IQ data via Saleae Logic 2 automation API.

Connects to Logic 2, triggers a timed capture, runs the SPI analyzer (Mode 3:
CPOL=1, CPHA=1, MSB first, 8 bits/transfer), exports the raw bytes, then
reconstructs and prints each 32-bit IQ word.

Requirements:
    pip install logic2-automation

Logic 2 must be running with automation enabled:
    Logic 2 -> Preferences -> Developer -> Enable Automation API

Usage:
    python tests/spi_capture.py                         # defaults: CLK=0 MOSI=1 CS=2
    python tests/spi_capture.py --clk 0 --mosi 1 --cs 2
    python tests/spi_capture.py --clk 0 --mosi 1 --cs 2 --duration 10
    python tests/spi_capture.py --load spi_bytes.csv    # re-parse a saved export
"""

import argparse
import csv
import os
import sys
import time

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(DATA_DIR, exist_ok=True)

# SPI analyzer setting strings for Logic 2.
# If the capture fails with a settings error, open Logic 2, add an SPI analyzer
# manually, and copy the exact dropdown text for CPOL/CPHA into these constants.
CPOL1_STRING = "Clock is Low when inactive (CPOL = 0)"
CPHA1_STRING = 0   # CPHA=0: AXI SPI hardware default (C_CPHA not set in BD)


def capture(clk_ch, mosi_ch, cs_ch, duration, out_csv):
    try:
        from saleae import automation
    except ImportError:
        sys.exit("Install logic2-automation:  pip install logic2-automation")

    print(f"Connecting to Logic 2 ...")
    try:
        mgr = automation.Manager.connect(port=10430)
    except Exception as e:
        sys.exit(
            f"Could not connect to Logic 2: {e}\n"
            f"Make sure Logic 2 is running and automation is enabled in Preferences."
        )

    with mgr:
        channels = sorted(set([clk_ch, mosi_ch, cs_ch]))
        sample_rate = 50_000_000   # 50 MSa/s - 4x oversampling at 12.5 MHz SCK

        device_cfg = automation.LogicDeviceConfiguration(
            enabled_digital_channels=channels,
            digital_sample_rate=sample_rate,
        )
        capture_cfg = automation.CaptureConfiguration(
            capture_mode=automation.TimedCaptureMode(duration_seconds=duration)
        )

        print(f"Channels: CLK={clk_ch}  MOSI={mosi_ch}  CS={cs_ch}")
        print(f"Sample rate: {sample_rate//1_000_000} MSa/s   Duration: {duration} s")
        print()
        print("=" * 52)
        print("  Capture running - run the test now:")
        print()
        print("    make test-run TEST=full   (all bins bright)")
        print("    make test-run TEST=tone   (single bin at 32)")
        print("    make test-run TEST=null   (all bins dark)")
        print("=" * 52)

        sal_path = out_csv.replace(".csv", ".sal")

        with mgr.start_capture(
            device_configuration=device_cfg,
            capture_configuration=capture_cfg,
        ) as cap:
            cap.wait()

            cap.save(sal_path)
            print(f"Capture saved to {sal_path}  (open in Logic 2 to inspect)")
            print("Capture complete. Adding SPI analyzer ...")

            spi = cap.add_analyzer(
                "SPI",
                label="PlutoSky IQ",
                settings={
                    "MOSI":               mosi_ch,
                    "Clock":              clk_ch,
                    "Enable":             cs_ch,
                    "Bits per Transfer":  8,
                    "Significant Bit":    "Most Significant Bit First (Standard)",
                    "Clock State":        CPOL1_STRING,
                    "Clock Phase":        CPHA1_STRING,
                    "Enable Line":        "Enable line is Active Low (Standard)",
                },
            )

            print(f"Exporting to {out_csv} ...")
            cap.export_data_table(filepath=out_csv, analyzers=[spi])

    print(f"Saved: {out_csv}")
    print()


def parse_and_print(csv_path, max_words=50):
    """
    Parse the Logic 2 SPI data-table CSV and reconstruct IQ words.

    Logic 2 SPI exports one row per 8-bit frame. Four consecutive rows within
    the same CS assertion form one 32-bit IQ word:
        byte 0 = I[15:8]
        byte 1 = I[ 7:0]
        byte 2 = Q[15:8]
        byte 3 = Q[ 7:0]
    """
    rows = []
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)

    if not rows:
        print("No SPI frames decoded. Check channel assignments and SPI mode settings.")
        return

    # Find the MOSI column (may be labeled 'MOSI' or 'mosi')
    headers = list(rows[0].keys())
    mosi_col = next((h for h in headers if "mosi" in h.lower()), None)
    pkt_col  = next((h for h in headers if "packet" in h.lower()), None)
    time_col = headers[0]   # first column is always time

    if mosi_col is None:
        print(f"Could not find MOSI column. Available columns: {headers}")
        print("First 5 rows:")
        for r in rows[:5]:
            print(" ", r)
        return

    print(f"Decoded {len(rows)} SPI bytes  ->  {len(rows)//4} IQ words")
    print()
    print(f"{'Word':>6}  {'Time(us)':>10}  {'I raw':>8}  {'Q raw':>8}  "
          f"{'I':>8}  {'Q':>8}  Bytes")
    print("-" * 72)

    words_printed = 0
    words_ok = 0
    words_bad = 0

    i = 0
    while i + 3 < len(rows):
        b = []
        valid = True
        for j in range(4):
            raw = rows[i + j].get(mosi_col, "").strip()
            try:
                # Logic 2 exports hex as '0xFF' or just 'FF'
                val = int(raw, 16) if raw.startswith("0x") or raw.startswith("0X") \
                      else int(raw, 16)
                b.append(val)
            except ValueError:
                valid = False
                break

        if not valid:
            i += 1
            continue

        i_raw = (b[0] << 8) | b[1]
        q_raw = (b[2] << 8) | b[3]
        # sign-extend 16-bit
        i_val = i_raw if i_raw < 0x8000 else i_raw - 0x10000
        q_val = q_raw if q_raw < 0x8000 else q_raw - 0x10000

        try:
            t_us = float(rows[i].get(time_col, "0")) * 1e6
        except ValueError:
            t_us = 0.0

        if words_printed < max_words:
            byte_str = " ".join(f"{v:02X}" for v in b)
            print(f"{words_printed:>6}  {t_us:>10.1f}  "
                  f"0x{i_raw:04X}  0x{q_raw:04X}  "
                  f"{i_val:>8}  {q_val:>8}  [{byte_str}]")
            words_printed += 1
        elif words_printed == max_words:
            print(f"  ... (truncated at {max_words} words)")
            words_printed += 1

        words_ok += 1
        i += 4

    total = words_ok + words_bad
    print()
    print(f"Total IQ words decoded: {total}")
    print()

    if total == 0:
        return

    # Basic sanity checks
    print("Sanity checks:")

    # Re-read first few to check pattern
    i = 0
    samples = []
    while i + 3 < len(rows) and len(samples) < 100:
        b = []
        valid = True
        for j in range(4):
            raw = rows[i + j].get(mosi_col, "").strip()
            try:
                val = int(raw, 16) if raw.startswith(("0x", "0X")) else int(raw, 16)
                b.append(val)
            except ValueError:
                valid = False
                break
        if valid:
            ir = (b[0] << 8) | b[1]
            qr = (b[2] << 8) | b[3]
            iv = ir if ir < 0x8000 else ir - 0x10000
            qv = qr if qr < 0x8000 else qr - 0x10000
            samples.append((iv, qv))
        i += 4

    if not samples:
        return

    # Detect pattern
    all_zero = all(iv == 0 and qv == 0 for iv, qv in samples)
    all_full = all(iv == 32767 and qv == 0 for iv, qv in samples)
    has_variation = len(set(iv for iv, _ in samples)) > 4

    if all_zero:
        print("  Pattern: NULL (I=0, Q=0) - matches TEST=null")
    elif all_full:
        print("  Pattern: FULL (I=32767, Q=0) - matches TEST=full")
    elif has_variation:
        import math
        magnitudes = [math.sqrt(iv**2 + qv**2) for iv, qv in samples]
        avg_mag = sum(magnitudes) / len(magnitudes)
        print(f"  Pattern: varying IQ (avg magnitude {avg_mag:.0f}) - consistent with TEST=tone")
        # For tone test: Fs/8 -> bin 32 of 256-point FFT
        # Check if phase increments by pi/4 per sample
        phases = [math.atan2(qv, iv) for iv, qv in samples if iv != 0 or qv != 0]
        if len(phases) > 2:
            diffs = [(phases[k+1] - phases[k]) % (2*math.pi) for k in range(min(8, len(phases)-1))]
            avg_diff = sum(diffs) / len(diffs)
            expected = math.pi / 4
            if abs(avg_diff - expected) < 0.15:
                print(f"  Phase increment {math.degrees(avg_diff):.1f} deg/sample "
                      f"(expect 45.0 for Fs/8 tone) - MATCHES TEST=tone")
            else:
                print(f"  Phase increment {math.degrees(avg_diff):.1f} deg/sample "
                      f"(expected 45.0 for Fs/8 tone)")
    else:
        print(f"  Pattern: unrecognized - first sample I={samples[0][0]} Q={samples[0][1]}")

    # Byte-level check: with TEST=full the wire should be 7F FF 00 00 every word
    if all_full:
        print("  Wire bytes (expect 7F FF 00 00 for every word): OK")


def main():
    ap = argparse.ArgumentParser(
        description="Capture SPI IQ data via Saleae Logic 2",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--clk",      type=int, default=0,
                    help="Logic channel connected to jp5_spi_clk (JP5 pin 7)")
    ap.add_argument("--mosi",     type=int, default=1,
                    help="Logic channel connected to jp5_spi_mosi (JP5 pin 9)")
    ap.add_argument("--cs",       type=int, default=2,
                    help="Logic channel connected to jp5_spi_csn (JP5 pin 13)")
    ap.add_argument("--duration", type=float, default=10.0,
                    help="Capture duration in seconds")
    ap.add_argument("--out",      default=os.path.join(DATA_DIR, "spi_capture.csv"),
                    help="Output CSV path")
    ap.add_argument("--load",     metavar="CSV",
                    help="Skip capture - parse an existing CSV export instead")
    ap.add_argument("--words",    type=int, default=50,
                    help="Max IQ words to print")
    args = ap.parse_args()

    if args.load:
        parse_and_print(args.load, args.words)
    else:
        capture(args.clk, args.mosi, args.cs, args.duration, args.out)
        parse_and_print(args.out, args.words)


if __name__ == "__main__":
    main()
