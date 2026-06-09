#!/usr/bin/env python3
"""
fm_test.py - End-to-end FM receive test for PlutoSky 7020 (fishball7020)

Tunes the AD9361 to an FM station, captures IQ via SSH/iio_readdev,
demodulates FM mono, and writes a 48 kHz 16-bit WAV.

Requirements:
    pip install numpy scipy

Usage:
    python tests/fm_test.py                         # 95.1 MHz, 5 s
    python tests/fm_test.py --freq 98.1
    python tests/fm_test.py --load-iq cap.bin       # re-demod without board
    python tests/fm_test.py --spectrum spec.png     # save spectrum plot
"""

import argparse, math, os, subprocess, sys, wave

try:
    import numpy as np
    from scipy import signal
except ImportError:
    sys.exit("pip install numpy scipy")

# -- data directory (tests/data/ relative to this file) -----------------------

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(DATA_DIR, exist_ok=True)

# -- tuneable constants --------------------------------------------------------

DEFAULT_FREQ_MHZ = 95.1
DEFAULT_DURATION = 5          # seconds
DEFAULT_OUTPUT   = os.path.join(DATA_DIR, "fm_output.wav")
BOARD_IP         = "192.168.2.1"
SSH_KEY          = os.environ.get("PLUTO_SSH_KEY")

# ADC sample rate.  2.5 MSPS fits the full FM channel (~200 kHz) and keeps
# the SSH transfer to ~50 MB for 5 s.
CAPTURE_RATE     = 2_500_000  # Hz

FM_MAX_DEV       = 75_000     # Hz - US/EU FM deviation limit
AUDIO_BW         = 15_000     # Hz - mono audio passband
RF_BW            = 2_000_000  # Hz - AD9361 analog RF filter width
AUDIO_RATE       = 48_000     # Hz - WAV output sample rate
IIO_BUF          = 8192       # iio_readdev buffer size (frames, power of 2)

# -- SSH helpers ---------------------------------------------------------------

def _ssh(ip, key):
    return ["ssh",
            *([ "-i", key ] if key else []),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            f"root@{ip}"]

def ssh_text(ip, key, cmd, timeout=30):
    r = subprocess.run(_ssh(ip, key) + [cmd],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"SSH failed:\n  {cmd}\n  {r.stderr.strip()}")
    return r.stdout.strip()

def ssh_bytes(ip, key, cmd, timeout=180):
    r = subprocess.run(_ssh(ip, key) + [cmd],
                       capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"SSH capture failed:\n  {r.stderr.decode(errors='replace').strip()}")
    return r.stdout

# -- AD9361 configuration ------------------------------------------------------

def find_iio(ip, key, name):
    out = ssh_text(ip, key,
        f'for d in /sys/bus/iio/devices/iio:device*; do '
        f'n=$(cat "$d/name" 2>/dev/null); '
        f'[ "$n" = "{name}" ] && echo "$d" && break; done')
    if not out:
        raise RuntimeError(
            f"IIO device '{name}' not found - check `ls /sys/bus/iio/devices/` on board")
    return out

def configure(ip, key, freq_hz, rate_hz, rf_bw_hz):
    print("Configuring AD9361 ...")
    phy = find_iio(ip, key, "ad9361-phy")
    ssh_text(ip, key, f"echo {freq_hz} > {phy}/out_altvoltage0_RX_LO_frequency")
    ssh_text(ip, key, f"echo {rate_hz} > {phy}/in_voltage_sampling_frequency")
    ssh_text(ip, key, f"echo {rf_bw_hz} > {phy}/in_voltage_rf_bandwidth")
    lo   = int(ssh_text(ip, key, f"cat {phy}/out_altvoltage0_RX_LO_frequency"))
    rate = int(ssh_text(ip, key, f"cat {phy}/in_voltage_sampling_frequency"))
    print(f"  LO   = {lo/1e6:.4f} MHz")
    print(f"  Rate = {rate/1e6:.4f} MSPS")
    return rate

# -- IQ capture ----------------------------------------------------------------

def capture(ip, key, n_samples, buf=IIO_BUF):
    mb = n_samples * 4 / 1e6
    print(f"Capturing {n_samples} samples ({mb:.1f} MB) ...")
    raw = ssh_bytes(ip, key,
        f"iio_readdev -u local: -b {buf} -s {n_samples} "
        f"cf-ad9361-lpc voltage0 voltage1")
    got = len(raw) // 4
    print(f"  Received {len(raw)} bytes ({got} samples)")
    if got < n_samples * 0.90:
        print(f"  WARNING: only got {got}/{n_samples} samples")
    return raw

def parse_iq(raw):
    """
    IIO scan format: le:S12/16>>0
      Each channel value is a 12-bit signed integer, sign-extended into a
      16-bit little-endian word.  Range as int16: [-2048, 2047].
      Interleaved layout: [I0 Q0 I1 Q1 ...] (voltage0 = I, voltage1 = Q).
    """
    s = np.frombuffer(raw, dtype="<i2")
    return (s[0::2].astype(np.float32) + 1j * s[1::2].astype(np.float32)) / 2048.0

