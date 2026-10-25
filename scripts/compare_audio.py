#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the YMZ280B bench's output (sim/ymz_tb: debug/ymz/rtl.raw) with MAME's WAV.

    python scripts/compare_audio.py [--rate 72916.667] [--seconds 20] [--wav out.wav]

The RTL's samples are resampled to MAME's 48 kHz (scipy resample_poly), scaled by the game's
volume byte as MAME applies it (deco_mlc.cpp 189-192: gain (255 - v) / 255, from the 0x500000
writes in debug/ymz/writes.txt), aligned to MAME by cross-correlation, and compared per channel:
the correlation, the best scale between the two, and the signal-to-difference ratio after it.
MAME resamples the chip's output with its own filter, so the two are not bit-identical; the
measure is how close. --wav writes the RTL's resampled output for listening.
"""
import argparse
import wave
from fractions import Fraction

import numpy as np
from scipy.signal import resample_poly, correlate

CHIP_RATE = 14_000_000 / 384


def volume_gain(path):
    g = 1.0
    for ln in open(path):
        if ln.startswith("#"):
            continue
        t, a, d, m = ln.split()
        a, d, m = int(a, 16) & 0xFFFFFF, int(d, 16), int(m, 16)
        if a == 0x500000 and (m & 0xFF):
            g = (255 - (d & 0xFF)) / 255.0
    return g


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rate", type=float, default=2 * CHIP_RATE, help="the RTL file's sample rate")
    ap.add_argument("--seconds", type=float, default=0, help="compare only the first n seconds")
    ap.add_argument("--wav", help="write the RTL's resampled output here")
    ap.add_argument("--rtl", default="debug/ymz/rtl.raw", help="the RTL's int16 stereo samples")
    ap.add_argument("--no-gain", action="store_true", help="the file already has the volume byte applied (core_tb)")
    a = ap.parse_args()

    w = wave.open("debug/ymz/avengrgs.wav")
    mame = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, 2).astype(np.float64)
    rtl = np.fromfile(a.rtl, dtype="<i2").reshape(-1, 2).astype(np.float64)
    gain = 1.0 if a.no_gain else volume_gain("debug/ymz/writes.txt")
    frac = Fraction(48000 / a.rate).limit_denominator(4000)
    up = np.stack([resample_poly(rtl[:, c], frac.numerator, frac.denominator) for c in (0, 1)], axis=1) * gain
    n = min(len(up), len(mame))
    if a.seconds:
        n = min(n, int(a.seconds * 48000))
    up, mm = up[:n], mame[:n]

    # the lag, from a loud stretch of the left channel
    seg = slice(n // 4, n // 4 + 48000 * 4) if n > 48000 * 6 else slice(0, n)
    c = correlate(mm[seg, 0], up[seg, 0], mode="full", method="fft")
    lag = int(np.argmax(c)) - (len(up[seg, 0]) - 1)
    print(f"RTL {len(rtl)} samples at {a.rate:.1f} Hz -> {len(up)} at 48 kHz (x{frac}); volume gain {gain:.3f}; lag {lag} samples ({lag / 48:.2f} ms)")
    if lag >= 0:
        mm2, up2 = mm[lag:], up[:n - lag]
    else:
        mm2, up2 = mm[:n + lag], up[-lag:]
    k = min(len(mm2), len(up2))
    mm2, up2 = mm2[:k], up2[:k]
    for ch, name in ((0, "left"), (1, "right")):
        x, y = up2[:, ch], mm2[:, ch]
        r = np.corrcoef(x, y)[0, 1]
        s = float(np.dot(x, y) / max(np.dot(x, x), 1e-9))
        d = y - s * x
        snr = 10 * np.log10(np.dot(y, y) / max(np.dot(d, d), 1e-9))
        print(f"  {name}: correlation {r:.5f}, scale MAME/RTL {s:.4f}, signal to difference {snr:.1f} dB, "
              f"rms MAME {np.sqrt((y * y).mean()):.0f} RTL {np.sqrt((x * x).mean()):.0f}")
    if a.wav:
        out = np.clip(up, -32768, 32767).astype("<i2")
        o = wave.open(a.wav, "wb")
        o.setnchannels(2); o.setsampwidth(2); o.setframerate(48000)
        o.writeframes(out.tobytes())
        o.close()
        print(f"wrote {a.wav}")


if __name__ == "__main__":
    main()
