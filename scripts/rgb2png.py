#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Raw 320 x 240 RGB8 frames (the benches' .rgb files) to PNG, beside the source.

    python scripts/rgb2png.py debug/core/avengrgs_f020.rgb [...]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

for p in sys.argv[1:]:
    raw = Path(p).read_bytes()
    img = np.frombuffer(raw, dtype=np.uint8).reshape(240, 320, 3)
    out = Path(p).with_suffix(".png")
    Image.fromarray(img).save(out)
    print(out)