# -- spectrum report -----------------------------------------------------------

def spectrum_report(iq, fs):
    """
    Print the top power peaks in the baseband spectrum (relative to the
    noise floor) so we can verify the FM station is actually being received.
    A strong FM station should appear as a peak within +/-100 kHz of 0 Hz.
    """
    n = min(32768, len(iq))
    win = np.hanning(n)
    psd = np.abs(np.fft.fftshift(np.fft.fft(iq[:n] * win))) ** 2
    freqs = np.fft.fftshift(np.fft.fftfreq(n, 1.0 / fs))
    psd_db = 10 * np.log10(psd + 1e-30)
    noise_floor = np.median(psd_db)
    psd_rel = psd_db - noise_floor

    from scipy.signal import find_peaks
    peaks, _ = find_peaks(psd_rel, height=6.0, distance=int(n * 10_000 / fs))
    peaks = sorted(peaks, key=lambda i: psd_rel[i], reverse=True)[:6]

    if peaks:
        print("  Baseband peaks above noise floor:")
        for i in peaks:
            print(f"    {freqs[i]/1e3:+7.1f} kHz   {psd_rel[i]:5.1f} dB above noise")
        # Is there energy near 0 Hz (the tuned station)?
        station_peak = any(abs(freqs[i]) < 200_000 for i in peaks)
        if not station_peak:
            print("  NOTE: no strong peak near 0 Hz - station may not be in range")
        return True
    else:
        print("  No peaks above noise floor - signal is likely too weak")
        print("  Check antenna connection and station frequency")
        return False

def save_spectrum_png(iq, fs, path):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed - skipping spectrum PNG")
        return
    n = min(65536, len(iq))
    f, psd = signal.welch(iq[:n], fs=fs, nperseg=4096, return_onesided=False)
    # fftshift to put 0 Hz in center
    f = np.fft.fftshift(f)
    psd = np.fft.fftshift(psd)
    plt.figure(figsize=(12, 4))
    plt.plot(f / 1e3, 10 * np.log10(np.abs(psd) + 1e-30))
    plt.xlabel("Frequency offset from LO (kHz)")
    plt.ylabel("PSD (dBFS/Hz)")
    plt.title(f"Baseband spectrum - Welch estimate")
    plt.grid(True, alpha=0.4)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    print(f"  Spectrum saved to {path}")

# -- FM demodulation -----------------------------------------------------------

def demod_fm(iq, fs, audio_rate=AUDIO_RATE, max_dev=FM_MAX_DEV, audio_bw=AUDIO_BW):
    """
    Mono FM demodulation: DC removal, phase discriminator, decimation to 250 kHz,
    audio lowpass at audio_bw Hz, polyphase resample to audio_rate, 75 us de-emphasis.
    """
    print(f"Demodulating FM ({fs/1e6:.3f} MSPS -> {audio_rate} Hz) ...")

    # DC removal
    iq = iq - iq.mean()
    sig_rms = np.sqrt(np.mean(np.abs(iq)**2))
    print(f"  Signal RMS  = {20*np.log10(sig_rms+1e-12):.1f} dBFS")

    # FM phase discriminator
    prod = iq[1:] * np.conj(iq[:-1])
    freq_hz = np.angle(prod) * (fs / (2.0 * np.pi))

    # Clip before decimating to suppress noise spikes from signal fades
    freq_hz = np.clip(freq_hz, -200_000.0, 200_000.0)

    # Remove LO frequency offset
    lo_offset_hz = float(freq_hz.mean())
    freq_hz = freq_hz - lo_offset_hz
    print(f"  LO offset   = {lo_offset_hz:+.0f} Hz  ({lo_offset_hz/1e3:+.2f} kHz)")

    # Decimate to 250 kHz
    d = max(1, int(round(fs / 250_000)))
    if d > 1:
        freq_hz = signal.decimate(freq_hz, d, ftype="fir", zero_phase=False)
    rate = fs / d
    print(f"  Decim  /{d:2d}: {rate/1e3:.0f} kHz")

    # Normalize to +/-1
    audio = freq_hz / max_dev

    # Audio lowpass FIR at audio_bw Hz
    nyq = rate / 2.0
    b = signal.firwin(255, min(audio_bw / nyq, 0.98), window="hamming")
    audio = signal.filtfilt(b, [1.0], audio)

    # Polyphase resample to audio_rate
    rate_i = int(round(rate))
    g = math.gcd(rate_i, audio_rate)
    up, down = audio_rate // g, rate_i // g
    if max(up, down) <= 1000:
        audio = signal.resample_poly(audio, up, down)
    else:
        n_out = int(round(len(audio) * audio_rate / rate))
        audio = signal.resample(audio, n_out)
    print(f"  Resample: {rate_i//1000} kHz -> {audio_rate//1000} kHz  ({up}/{down})")

    # 75 us de-emphasis: alpha = dt / (tau + dt)
    tau   = 75e-6
    dt    = 1.0 / audio_rate
    alpha = dt / (tau + dt)
    audio = signal.lfilter([alpha], [1.0, -(1.0 - alpha)], audio)

    rms  = np.sqrt(np.mean(audio**2))
    peak = np.max(np.abs(audio))
    dc   = float(audio.mean())
    crest = 20 * np.log10(peak / (rms + 1e-12))
    print(f"  Audio RMS   = {20*np.log10(rms+1e-12):.1f} dBFS  peak={20*np.log10(peak+1e-12):.1f} dBFS  crest={crest:.1f} dB  DC={dc:.4f}")
    if abs(dc) > 0.05:
        print(f"  WARNING: large audio DC bias ({dc:.4f}) - de-emphasis feeding back?")
    if crest < 6:
        print(f"  WARNING: low crest factor ({crest:.1f} dB) - audio may be clipping/compressed")

    return audio.astype(np.float32)

