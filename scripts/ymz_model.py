#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's YMZ280B (src/devices/sound/ymz280b.cpp at mame0289-1527) in Python, at the chip's own
rate, for checking sim/ymz_tb sample by sample.

    python scripts/ymz_model.py --seconds 30                # write debug/ymz/model.raw
    python scripts/ymz_model.py --seconds 30 --compare      # and compare with debug/ymz/rtl.raw

The register writes are debug/ymz/writes.txt (scripts/mame/ymzlog.lua). MAME updates the stream
before a write, so a write at machine time t takes effect from internal sample floor(t * rate),
rate = clock / 384 * 2 (ymz280b.cpp INTERNAL_SAMPLE_RATE). The voice update is
sound_stream_update with one sample per call, which for output_step <= FRAC_ONE (always: fnum is
9 bits) emits the same sequence as MAME's chunked loop. The output is the sum of the voices'
interp * vol / 2, divided by 256: MAME's add_int(..., 32768 * 256) as a 16-bit value, before the
driver's output gain. The ROM is read through deco_mlc.cpp's descramble.
"""
import argparse
import sys

import numpy as np

CLOCK = 14_000_000
RATE = CLOCK / 384 * 2
FRAC_BITS, FRAC_ONE = 9, 1 << 9
INDEX_SCALE = [0x0e6, 0x0e6, 0x0e6, 0x0e6, 0x133, 0x199, 0x200, 0x266]
DIFF = [(-(2 * (n & 7) + 1) if n & 8 else 2 * (n & 7) + 1) for n in range(16)]


def cdiv(a, b):
    """C integer division: truncation toward zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


class Voice:
    def __init__(self):
        self.fnum = 0; self.looping = 0; self.mode = 0; self.keyon = 0; self.playing = 0
        self.level = 0; self.pan = 0; self.start = 0; self.loop_start = 0; self.loop_end = 0
        self.stop = 0; self.position = 0; self.signal = 0; self.step = 0; self.loop_signal = 0
        self.loop_step = 0; self.loop_count = 0; self.output_pos = FRAC_ONE; self.output_step = 1
        self.last = 0; self.curr = 0; self.ended = False; self.left = 0; self.right = 0

    def update_step(self):
        f = self.fnum & (0xff if self.mode == 1 else 0x1ff)
        self.output_step = f + 1

    def update_volumes(self):
        if self.pan == 8:
            self.left = self.right = self.level
        elif self.pan < 8:
            self.left = self.level
            self.right = 0 if self.pan == 0 else cdiv(self.level * (self.pan - 1), 7)
        else:
            self.left = cdiv(self.level * (15 - self.pan), 7)
            self.right = self.level


