#!/usr/bin/env python3
"""
apt_receive.py — NOAA APT satellite image receiver for PlutoSky 7020

Captures IQ during a NOAA weather satellite pass, FM-demodulates, AM-demodulates
the 2400 Hz APT subcarrier, syncs to the line pattern, and saves a PNG image.

NOAA satellite downlink frequencies:
  NOAA 15 : 137.620 MHz
  NOAA 18 : 137.9125 MHz
  NOAA 19 : 137.100 MHz  (default — usually the strongest)

BEFORE RUNNING: check upcoming overhead passes at https://www.n2yo.com/passes/
A pass above 20 degrees elevation gives usable signal; above 40 degrees is ideal.
A pass lasts 8-15 minutes; the script runs for --duration seconds.

Requirements:
    pip install numpy scipy matplotlib

Usage:
    python tests/apt_receive.py                          # NOAA 19, 90 s
    python tests/apt_receive.py --freq 137.620 --duration 600   # full NOAA 15 pass
    python tests/apt_receive.py --load-iq cap.bin --freq 137.1  # re-process offline
    python tests/apt_receive.py --save-iq cap.bin               # save IQ for later

Data size note:
    At 2.5 MSPS, 90 s of IQ ≈ 900 MB.  Transfer over USB SSH takes ~60-90 s.
    For a full 10-minute pass use --rate 1000000 (360 MB at 1 MSPS, enough bandwidth
    to capture the full APT signal).
"""

import argparse, math, os, subprocess, sys, wave

try:
    import numpy as np
    from scipy import signal
except ImportError:
    sys.exit("pip install numpy scipy matplotlib")

# ── data directory (tests/data/ relative to this file) ───────────────────────

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(DATA_DIR, exist_ok=True)

# ── APT signal constants ──────────────────────────────────────────────────────

APT_SUBCARRIER  = 2400    # Hz  — AM subcarrier frequency
APT_LINE_RATE   = 2       # lines/second
APT_PIXEL_RATE  = 4160    # Hz  — pixels/second (2 lines/s × 2080 px/line)
APT_LINE_LEN    = 2080    # pixels per complete scan line
APT_SYNC_FREQ   = 1040    # Hz  — sync pulse frequency
APT_FM_DEV      = 17_000  # Hz  — FM carrier peak deviation (NOAA standard)

# Pixel layout within one 2080-pixel line (offsets are pixel indices):
#  [  0.. 38] Sync A    — 39 px, 7 cycles of 1040 Hz square wave
#  [ 39.. 85] Space A   — 47 px, 0% black (calibration)
#  [ 86..994] Image A   — 909 px, visible (day) or near-IR (night)
#  [995..1039] Telemetry A — 45 px, 16 calibration wedges
#  [1040..1078] Sync B  — 39 px
#  [1079..1125] Space B — 47 px
#  [1126..2034] Image B — 909 px, thermal IR 10.3-11.5 µm (always)
#  [2035..2079] Telemetry B — 45 px

APT_SYNC_A_START  = 0
APT_IMG_A_START   = 86
APT_IMG_A_END     = 995
APT_SYNC_B_START  = 1040
APT_IMG_B_START   = 1126
APT_IMG_B_END     = 2035

# ── board defaults ────────────────────────────────────────────────────────────

BOARD_IP      = "192.168.2.1"
SSH_KEY       = os.environ.get("PLUTO_SSH_KEY")
CAPTURE_RATE  = 2_500_000   # Hz — set lower (e.g. 1000000) for long passes
RF_BW         = 40_000      # Hz — RF filter, just wider than APT bandwidth
IIO_BUF       = 8192