# -- WAV output ----------------------------------------------------------------

def write_wav(path, audio, rate):
    peak = np.max(np.abs(audio))
    if peak < 1e-9:
        print("  WARNING: audio amplitude is near zero")
        peak = 1.0
    a16 = (audio / peak * 0.90 * 32767).clip(-32768, 32767).astype(np.int16)
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(a16.tobytes())
    kb = os.path.getsize(path) // 1024
    print(f"Wrote {path}  ({len(a16)/rate:.1f} s  {rate} Hz  16-bit mono  {kb} KB)")

# -- main ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="FM receive test - PlutoSky 7020",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--freq",     type=float, default=DEFAULT_FREQ_MHZ,
                    help="FM station frequency (MHz)")
    ap.add_argument("--duration", type=float, default=DEFAULT_DURATION,
                    help="Capture duration (seconds)")
    ap.add_argument("--output",   default=DEFAULT_OUTPUT,
                    help="Output WAV filename")
    ap.add_argument("--rate",     type=int,   default=CAPTURE_RATE,
                    help="ADC sample rate (Hz)")
    ap.add_argument("--ip",       default=BOARD_IP,  help="Board IP address")
    ap.add_argument("--key",      default=SSH_KEY,   help="SSH private key path")
    ap.add_argument("--save-iq",  metavar="FILE",    help="Save raw IQ bytes to FILE")
    ap.add_argument("--load-iq",  metavar="FILE",
                    help="Skip board capture - load raw IQ from FILE instead")
    ap.add_argument("--spectrum", metavar="PNG",
                    help="Save baseband spectrum plot to PNG file")
    args = ap.parse_args()

    freq_hz = int(args.freq * 1e6)

    print("=" * 52)
    print(f"  FM Receive Test - PlutoSky 7020")
    print(f"  Station  : {args.freq} MHz")
    print(f"  Duration : {args.duration} s")
    print(f"  Output   : {args.output}")
    print("=" * 52)

    # -- capture --------------------------------------------------------------
    if args.load_iq:
        print(f"\nLoading IQ from {args.load_iq} ...")
        raw = open(args.load_iq, "rb").read()
        actual_rate = args.rate
        print(f"  {len(raw)} bytes ({len(raw)//4} samples) at assumed {actual_rate/1e6:.3f} MSPS")
    else:
        print()
        actual_rate = configure(args.ip, args.key, freq_hz, args.rate, RF_BW)
        n_samples = int(actual_rate * args.duration)
        print()
        raw = capture(args.ip, args.key, n_samples)

    if args.save_iq:
        open(args.save_iq, "wb").write(raw)
        print(f"IQ saved to {args.save_iq}")

    # -- parse and inspect -----------------------------------------------------
    iq = parse_iq(raw)
    power = 10 * np.log10(np.mean(np.abs(iq)**2) + 1e-30)
    print(f"\nIQ power : {power:.1f} dBFS  ({len(iq)} samples)")
    if power < -35:
        print("  WARNING: signal is very weak - check antenna and station freq")
    elif power > -1:
        print("  WARNING: signal may be saturated - consider reducing gain")

    print("\nSpectrum check:")
    has_signal = spectrum_report(iq, actual_rate)

    if args.spectrum:
        print()
        save_spectrum_png(iq, actual_rate, args.spectrum)

    # -- demodulate ------------------------------------------------------------
    print()
    audio = demod_fm(iq, actual_rate)

    # -- write WAV -------------------------------------------------------------
    print()
    write_wav(args.output, audio, AUDIO_RATE)

    if not has_signal:
        print("\nTIP: No strong signal was detected in the spectrum.")
        print("     Try --spectrum out.png to visually inspect the capture,")
        print("     or --save-iq cap.bin and try again with --load-iq cap.bin")
        print("     after adjusting the frequency.")
    else:
        print("\nDone. Open the WAV in Audacity or VLC.")


if __name__ == "__main__":
    main()