class YMZ:
    def __init__(self, rom):
        self.rom = rom
        self.v = [Voice() for _ in range(8)]
        self.reg = 0
        self.keyon_enable = 0
        self.trace = None

    def read_byte(self, a):
        a &= 0xFFFFFF
        x = ((a >> 21) << 21) | ((a & 0xFFFFF) << 1) | ((a >> 20) & 1)
        return self.rom[x] if x < len(self.rom) else 0

    def write(self, offset, data):
        if offset & 1 == 0:
            self.reg = data
            return
        r, d = self.reg, data
        if r < 0x80:
            v = self.v[(r >> 2) & 7]
            k = r & 0xe3
            if k == 0x00:
                v.fnum = (v.fnum & 0x100) | d; v.update_step()
            elif k == 0x01:
                v.fnum = (v.fnum & 0xff) | ((d & 1) << 8)
                v.looping = (d & 0x10) >> 4
                if (d & 0x60) == 0:
                    d &= 0x7f
                else:
                    v.mode = (d & 0x60) >> 5
                if not v.keyon and (d & 0x80) and self.keyon_enable:
                    v.playing = 1; v.position = v.start
                    v.signal = v.loop_signal = 0; v.step = v.loop_step = 0x7f; v.loop_count = 0
                elif v.keyon and not (d & 0x80):
                    v.playing = 0
                v.keyon = (d & 0x80) >> 7
                v.update_step()
            elif k == 0x02:
                v.level = d; v.update_volumes()
            elif k == 0x03:
                v.pan = d & 0x0f; v.update_volumes()
            elif k in (0x20, 0x21, 0x22, 0x23, 0x40, 0x41, 0x42, 0x43, 0x60, 0x61, 0x62, 0x63):
                name = ("start", "loop_start", "loop_end", "stop")[k & 3]
                old = getattr(v, name)
                if k & 0xe0 == 0x20:
                    new = (old & (0x00ffff << 1)) | (d << 17)
                elif k & 0xe0 == 0x40:
                    new = (old & (0xff00ff << 1)) | (d << 9)
                else:
                    new = (old & (0xffff00 << 1)) | (d << 1)
                setattr(v, name, new)
        elif r == 0xff:
            self.keyon_enable = (d & 0x80) >> 7

    def gen(self, v):
        """One source sample for a playing voice: (sample, produced)."""
        if v.mode == 1:
            val = self.read_byte(v.position // 2) >> ((~v.position & 1) << 2)
            v.signal += cdiv(v.step * DIFF[val & 15], 8)
            v.signal = max(-32768, min(32767, v.signal))
            v.step = (v.step * INDEX_SCALE[val & 7]) >> 8
            v.step = max(0x7f, min(0x6000, v.step))
            out = v.signal
            if self.trace is not None and v is self.v[1]:
                self.trace.write(f"{v.signal} {v.step}\n")
            v.position += 1
            adv = 1
        elif v.mode == 2:
            val = self.read_byte(v.position // 2)
            out = (val - 256 if val & 0x80 else val) * 256
            v.position += 2
            adv = 2
        else:
            val = (self.read_byte(v.position // 2 + 1) << 8) + self.read_byte(v.position // 2)
            out = val - 65536 if val & 0x8000 else val
            v.position += 4
            adv = 4
        if v.looping:
            if v.mode == 1 and v.position == v.loop_start and v.loop_count == 0:
                v.loop_signal = v.signal; v.loop_step = v.step
            if v.position >= v.loop_end and v.keyon:
                v.position = v.loop_start
                if v.mode == 1:
                    v.signal = v.loop_signal; v.step = v.loop_step
                v.loop_count += 1
        if v.position >= v.stop:
            v.ended = True
        return out

    def sample(self):
        """One internal sample: (left, right) before the output gain, as MAME sums them."""
        left = right = 0
        for v in self.v:
            prev, curr = v.last, v.curr
            if not v.playing and curr == 0 and prev == 0:
                v.output_pos = FRAC_ONE
                continue
            if v.output_pos < FRAC_ONE:
                it = (prev * (FRAC_ONE - v.output_pos) + curr * v.output_pos) >> FRAC_BITS
                if self.trace is not None and v is self.v[1]:
                    self.strace.write(f"{it} {v.left}\n")
                left += cdiv(it * v.left, 2); right += cdiv(it * v.right, 2)
                v.output_pos += v.output_step
            if v.output_pos >= FRAC_ONE:
                v.output_pos -= FRAC_ONE
                if v.playing and v.mode in (1, 2, 3):
                    new = self.gen(v)
                else:
                    new = 0
                if v.ended:
                    v.ended = False
                    v.playing = 0
                prev, curr = curr, new
            v.last, v.curr = prev, curr
        return cdiv(left, 256), cdiv(right, 256)


def load_writes(path, seconds):
    out = []
    for ln in open(path):
        if ln.startswith("#"):
            continue
        t, a, d, m = ln.split()
        t = float(t); a = int(a, 16) & 0xFFFFFF; d = int(d, 16)
        if seconds and t > seconds:
            break
        if a in (0x600000, 0x600004):
            out.append((int(t * RATE), (a >> 2) & 1, (d >> 24) & 0xff))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--set", default="avengrgs")
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args()
    rom = open(f"debug/{a.set}_ymz.bin", "rb").read()
    chip = YMZ(rom)
    chip.trace = open("debug/ymz/model_v1.txt", "w")
    chip.strace = open("debug/ymz/model_s1.txt", "w")
    writes = load_writes("debug/ymz/writes.txt", a.seconds)
    n = int((a.seconds + 1) * RATE)
    out = np.zeros((n, 2), dtype=np.int32)
    wi = 0
    for i in range(n):
        while wi < len(writes) and writes[wi][0] <= i:
            chip.write(writes[wi][1], writes[wi][2]); wi += 1
        out[i] = chip.sample()
        if i % 365000 == 0:
            print(f"  {i / RATE:.0f} s", file=sys.stderr)
    np.clip(out, -32768, 32767).astype("<i2").tofile("debug/ymz/model.raw")
    print(f"model: {n} samples at {RATE:.1f} Hz, {len(writes)} writes -> debug/ymz/model.raw")
    if a.compare:
        rtl = np.fromfile("debug/ymz/rtl.raw", dtype="<i2").reshape(-1, 2).astype(np.int64)
        mod = np.clip(out, -32768, 32767).astype(np.int64)
        k = min(len(rtl), len(mod))
        best = None
        for lag in range(-64, 65):
            x = rtl[max(0, lag):k + min(0, lag)]
            y = mod[max(0, -lag):k - max(0, lag)]
            m = min(len(x), len(y))
            e = int(np.abs(x[:m] - y[:m]).sum())
            if best is None or e < best[0]:
                best = (e, lag, m)
        e, lag, m = best
        x = rtl[max(0, lag):][:m]; y = mod[max(0, -lag):][:m]
        d = np.abs(x - y)
        nz = (y != 0).any(axis=1) | (x != 0).any(axis=1)
        print(f"  where either is not silent ({int(nz.sum())} samples): identical {float((d[nz] == 0).all(axis=1).mean()) * 100:.2f}%, "
              f"within 2 {float((d[nz] <= 2).all(axis=1).mean()) * 100:.2f}%, mean |diff| {float(d[nz].mean()):.2f}")
        print(f"RTL against the model: best lag {lag} samples; identical samples {float((d == 0).all(axis=1).mean()) * 100:.2f}%; "
              f"max |diff| {int(d.max())}; mean |diff| {float(d.mean()):.2f}; model rms {float(np.sqrt((y.astype(float) ** 2).mean())):.0f}")
        bad = np.nonzero((d > 4).any(axis=1))[0]
        if len(bad):
            i = bad[0]
            print(f"  first difference over 4 at sample {i} ({i / RATE:.4f} s): RTL {x[i].tolist()} model {y[i].tolist()}")


if __name__ == "__main__":
    main()
