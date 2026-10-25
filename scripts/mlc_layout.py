#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The SDRAM image layout: where every byte of every MAME region lives (docs/ROADMAP.md, Memory
plan; docs/phase1_video.md, "gfx1 layout"). One definition, used by the sprite bench's
behavioural SDRAM, the download bench's check against rtl/memory/mlc_dl_xform.sv, and the
.mra generator.

    python scripts/mlc_layout.py --image debug/avengrgs_sdram.bin   # the 32 MB image from debug/<set>_*.bin
    python scripts/mlc_layout.py --selftest

gfx1 (24 MB): MAME keeps a tile's two plane pairs RGN_FRAC(1,2) = 12 MB apart. The image stores
16-byte units: row r of tiles 2k and 2k+1, each tile's 8 bytes as a0 a1 a2 a3 (first half) b0 b1
b2 b3 (second half), so the sprite engine reads one unit for two consecutive tiles' rows and the
SH-2 one unit for a cache line. Region byte a, with h = a >= 0xC00000 and o = a - h * 0xC00000,
lands at {o[23:7], o[5:2], o[6], h, o[1:0]}: tile pair o[23:7], row o[5:2], tile o[6], half h,
byte o[1:0]. Every other region is stored as MAME loads it.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

MAINCPU_BASE = 0x0000000
GFX1_BASE    = 0x0100000
GFX2_BASE    = 0x1900000
YMZ_BASE     = 0x1980000
IMAGE_END    = 0x1F80000
GFX1_SIZE    = 0x1800000
GFX1_HALF    = 0xC00000
GFX2_SIZE    = 0x80000
YMZ_SIZE     = 0x600000

REGIONS = (("maincpu", MAINCPU_BASE, 0x100000), ("gfx1", GFX1_BASE, GFX1_SIZE),
           ("gfx2", GFX2_BASE, GFX2_SIZE), ("ymz", YMZ_BASE, YMZ_SIZE))


def gfx1_offset(a):
    """SDRAM offset within the gfx1 window of region byte a."""
    h = 1 if a >= GFX1_HALF else 0
    o = a - h * GFX1_HALF
    return ((o >> 7) << 8) | (((o >> 2) & 15) << 4) | (((o >> 6) & 1) << 3) | (h << 2) | (o & 3)


def gfx1_unit(tile, row):
    """SDRAM byte address of the 16-byte unit holding row `row` of tile `tile` (and its pair)."""
    return GFX1_BASE + (((tile >> 1) * 16 + row) << 4)


def download_address(addr):
    """The SDRAM address the download path writes the .mra image byte at offset `addr` to:
    what rtl/memory/mlc_dl_xform.sv computes."""
    if GFX1_BASE <= addr < GFX1_BASE + GFX1_SIZE:
        return GFX1_BASE + gfx1_offset(addr - GFX1_BASE)
    return addr


def build_image(set_name, debug=REPO / "debug"):
    """The whole SDRAM image from debug/<set>_<region>.bin (MAME region order)."""
    img = bytearray(IMAGE_END)
    for name, base, size in REGIONS:
        p = debug / f"{set_name}_{name}.bin"
        if not p.exists():
            print(f"{p.name} missing: {name} left zero", file=sys.stderr)
            continue
        data = p.read_bytes()
        assert len(data) == size, f"{p.name}: {len(data):#x} bytes, region is {size:#x}"
        if name == "gfx1":
            # the permutation keeps each tile row's four bytes together: place rows, not bytes
            for a in range(0, size, 4):
                d = gfx1_offset(a)
                img[base + d:base + d + 4] = data[a:a + 4]
        else:
            img[base:base + size] = data
    return bytes(img)


def check_pkg():
    """The RTL's copy of the bases (rtl/video/mlc_video_pkg.sv) equals this one."""
    import re
    text = (REPO / "rtl" / "video" / "mlc_video_pkg.sv").read_text(encoding="utf-8")
    got = {k: int(v, 16) for k, v in re.findall(r"localparam logic \[25:0\] (\w+)\s*=\s*26'h([0-9A-Fa-f]+);", text)}
    want = {"MAINCPU_BASE": MAINCPU_BASE, "GFX1_BASE": GFX1_BASE, "GFX2_BASE": GFX2_BASE,
            "YMZ_BASE": YMZ_BASE, "ROM_END": IMAGE_END}
    bad = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
    assert not bad, f"mlc_video_pkg.sv disagrees with mlc_layout.py: {bad}"


def _selftest():
    check_pkg()
    # the permutation is a bijection onto the window and keeps a unit's two tiles adjacent
    seen = set()
    for a in range(0, GFX1_SIZE, 4):
        d = gfx1_offset(a)
        assert d % 4 == 0 and 0 <= d < GFX1_SIZE, (a, d)
        assert d not in seen
        seen.add(d)
    assert len(seen) == GFX1_SIZE // 4
    for t, r in ((0, 0), (1, 0), (2, 5), (0x2FFFF, 15), (0x12345, 7)):
        u = gfx1_unit(t, r) - GFX1_BASE
        # first half row bytes of tile t, row r: region offset t*64 + r*4
        assert gfx1_offset(t * 64 + r * 4) == u + (t & 1) * 8, (t, r)
        assert gfx1_offset(GFX1_HALF + t * 64 + r * 4) == u + (t & 1) * 8 + 4, (t, r)
    print("mlc_layout selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", help="write the 32 MB SDRAM image here")
    ap.add_argument("--set", default="avengrgs")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        _selftest()
    if a.image:
        Path(a.image).write_bytes(build_image(a.set))
        print(a.image)


if __name__ == "__main__":
    main()
