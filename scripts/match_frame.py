#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Find the MAME frame a board screenshot shows, and how far it is from it.

    python scripts/match_frame.py debug/hw/shot.png debug/mame_frames [--top 3] [--diff out.png]

The reference set is MAME's frames as scripts/mame/snap_range.lua writes them (fNNNNN.png). Each
is compared with the screenshot (both 320 x 240 RGB, a native board screenshot); the closest by
differing pixels is reported, with the count, so "identical to MAME frame N" is a measurement.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB"), dtype=np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shot")
    ap.add_argument("frames")
    ap.add_argument("--top", type=int, default=3)
    ap.add_argument("--diff", help="write the differing pixels of the best match here")
    ap.add_argument("--rot180", action="store_true", help="the screenshot is flipped: compare with each MAME frame rotated 180 degrees")
    a = ap.parse_args()
    shot = load(a.shot)
    res = []
    for p in sorted(Path(a.frames).glob("f*.png")):
        ref = load(p)
        if a.rot180:
            ref = np.ascontiguousarray(np.rot90(ref, 2))
        if ref.shape != shot.shape:
            sys.exit(f"{p.name} is {ref.shape}, the screenshot {shot.shape}")
        res.append((int(np.any(ref != shot, axis=2).sum()), p))
    if not res:
        sys.exit(f"no fNNNNN.png in {a.frames}")
    res.sort(key=lambda r: r[0])
    for n, p in res[:a.top]:
        print(f"{p.stem}: {n} of {shot.shape[0] * shot.shape[1]} pixels differ")
    if a.diff:
        ref = load(res[0][1])
        if a.rot180:
            ref = np.ascontiguousarray(np.rot90(ref, 2))
        d = np.zeros_like(shot)
        d[np.any(ref != shot, axis=2)] = (255, 0, 255)
        Image.fromarray(d).save(a.diff)
    return 0 if res[0][0] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
