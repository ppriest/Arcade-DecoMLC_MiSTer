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


# the gfx_layouts (mlc_video_pkg L_*), the .mra mod byte bits 5:4
L_4BPP, L_5BPP, L_6BPP, L_ACCHI = 0, 1, 2, 3
GFX1_EXT_OFF = 0x1000000                # the extra area (planes 4-5), 16 MB into gfx1
MACHINE_LAYOUT = {"avengrgs": L_4BPP, "mlc": L_4BPP, "mlc_5bpp": L_5BPP, "mlc_6bpp": L_6BPP,
                  "stadhr96": L_6BPP, "acchi": L_ACCHI}


def gfx1_dest(a, layout=L_4BPP, frac8=False):
    """SDRAM offset within the gfx1 window of region byte a: rtl/memory/mlc_dl_xform.sv."""
    if layout == L_4BPP:
        return gfx1_offset(a)
    if layout == L_ACCHI:
        p, o = a >> 22, a & 0x3FFFFF        # fifths of 4 MB; tile o >> 5, row o[4:1]
        t, r, k = o >> 5, (o >> 1) & 15, o & 1
        if p == 0:
            return GFX1_EXT_OFF + ((((t >> 2) << 4) | r) << 4) + ((t & 3) << 2) + k
        h, b = (1 if p in (1, 2) else 0), (1 if p in (1, 3) else 0)
        return ((((t >> 1) << 4) | r) << 4) + ((t & 1) << 3) + (h << 2) + (b << 1) + k
    f = 0x800000 if frac8 else 0x400000     # 5bpp, 6bpp: thirds; tile o >> 6, row o[5:2]
    T, o = a // f, a % f
    t, r, k = o >> 6, (o >> 2) & 15, o & 3
    if T == 2:
        return GFX1_EXT_OFF + ((((t >> 2) << 4) | r) << 4) + ((t & 3) << 2) + k
    return ((((t >> 1) << 4) | r) << 4) + ((t & 1) << 3) + (T << 2) + k


DE156_INV = [0x6f0d, 0x8a5b, 0x82dd, 0x08db, 0x1db4, 0x29b7, 0x61b6, 0x5d86, 0xe9a2, 0xabb3, 0x8ab9, 0x9abd, 0xeb15, 0x699a, 0xb009, 0x13f1]


def de156_prog_dest(addr):
    """Where the download puts byte `addr` of a DE156 program (rtl/memory/mlc_dl_xform.sv): raw
    word r at ARM word AddrScramble^-1(r)."""
    x = ((addr >> 2) & 0xFFFF) ^ 0x92C6
    a = sum((bin(m & x).count("1") & 1) << i for i, m in enumerate(DE156_INV))
    return (addr & 0xC0000) | (a << 2) | (addr & 3)


def set_de156(set_name):
    """True for the DE156 sets (every machine config but avengrgs)."""
    sys.path.insert(0, str(REPO / "scripts"))
    import build_mra
    text = build_mra.DRIVER.read_text(encoding="utf-8", errors="replace")
    return build_mra.game_info(text, set_name)["machine"] != "avengrgs"


def set_gfx(set_name):
    """(layout, frac8) of a set, from its GAME line's machine config and its gfx1 size."""
    sys.path.insert(0, str(REPO / "scripts"))
    import build_mra
    text = build_mra.DRIVER.read_text(encoding="utf-8", errors="replace")
    layout = MACHINE_LAYOUT[build_mra.game_info(text, set_name)["machine"]]
    body = build_mra.ers.blocks(text)[set_name]
    size = build_mra.region_size(body, "gfx1")
    return layout, layout in (L_5BPP, L_6BPP) and size == 0x1800000


def gfx1_unit(tile, row):
    """SDRAM byte address of the 16-byte unit holding row `row` of tile `tile` (and its pair)."""
    return GFX1_BASE + (((tile >> 1) * 16 + row) << 4)


def download_address(addr, layout=L_4BPP, frac8=False, de156=False):
    """The SDRAM address the download path writes the .mra image byte at offset `addr` to:
    what rtl/memory/mlc_dl_xform.sv computes."""
    if de156 and addr < MAINCPU_BASE + 0x100000:
        return de156_prog_dest(addr)
    if GFX1_BASE <= addr < GFX1_BASE + GFX1_SIZE:
        a = addr - GFX1_BASE
        # the .mra's padding after a short region goes past the last region (mlc_dl_xform.sv)
        if (layout == L_ACCHI and a >= 0x1400000) or (layout in (L_5BPP, L_6BPP) and not frac8 and a >= 0xC00000):
            return IMAGE_END + (addr & 1)
        return GFX1_BASE + gfx1_dest(a, layout, frac8)
    return addr