NOAA_FREQS = {
    "NOAA-15": 137.620,
    "NOAA-18": 137.9125,
    "NOAA-19": 137.100,
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

def _ssh(ip, key):
    return ["ssh",
            *([ "-i", key ] if key else []),
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            f"root@{ip}"]

def ssh_text(ip, key, cmd, timeout=30):
    r = subprocess.run(_ssh(ip, key) + [cmd],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"SSH failed:\n  {cmd}\n  {r.stderr.strip()}")
    return r.stdout.strip()

def ssh_bytes(ip, key, cmd, timeout=600):
    r = subprocess.run(_ssh(ip, key) + [cmd],
                       capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(
            f"SSH capture failed:\n  {r.stderr.decode(errors='replace').strip()}")
    return r.stdout

# ── AD9361 configuration ──────────────────────────────────────────────────────

def find_iio(ip, key, name):
    out = ssh_text(ip, key,
        f'for d in /sys/bus/iio/devices/iio:device*; do '
        f'n=$(cat "$d/name" 2>/dev/null); '
        f'[ "$n" = "{name}" ] && echo "$d" && break; done')
    if not out:
        raise RuntimeError(
            f"IIO device '{name}' not found — RF bitstream loaded?")
    return out

def configure(ip, key, freq_hz, rate_hz, rf_bw_hz, gain_mode="slow_attack", manual_gain_db=None):
    """
    Configure AD9361 LO, sample rate, RF bandwidth, and gain control.

    The AD9363 on this board only supports sample rates achievable by its
    internal decimation chain with a fixed reference clock.  If the requested
    rate is rejected (EINVAL) the function retries with the next higher standard
    rate until one is accepted, then reads back what the driver actually set.

    Known-working rates on this board: 2.5 MSPS, 5 MSPS, 10 MSPS, 25 MSPS.
    Rates below ~2.083 MSPS appear unsupported with the default clock config.

    gain_mode: "slow_attack" (default), "fast_attack", "hybrid", or "manual"
    manual_gain_db: only used when gain_mode="manual" (AD9363 range: 0–73 dB)
    """
    print("Configuring AD9361 ...")
    phy = find_iio(ip, key, "ad9361-phy")
    ssh_text(ip, key, f"echo {freq_hz} > {phy}/out_altvoltage0_RX_LO_frequency")

    # Try the requested rate; if rejected, step up through standard rates.
    fallback_rates = [rate_hz, 2_083_333, 2_500_000, 5_000_000]
    for attempt in fallback_rates:
        r = subprocess.run(
            _ssh(ip, key) + [f"echo {attempt} > {phy}/in_voltage_sampling_frequency"],
            capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            if attempt != rate_hz:
                print(f"  NOTE: {rate_hz/1e6:.3f} MSPS rejected by driver "
                      f"(below minimum). Using {attempt/1e6:.3f} MSPS instead.")
            break
        if attempt == fallback_rates[-1]:
            raise RuntimeError(
                f"Could not set any sample rate. Last error:\n  {r.stderr.strip()}")

    # RF bandwidth — silently clamp if rejected (driver will use its own minimum)
    subprocess.run(
        _ssh(ip, key) + [f"echo {rf_bw_hz} > {phy}/in_voltage_rf_bandwidth"],
        capture_output=True, timeout=15)

    # Gain control — both RX channels share the same phy device
    for ch in ("in_voltage0", "in_voltage1"):
        subprocess.run(
            _ssh(ip, key) + [f"echo {gain_mode} > {phy}/{ch}_gain_control_mode"],
            capture_output=True, timeout=10)
        if gain_mode == "manual" and manual_gain_db is not None:
            subprocess.run(
                _ssh(ip, key) + [f"echo {manual_gain_db} > {phy}/{ch}_hardwaregain"],
                capture_output=True, timeout=10)

    lo   = int(ssh_text(ip, key, f"cat {phy}/out_altvoltage0_RX_LO_frequency"))
    rate = int(ssh_text(ip, key, f"cat {phy}/in_voltage_sampling_frequency"))
    gain_rb = ssh_text(ip, key, f"cat {phy}/in_voltage0_hardwaregain 2>/dev/null || echo unknown")
    mode_rb = ssh_text(ip, key, f"cat {phy}/in_voltage0_gain_control_mode 2>/dev/null || echo unknown")
    print(f"  LO   = {lo/1e6:.4f} MHz")
    print(f"  Rate = {rate/1e6:.4f} MSPS")
    print(f"  Gain = {gain_rb} dB  (mode: {mode_rb})")
    return rate

# ── IQ capture ────────────────────────────────────────────────────────────────

# Threshold above which buffering the capture in RAM is impractical.
# Above this size, stream directly to a temp file to avoid OOM.
_RAM_LIMIT_BYTES = 600 * 1024 * 1024   # 600 MB

def capture(ip, key, n_samples, iq_file=None):
    """
    Capture IQ from the board via iio_readdev piped over SSH.

    For small captures (< 600 MB) the raw bytes are returned directly.
    For large captures the data is streamed to iq_file on disk (or a temp file
    if iq_file is None) and the file path is returned as a string instead of
    bytes — callers must check the return type.

    Using subprocess.Popen + stdout=file streams the data directly to disk
    without ever holding the full capture in Python memory.
    """
    expected_bytes = n_samples * 4
    mb = expected_bytes / 1e6
    print(f"Capturing {n_samples} samples ({mb:.0f} MB) ...")

    ssh_cmd = _ssh(ip, key) + [
        f"iio_readdev -u local: -b {IIO_BUF} -s {n_samples} "
        f"cf-ad9361-lpc voltage0 voltage1"
    ]

    if expected_bytes <= _RAM_LIMIT_BYTES:
        # Small enough to buffer in RAM
        r = subprocess.run(ssh_cmd, capture_output=True,
                           timeout=int(n_samples / 2_000_000) + 120)
        if r.returncode != 0:
            raise RuntimeError(
                f"iio_readdev failed:\n  {r.stderr.decode(errors='replace').strip()}")
        got = len(r.stdout) // 4
        print(f"  Received {len(r.stdout)} bytes ({got} samples)")
        if got < n_samples * 0.90:
            print(f"  WARNING: only received {got}/{n_samples} samples")
        return r.stdout   # bytes

    else:
        # Too large for RAM — stream directly to disk
        import threading, time
        path = iq_file or os.path.join(DATA_DIR, f"apt_iq_{os.getpid()}.bin")
        duration_s = n_samples / 2_500_000   # approximate at 2.5 MSPS
        print(f"  Large capture — streaming to {path} (avoids {mb:.0f} MB in RAM)")
        print(f"  Expected duration: {duration_s:.0f} s  — progress updates every 10 s")
        timeout = int(n_samples / 800_000) + 180   # generous: ~1.25× expected duration

        done_evt = threading.Event()

        def _progress():
            start = time.time()
            while not done_evt.wait(timeout=10):
                try:
                    sz = os.path.getsize(path)
                except OSError:
                    sz = 0
                elapsed = time.time() - start
                pct = sz / expected_bytes * 100 if expected_bytes else 0
                rate = sz / elapsed / 1e6 if elapsed > 0 else 0
                eta = (expected_bytes - sz) / (rate * 1e6) if rate > 0 else 0
                print(f"  [{elapsed:5.0f}s] {sz/1e6:6.0f}/{mb:.0f} MB "
                      f"({pct:3.0f}%)  {rate:.1f} MB/s  ETA {eta:.0f}s", flush=True)

        prog_thread = threading.Thread(target=_progress, daemon=True)
        with open(path, "wb") as f:
            proc = subprocess.Popen(ssh_cmd, stdout=f, stderr=subprocess.PIPE)
            prog_thread.start()
            try:
                _, stderr = proc.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                done_evt.set()
                raise RuntimeError("Capture timed out")
            finally:
                done_evt.set()
        if proc.returncode not in (0, -2):   # -2 = SIGINT (user stopped early)
            raise RuntimeError(
                f"iio_readdev failed:\n  {stderr.decode(errors='replace').strip()}")
        got_bytes = os.path.getsize(path)
        got = got_bytes // 4
        print(f"  Streamed {got_bytes} bytes ({got} samples) to {path}")
        if got < n_samples * 0.90:
            print(f"  WARNING: only received {got}/{n_samples} samples ({got/n_samples*100:.0f}%)")
        return path   # str — callers must handle both return types

def parse_iq(raw):
    """
    IIO format le:S12/16>>0 — 12-bit signed in 16-bit LE container, interleaved I/Q.
    voltage0=I, voltage1=Q.  Range as int16: [-2048, 2047].
    """
    s = np.frombuffer(raw, dtype="<i2")
    return (s[0::2].astype(np.float32) + 1j * s[1::2].astype(np.float32)) / 2048.0

# ── FM demodulation ───────────────────────────────────────────────────────────

def fm_demod(iq, fs, max_dev=APT_FM_DEV, target_rate=50_000):
    """
    Phase-difference FM discriminator.

    Steps:
      1. Remove DC (LO leakage biases the phasor off-origin, corrupting angle())
      2. Discriminate: angle(x[n]*conj(x[n-1])) * fs/(2π)  → instantaneous freq Hz
      3. Decimate to target_rate for AM demodulation

    Returns (audio_hz, actual_rate) where audio_hz contains the 2400 Hz APT
    subcarrier with amplitude proportional to pixel brightness.
    """
    print(f"FM demodulating ({fs/1e6:.3f} MSPS -> ~{target_rate/1e3:.0f} kHz) ...")

    # 1. DC removal — mandatory for correct discriminator output
    iq = iq - iq.mean()

    # 2. FM phase-difference discriminator
    prod    = iq[1:] * np.conj(iq[:-1])
    freq_hz = np.angle(prod) * (fs / (2.0 * np.pi))   # inst. frequency in Hz

    # 3. Decimate to target_rate
    d = max(1, int(round(fs / target_rate)))
    if d > 1:
        freq_hz = signal.decimate(freq_hz, d, ftype="fir", zero_phase=True)
    actual = fs / d
    print(f"  Decim /{d}: {actual/1e3:.1f} kHz")

    rms = np.sqrt(np.mean(freq_hz**2))
    print(f"  Subcarrier RMS: {rms:.1f} Hz  (expect ~{max_dev*0.7:.0f} for well-modulated APT)")

    return freq_hz, actual

# ── APT AM demodulation ───────────────────────────────────────────────────────

def apt_am_demod(audio, fs):
    """
    Extract pixel values from the 2400 Hz APT subcarrier via complex demodulation.

    The FM-demodulated signal looks like:
        audio(t) = brightness(t) * cos(2π * 2400 * t)

    We shift 2400 Hz to baseband (complex multiply by exp(-j*2π*2400*t)),
    lowpass at ~2100 Hz (the pixel Nyquist), then take the magnitude.
    This gives brightness(t) without needing to know the subcarrier phase.

    Returns (pixels, APT_PIXEL_RATE) — float32 array, values ~[0, 1].
    """
    print(f"APT AM demodulating ({fs/1e3:.1f} kHz subcarrier -> {APT_PIXEL_RATE} Hz pixels) ...")

    # Shift 2400 Hz subcarrier to 0 Hz
    t       = np.arange(len(audio), dtype=np.float64) / fs
    mix     = np.exp(-2j * np.pi * APT_SUBCARRIER * t).astype(np.complex64)
    baseband = audio.astype(np.complex64) * mix    # complex baseband

    # Lowpass at ~2100 Hz to isolate the pixel data
    nyq = fs / 2.0
    b   = signal.firwin(127, min(2100.0 / nyq, 0.98), window="hamming")
    bi  = signal.filtfilt(b, [1.0], baseband.real)
    bq  = signal.filtfilt(b, [1.0], baseband.imag)

    # Magnitude = envelope = pixel brightness
    pixels = np.sqrt(bi**2 + bq**2)

    # Resample to APT_PIXEL_RATE (4160 Hz)
    fs_i = int(round(fs))
    g    = math.gcd(fs_i, APT_PIXEL_RATE)
    up, down = APT_PIXEL_RATE // g, fs_i // g
    if max(up, down) <= 1000:
        pixels = signal.resample_poly(pixels, up, down)
    else:
        n_out  = int(round(len(pixels) * APT_PIXEL_RATE / fs))
        pixels = signal.resample(pixels, n_out)

    # Normalize to [0, 1] using 1st / 99th percentile to clip outliers
    lo, hi = np.percentile(pixels, 1), np.percentile(pixels, 99)
    if hi - lo < 1e-9:
        print("  WARNING: pixel amplitude is near zero — check signal strength")
        return pixels, APT_PIXEL_RATE
    pixels = (pixels - lo) / (hi - lo)
    pixels = np.clip(pixels, 0.0, 1.0)

    total_lines = len(pixels) / APT_LINE_LEN
    print(f"  Pixel stream: {len(pixels)} samples = {total_lines:.1f} lines")
    return pixels.astype(np.float32), APT_PIXEL_RATE

# ── APT sync detection and framing ────────────────────────────────────────────

def apt_sync_template():
    """
    Generate the sync A pattern: 7 cycles of 1040 Hz square wave at 4160 Hz.
    At 4160 Hz, 1040 Hz has a period of 4 samples → 7 cycles = 28 samples.
    Pattern alternates: 2 samples high, 2 samples low (half-cycles of 4-sample period).
    """
    samples_per_cycle = APT_PIXEL_RATE // APT_SYNC_FREQ  # 4
    n_cycles          = 7
    n                 = samples_per_cycle * n_cycles       # 28
    t = np.arange(n) / float(APT_PIXEL_RATE)
    # Square wave at sync freq, duty cycle 50%
    s = 0.5 * (1.0 + signal.square(2 * np.pi * APT_SYNC_FREQ * t))
    return s.astype(np.float32)

def find_sync_offset(pixels, n_lines_for_align=40):
    """
    Find where each line starts within the pixel stream.

    Algorithm:
      1. Fold the first n_lines_for_align lines of pixel data into a 2080-pixel
         average row.  The sync pattern (which is identical every line) reinforces;
         random image content averages toward constant.
      2. Cross-correlate the average row with the 1040 Hz sync template.
      3. The peak correlation gives the sample offset of Sync A within a line.

    Returns the sample offset (0..APT_LINE_LEN-1) of Sync A.
    """
    n_lines = min(n_lines_for_align, len(pixels) // APT_LINE_LEN)
    if n_lines < 2:
        print("  WARNING: too few lines to detect sync, using offset 0")
        return 0

    # Fold and average
    segment  = pixels[:n_lines * APT_LINE_LEN]
    folded   = segment.reshape(n_lines, APT_LINE_LEN)
    avg_line = folded.mean(axis=0)

    # Cross-correlate with sync template
    sync_tmpl = apt_sync_template()
    # Tile avg_line twice so correlation wraps correctly (sync near end of line)
    tiled = np.tile(avg_line, 2)
    corr  = np.correlate(tiled, sync_tmpl - sync_tmpl.mean(), mode='valid')
    corr  = corr[:APT_LINE_LEN]   # only first period

    offset = int(np.argmax(corr))
    corr_strength = corr[offset] / (np.std(corr) + 1e-9)
    print(f"  Sync A at pixel offset {offset}  (correlation SNR: {corr_strength:.1f})")
    if corr_strength < 3.0:
        print("  WARNING: weak sync correlation — image may be misaligned")

    return offset

def build_image(pixels, sync_offset):
    """
    Arrange the pixel stream into a 2D image array.

    Starting from sync_offset (the first complete Sync A position), extract
    consecutive full lines of APT_LINE_LEN pixels each.

    Returns float32 array of shape (n_lines, 2080), values in [0, 1].
    """
    start     = sync_offset
    n_lines   = (len(pixels) - start) // APT_LINE_LEN
    end       = start + n_lines * APT_LINE_LEN
    img       = pixels[start:end].reshape(n_lines, APT_LINE_LEN)
    return img

# ── image saving ──────────────────────────────────────────────────────────────

def save_image(img, path, freq_mhz, duration_s):
    """
    Save the APT image as a PNG with Channel A and Channel B side by side.

    APT line layout:
      Left  (px 0-1039)    : Sync A + Space A + Image A (visible/NIR) + Telemetry A
      Right (px 1040-2079) : Sync B + Space B + Image B (thermal IR)  + Telemetry B

    Falls back to PGM (full 2080-px wide) if matplotlib is not installed.
    """
    n_lines = img.shape[0]
    img_u8  = (img * 255).clip(0, 255).astype(np.uint8)

    # -- try matplotlib PNG --------------------------------------------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        chan_a = img_u8[:, APT_IMG_A_START:APT_IMG_A_END]   # 909 px
        chan_b = img_u8[:, APT_IMG_B_START:APT_IMG_B_END]   # 909 px
        full   = img_u8                                       # 2080 px

        # Aspect ratio: each pixel is ~4 km wide, ~7 km tall at nadir —
        # display at 1:1 pixel aspect for simplicity.
        fig_h  = max(3, n_lines / 40)

        fig, axes = plt.subplots(1, 3, figsize=(20, fig_h),
                                 gridspec_kw={"width_ratios": [1, 1, 2.29]})

        axes[0].imshow(chan_a, cmap="gray", aspect="auto", vmin=0, vmax=255)
        axes[0].set_title("Channel A\n(Visible / Near-IR)")
        axes[0].axis("off")

        axes[1].imshow(chan_b, cmap="inferno", aspect="auto", vmin=0, vmax=255)
        axes[1].set_title("Channel B\n(Thermal IR 10.3-11.5 µm)")
        axes[1].axis("off")

        axes[2].imshow(full, cmap="gray", aspect="auto", vmin=0, vmax=255)
        axes[2].set_title("Full line (sync + image + telemetry, both channels)")
        axes[2].axis("off")

        satellite = {137.620: "NOAA-15", 137.9125: "NOAA-18", 137.100: "NOAA-19"}.get(
            round(freq_mhz, 4), f"{freq_mhz} MHz")
        fig.suptitle(f"NOAA APT — {satellite} — {n_lines} lines ({duration_s:.0f} s)",
                     fontsize=12)
        plt.tight_layout()
        plt.savefig(path, dpi=150, bbox_inches="tight")
        plt.close()
        kb = os.path.getsize(path) // 1024
        print(f"Saved PNG : {path}  ({n_lines} lines × 2080 px, {kb} KB)")
        return

    except ImportError:
        pass

    # -- fallback: PGM (full 2080-px width, no external deps) ----------------
    pgm = os.path.splitext(path)[0] + ".pgm"
    with open(pgm, "wb") as f:
        header = f"P5\n{img_u8.shape[1]} {img_u8.shape[0]}\n255\n".encode()
        f.write(header)
        f.write(img_u8.tobytes())
    kb = os.path.getsize(pgm) // 1024
    print(f"Saved PGM : {pgm}  ({n_lines} lines × 2080 px, {kb} KB)")
    print("  Open with: GIMP, feh, eog, or 'open' on macOS")
    print("  pip install matplotlib   to get a labeled PNG next time")

# ── diagnostic: spectrum of FM output ────────────────────────────────────────

def print_subcarrier_check(audio, fs):
    """
    Verify the 2400 Hz subcarrier is present in the FM demodulated audio.
    Print peak frequency near 2400 Hz and its level above noise floor.
    This is the single most useful check after FM demod.
    """
    n   = min(len(audio), 65536)
    win = np.hanning(n)
    psd = np.abs(np.fft.rfft(audio[:n] * win)) ** 2
    f   = np.fft.rfftfreq(n, 1.0 / fs)

    # Look for peak within ±300 Hz of 2400 Hz
    mask   = (f > 2100) & (f < 2700)
    if not mask.any():
        print("  Could not check subcarrier (frequency resolution too coarse)")
        return
    i_peak = np.argmax(psd[mask])
    f_peak = f[mask][i_peak]
    p_peak = 10 * np.log10(psd[mask][i_peak] + 1e-30)
    p_noise = 10 * np.log10(np.median(psd) + 1e-30)
    snr    = p_peak - p_noise
    print(f"  Subcarrier peak : {f_peak:.0f} Hz   SNR vs noise floor: {snr:.1f} dB")
    if snr < 10:
        print("  WARNING: weak subcarrier — check antenna, frequency, and pass timing")
    elif snr > 30:
        print("  Strong subcarrier — good signal")

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="NOAA APT satellite image receiver — PlutoSky 7020",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog="Check pass times at https://www.n2yo.com/passes/ before running.")
    ap.add_argument("--freq",     type=float, default=NOAA_FREQS["NOAA-19"],
                    help="Downlink frequency in MHz (NOAA 19=137.1, 18=137.9125, 15=137.620)")
    ap.add_argument("--duration", type=float, default=90,
                    help="Capture duration in seconds")
    ap.add_argument("--output",   default=os.path.join(DATA_DIR, "apt_image.png"),
                    help="Output image filename (.png or .pgm)")
    ap.add_argument("--rate",     type=int,   default=CAPTURE_RATE,
                    help="ADC sample rate in Hz (minimum ~2.08 MSPS on this board)")
    ap.add_argument("--ip",       default=BOARD_IP,  help="Board IP address")
    ap.add_argument("--key",      default=SSH_KEY,   help="SSH private key path")
    ap.add_argument("--save-iq",  metavar="FILE",    help="Save raw IQ bytes to FILE")
    ap.add_argument("--load-iq",  metavar="FILE",
                    help="Skip board capture — load previously saved IQ from FILE")
    ap.add_argument("--gain-mode", default="slow_attack",
                    choices=["slow_attack", "fast_attack", "hybrid", "manual"],
                    help="AD9363 AGC mode (slow_attack recommended for satellites)")
    ap.add_argument("--gain-db",  type=float, default=None, metavar="DB",
                    help="Manual RX gain in dB (0–73). Only used with --gain-mode manual")
    args = ap.parse_args()

    freq_hz  = int(args.freq * 1e6)
    lines_expected = int(args.duration * APT_LINE_RATE)

    print("=" * 60)
    print(f"  NOAA APT Receiver — PlutoSky 7020")
    print(f"  Frequency : {args.freq} MHz")
    print(f"  Duration  : {args.duration} s  (~{lines_expected} image lines)")
    print(f"  Output    : {args.output}")
    data_mb = args.rate * args.duration * 4 / 1e6
    print(f"  Est. data : ~{data_mb:.0f} MB at {args.rate/1e6:.1f} MSPS "
          f"({'streamed to disk' if data_mb > 600 else 'buffered in RAM'})")
    print("=" * 60)

    # ── capture ──────────────────────────────────────────────────────────────
    _tmp_iq_file = None   # track any temp file we create for cleanup

    if args.load_iq:
        print(f"\nLoading IQ from {args.load_iq} ...")
        actual_rate = args.rate
        iq_source   = args.load_iq   # file path
        nbytes      = os.path.getsize(args.load_iq)
        actual_dur  = nbytes / 4 / actual_rate
        print(f"  {nbytes} bytes = {nbytes//4} samples = {actual_dur:.1f} s "
              f"at {actual_rate/1e6:.2f} MSPS")
    else:
        print()
        actual_rate = configure(args.ip, args.key, freq_hz, args.rate, RF_BW,
                                gain_mode=args.gain_mode, manual_gain_db=args.gain_db)
        n_samples   = int(actual_rate * args.duration)
        actual_dur  = args.duration
        print()
        # capture() returns bytes for small captures, a file path string for large ones
        result = capture(args.ip, args.key, n_samples,
                         iq_file=args.save_iq)   # stream directly to save path if given
        if isinstance(result, str):
            iq_source = result
            if result != args.save_iq:
                _tmp_iq_file = result  # temp file — clean up after processing
        else:
            # Small capture in RAM — optionally save it, then write to a temp file
            # so parse_iq can use the same code path
            if args.save_iq:
                open(args.save_iq, "wb").write(result)
                print(f"IQ saved to {args.save_iq}")
            iq_source = result  # keep as bytes

    # ── parse IQ (supports both in-RAM bytes and on-disk file) ───────────────
    if isinstance(iq_source, str):
        # Memory-map the file to avoid double-buffering, then slice to duration
        s_all = np.memmap(iq_source, dtype="<i2", mode="r")
        max_samples = int(actual_rate * args.duration)
        s = s_all[: max_samples * 2]   # *2 because interleaved I/Q int16 pairs
        if len(s) < len(s_all):
            actual_dur = len(s) // 2 / actual_rate
            print(f"  Truncated to first {actual_dur:.1f} s ({len(s)//2} samples) "
                  f"per --duration; pass --duration {int(len(s_all)//2/actual_rate)} to use full file")
        iq = (s[0::2].astype(np.float32) + 1j * s[1::2].astype(np.float32)) / 2048.0
        del s, s_all
    else:
        iq = parse_iq(iq_source)

    power = 10 * np.log10(np.mean(np.abs(iq)**2) + 1e-30)
    print(f"\nIQ signal power: {power:.1f} dBFS")
    if power < -30:
        print("  WARNING: very low signal — check antenna and pass timing")

    # ── FM demodulate ─────────────────────────────────────────────────────────
    print()
    audio, audio_rate = fm_demod(iq, actual_rate, target_rate=50_000)
    del iq  # free memory — IQ array can be large

    # Verify the 2400 Hz APT subcarrier is present in the FM output
    print("  Subcarrier check:")
    print_subcarrier_check(audio, audio_rate)

    # ── APT AM demodulate ─────────────────────────────────────────────────────
    print()
    pixels, pixel_rate = apt_am_demod(audio, audio_rate)
    del audio  # free memory

    # ── sync detection ────────────────────────────────────────────────────────
    print("\nDetecting sync ...")
    n_lines = len(pixels) // APT_LINE_LEN
    if n_lines < 2:
        print(f"  ERROR: only {n_lines} complete lines in capture.")
        print(f"  Need at least 2 lines ({2 * 0.5:.0f} s) to sync.")
        print(f"  Capture duration was {actual_dur:.1f} s — run during an actual satellite pass.")
        sys.exit(1)
    print(f"  {n_lines} complete lines available")
    sync_offset = find_sync_offset(pixels)

    # ── frame assembly ────────────────────────────────────────────────────────
    print("\nAssembling image ...")
    img = build_image(pixels, sync_offset)
    del pixels
    print(f"  Image: {img.shape[0]} lines × {img.shape[1]} pixels")
    if img.shape[0] < 10:
        print("  WARNING: very few lines — the image will be a thin strip.")
        print("  For a meaningful image, capture during a satellite pass (check n2yo.com).")

    # ── save ──────────────────────────────────────────────────────────────────
    print()
    save_image(img, args.output, args.freq, actual_dur)

    # ── summary ──────────────────────────────────────────────────────────────
    print()
    print("What you should see:")
    print("  Channel A (left)  — visible light in daytime, near-IR at night")
    print("  Channel B (right) — thermal IR: clouds appear bright, warm land dark")
    print("  Full image        — shows sync bars, space, and telemetry wedges")
    if img.shape[0] < 60:
        print()
        print("TIP: With fewer than 60 lines the image is a thin strip.")
        print("     For a full pass image, run during an overhead pass (n2yo.com)")
        print("     and use a longer --duration (480-900 s).")

    # Clean up any temp IQ file we created during streaming
    if _tmp_iq_file and os.path.exists(_tmp_iq_file):
        os.remove(_tmp_iq_file)


if __name__ == "__main__":
    main()