def build_image(set_name, debug=REPO / "debug"):
    """The whole SDRAM image from debug/<set>_<region>.bin (MAME region order)."""
    img = bytearray(IMAGE_END)
    layout, frac8 = set_gfx(set_name)
    de156 = set_de156(set_name)
    for name, base, size in REGIONS:
        p = debug / f"{set_name}_{name}.bin"
        if not p.exists():
            print(f"{p.name} missing: {name} left zero", file=sys.stderr)
            continue
        data = p.read_bytes()
        assert len(data) <= size, f"{p.name}: {len(data):#x} bytes, the window is {size:#x}"
        if name == "gfx1":
            # every layout keeps a byte pair together (acchi's 16-bit rows), the others four
            step = 2 if layout == L_ACCHI else 4
            for a in range(0, len(data), step):
                d = gfx1_dest(a, layout, frac8)
                img[base + d:base + d + step] = data[a:a + step]
        elif name == "maincpu" and de156:
            for a in range(0, len(data), 4):
                d = de156_prog_dest(a)
                img[base + d:base + d + 4] = data[a:a + 4]
        else:
            img[base:base + len(data)] = data           # a region shorter than its window
    assert len(img) == IMAGE_END
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
    # the deeper layouts: an injection into the window, and a tile row read back from the image
    # the way rtl/video/mlc_sprite_draw.sv reads it decodes to MAME's pens (render_model.Gfx)
    import random
    sys.path.insert(0, str(REPO / "scripts"))
    import render_model as rm
    names = {L_4BPP: "4bpp", L_5BPP: "5bpp", L_6BPP: "6bpp", L_ACCHI: "acchi"}
    rnd = random.Random(5)
    for layout, frac8, size in ((L_4BPP, False, 0x1800000), (L_6BPP, True, 0x1800000), (L_6BPP, False, 0xC00000),
                                (L_5BPP, False, 0xC00000), (L_ACCHI, False, 0x1400000)):
        step = 2 if layout == L_ACCHI else 4
        dests = {gfx1_dest(a, layout, frac8) for a in range(0, size, step)}
        assert len(dests) == size // step and max(dests) < GFX1_SIZE, (layout, frac8)
        region = bytes(rnd.getrandbits(8) for _ in range(size)) if size <= 0x400000 else None
        if region is None:
            region = bytearray(size)
            for i in range(0, size, 4096):
                region[i:i + 64] = bytes(rnd.getrandbits(8) for _ in range(64))
            region = bytes(region)
        img = bytearray(GFX1_SIZE)
        for a in range(0, size, step):
            d = gfx1_dest(a, layout, frac8)
            img[d:d + step] = region[a:a + step]
        g = rm.Gfx(region, names[layout])
        for _ in range(400):
            t, r = rnd.randrange(g.elements), rnd.randrange(16)
            u = (((t >> 1) << 4) | r) << 4
            base = img[u + (t & 1) * 8:u + (t & 1) * 8 + 8]
            xu = GFX1_EXT_OFF + ((((t >> 2) << 4) | r) << 4) + (t & 3) * 4
            ext = img[xu:xu + 4] if layout != L_4BPP else bytes(4)
            for x in range(16):
                byte, bit = 1 - (x >> 3), x & 7            # MAME bit 15 - x of a 16-bit plane, as pix4
                pen = 0
                for k, src in enumerate((base[0:2], base[2:4], base[4:6], base[6:8], ext[0:2], ext[2:4])):
                    pen |= ((src[byte] >> bit) & 1) << k
                pen &= (1 << g.nplanes) - 1
                assert pen == g.row(t, r)[x], (names[layout], frac8, t, r, x, pen, g.row(t, r)[x])
    # the DE156 program's placement is a bijection, and word a of the image is raw word
    # AddrScramble(a) (deco156.cpp)
    masks = [0xce4a, 0x4db2, 0xef60, 0x5737, 0x13dc, 0x4bd9, 0xa209, 0xd996, 0xa700, 0xeca0, 0x7529, 0x3100,
             0x33b4, 0x6161, 0x1eef, 0xf5a5]
    seen = set()
    for r in range(0x40000):
        d = de156_prog_dest(r << 2) >> 2
        seen.add(d)
        lo = 0x92C6
        for i in range(16):
            if (d >> i) & 1:
                lo ^= masks[i]
        assert (d & 0x30000) | lo == r, (hex(r), hex(d))
    assert len(seen) == 0x40000
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
