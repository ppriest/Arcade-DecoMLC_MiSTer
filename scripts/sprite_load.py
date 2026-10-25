#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sprite fetches per scanline, from MAME, for the MLC sprite fetch budget.

    python scripts/sprite_load.py <set> [<set> ...] [--skip 600] [--frames 1800]
    python scripts/sprite_load.py <set> --coin 600 --skip 1500 --tag _play
    python scripts/sprite_load.py <set> --reuse

Dumps the sprite list, the IRQ and clip blocks and the DMA'd top of VRAM at every
vblank start (scripts/mame/sprdump.lua), and the whole VRAM once at the end, then
walks deco_mlc_v.cpp's draw_sprites() (lines 144-533) for every visible line of
every frame and counts what a per-scanline engine has to read:

    cand    list entries enabled and not clipped by Y whose block covers the line:
            one index-block read each (16 B VRAM or 8 B gfx2 ROM)
    rows    16-pixel tile rows of those blocks, before any X test
    vis     tile rows whose stretched span overlaps the clip window and the screen:
            one pixel fetch each (8 B at 4bpp, two per row in 8bpp pairs)
    pix     screen pixels those rows cover after zoom and clipping: the line
            buffer writes (a pair's two fetches make one row of pixels)
    tblrom  tile-table entries read from gfx2 ROM for visible rows (2 B each)
    tblram  tile-table entries read from VRAM for visible rows (4 B each)

Entries are walked as MAME walks them: 8bpp pairs count once with two pixel
fetches a row, auto-flicker entries only on their frames. The blank-row test of
the sibling tool is not done here. Raw dumps: debug/sprload/<set><tag>.bin and
<set><tag>_vram.bin. Snapshot of the last frame: debug/sprload/snap<tag>/.
"""
import argparse
import os
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, lua_env, lua_runner_env, mame_cmd,  # noqa: E402
                          mame_paths, regions)

SPR_WORDS = 0xC00
REC_SPR, REC_IRQ, REC_CLIP, REC_VTOP = 0x1800, 0x80, 0x80, 0x2400
REC = REC_SPR + REC_IRQ + REC_CLIP + REC_VTOP
VTOP = 0x1DC00                      # byte offset of the per-frame VRAM region
SCREEN_W = 320
VIS_TOP, VIS_BOT = 8, 247           # set_visarea (deco_mlc.cpp:553)
LINES = VIS_BOT - VIS_TOP + 1

# set: (zip, gfx2 file)  -- the index-block and tile-table ROM
ROMS = {
    "avengrgs":  ("avengrgs", "sf_02-0.6j"),
    "avengrgsj": ("avengrgs", "avengrgsj/sd_02-0.6j"),
}


def gfx2(game):
    zname, name = ROMS[game]
    for d in os.environ.get("MAME_ROMPATH", "").split(";") + [r"F:/Emulation/roms/MAME ROMs"]:
        zp = Path(d) / f"{zname}.zip"
        if zp.exists():
            return zipfile.ZipFile(zp).read(name)
    sys.exit(f"{zname}.zip not found in MAME_ROMPATH")


def run(game, skip, frames, coin, tag):
    mame_dir, exe = mame_paths()
    r = regions()
    out = REPO / "debug" / "sprload" / f"{game}{tag}.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    inp = r.get("inputs", {})
    env = dict(os.environ, **lua_env(r), **lua_runner_env("sprdump.lua"),
               SD_OUT=out.as_posix(), SD_VRAM=out.with_name(f"{game}{tag}_vram.bin").as_posix(),
               SD_SKIP=str(skip), SD_FRAMES=str(frames), SD_COIN=str(coin),
               SD_IN_COIN=inp.get("coin", "Coin 1"), SD_IN_START=inp.get("start", "1 Player Start"),
               SD_IN_HOLD=inp.get("hold", "P1 Right"), SD_IN_PULSE=inp.get("pulse", "P1 Button 1"))
    cmd = mame_cmd(exe, game, "sprdump.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(),
                    "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def u32(b, off):
    return int.from_bytes(b[off:off + 4], "big")


def sign11(v):
    return v - 0x800 if v & 0x400 else v


class Counts:
    __slots__ = ("cand", "rows", "vis", "pix", "tblrom", "tblram")

    def __init__(self):
        self.cand = [0] * LINES
        self.rows = [0] * LINES
        self.vis = [0] * LINES
        self.pix = [0] * LINES
        self.tblrom = [0] * LINES
        self.tblram = [0] * LINES


def frame_counts(rec, vram, rom, parity, detail=None):
    """One frame's per-line counts. rec: one dump record; vram: 128 KB with the
    frame's top region overlaid; rom: gfx2; parity: frame_number & 1.
    detail: (line, list) collects one tuple per block covering that line."""
    spr = rec[:REC_SPR]
    irq = [u32(rec, REC_SPR + i * 4) for i in range(32)]
    clip = [u32(rec, REC_SPR + REC_IRQ + i * 4) for i in range(32)]
    c = Counts()

    def w16(i):
        return int.from_bytes(spr[i * 2:i * 2 + 2], "big")

    offs = 0
    while offs < SPR_WORDS:
        pair = (offs + 8 < SPR_WORDS) and (w16(offs + 8 + 1) & 0x1000) and (w16(offs + 8) & 0x8000)
        if pair:
            offs += 8
        base = offs
        offs += 8
        w0, w1 = w16(base), w16(base + 1)
        if not (w0 & 0x8000):
            continue
        if (w1 & 0x2000) and parity:
            continue
        y = sign11(w16(base + 2) & 0x7FF)
        x = sign11(w16(base + 3) & 0x7FF)
        fx, fy = w1 & 0x8000, w1 & 0x4000
        raster_select = (w1 & 0x0180) >> 7
        raster_mode = (w1 >> 10) & 1
        clipper = (w1 >> 8) & 3
        clipper = ((clipper & 2) >> 1) | ((clipper & 1) << 1)
        if (w1 >> 10) & 2:
            clipper |= 4
        indx = w0 & 0x7FFF
        yscale = w16(base + 4) & 0x3FF
        xscale = w16(base + 5) & 0x3FF
        min_y, max_y = clip[clipper * 4], clip[clipper * 4 + 1]
        cx0, cx1 = clip[clipper * 4 + 2], clip[clipper * 4 + 3]
        cx0, cx1 = max(cx0, 0), min(cx1, SCREEN_W - 1)

        if indx & 0x4000:
            p = rom[indx * 8:indx * 8 + 8]
            if (p[5] & 1) and parity:
                continue
            h, w = p[1] & 0xF, p[3] & 0xF
            yoffs, xoffs = p[0], p[2]
            fy1, fx1 = p[1] & 0x10, p[3] & 0x10
            table = bool(p[4] & 0xC0)
            table_rom = False
            idx_rom = True
        else:
            o = (indx & 0x1FFF) * 16
            p0, p1, p2 = u32(vram, o), u32(vram, o + 4), u32(vram, o + 8)
            if (p2 & 0x100) and parity:
                continue
            h, w = (p0 >> 8) & 0xF, (p1 >> 8) & 0xF
            yoffs, xoffs = p0 & 0xFF, p1 & 0xFF
            fy1, fx1 = p0 & 0x1000, p1 & 0x1000
            table = bool(p2 & 0xC0)
            table_rom = bool(p2 & 3)
            idx_rom = False
        h = h or 16
        w = w or 16
        if fx1:
            fx ^= 0x8000
        if fy1:
            fy ^= 0x4000

        extra_x_scale = 0x100
        if raster_mode and raster_select in (1, 2, 3):
            b = {1: 6, 2: 9, 3: 12}[raster_select]
            y += sign11(irq[b] & 0x7FF)
            x += sign11(irq[b + 1] & 0x7FF)
            extra_x_scale = irq[b + 2] & 0x3FF

        yscale_frac = yscale << 8
        xs = xscale * extra_x_scale
        ybase = y << 16
        yinc = yscale_frac * 16
        ybase += ((yoffs - 15) * yscale_frac - (h - 1) * yinc) if fy else -(yoffs * yscale_frac)
        xbase = x << 16
        xinc = xs * 16
        xbase += ((xoffs - 15) * xs - (w - 1) * xinc) if fx else -(xoffs * xs)
        if not yscale_frac:
            continue
        ytop = ybase >> 16
        # lines with (bby << 16) // ratio < 16 * h, ratio == yscale_frac
        span = (16 * h * yscale_frac + 0xFFFF) >> 16
        # tile columns whose stretched span overlaps the clip window
        cols = pixels = 0
        for bx in range(w):
            sx = xbase + bx * xinc
            width = (xs * 16 + (sx & 0xFFFF)) >> 16
            sx >>= 16
            a, b = max(sx, cx0), min(sx + width, cx1 + 1)
            if width and a < b:
                cols += 1
                pixels += b - a
        px = 2 if pair else 1
        lo, hi = max(ytop, min_y, VIS_TOP), min(ytop + span - 1, max_y, VIS_BOT)
        if detail is not None and lo <= detail[0] <= hi:
            detail[1].append((base // 8, indx, w, h, x, y, xscale, yscale, cols, px,
                              "rom" if idx_rom else "ram", table, table_rom, clipper, (cx0, cx1)))
        for line in range(lo, hi + 1):
            i = line - VIS_TOP
            c.cand[i] += 1
            c.rows[i] += w
            c.vis[i] += cols * px
            c.pix[i] += pixels
            if table:
                if table_rom:
                    c.tblrom[i] += cols * px
                else:
                    c.tblram[i] += cols
    return c


def analyse(path, vram_path, rom):
    data = path.read_bytes()
    vram = bytearray(vram_path.read_bytes())
    nf = len(data) // REC
    hists = {k: {} for k in Counts.__slots__}
    worst = {k: (0, None) for k in Counts.__slots__}
    for f in range(nf):
        rec = data[f * REC:(f + 1) * REC]
        vram[VTOP:VTOP + REC_VTOP] = rec[REC_SPR + REC_IRQ + REC_CLIP:]
        c = frame_counts(rec, vram, rom, f & 1)
        for k in Counts.__slots__:
            arr = getattr(c, k)
            h = hists[k]
            for v in arr:
                h[v] = h.get(v, 0) + 1
            m = max(arr)
            if m > worst[k][0]:
                worst[k] = (m, (f, arr.index(m) + VIS_TOP))
    return nf, hists, worst


def pct(hist, q):
    total = sum(hist.values())
    acc = 0
    for k in sorted(hist):
        acc += hist[k]
        if acc >= q * total:
            return k
    return max(hist)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--line", metavar="FRAME:LINE",
                    help="list the blocks covering one line of one dumped frame (implies --reuse)")
    a = ap.parse_args()
    for g in a.sets:
        path = REPO / "debug" / "sprload" / f"{g}{a.tag}.bin"
        vpath = path.with_name(f"{g}{a.tag}_vram.bin")
        if not (a.reuse or a.line) or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag)
        if not path.exists() or path.stat().st_size < REC or not vpath.exists():
            print(f"{g}{a.tag}: no dump (MAME failed?)")
            continue
        if a.line:
            f, line = (int(v) for v in a.line.split(":"))
            data = path.read_bytes()
            vram = bytearray(vpath.read_bytes())
            rec = data[f * REC:(f + 1) * REC]
            vram[VTOP:VTOP + REC_VTOP] = rec[REC_SPR + REC_IRQ + REC_CLIP:]
            blocks = []
            frame_counts(rec, vram, gfx2(g), f & 1, (line, blocks))
            print(f"{g}{a.tag} frame {f} line {line}: {len(blocks)} blocks")
            print("  entry  index   w  h     x     y xscl yscl cols px  idx table  clip window")
            for e, indx, w, h, x, y, xs, ys, cols, px, idx, tbl, trom, clp, win in blocks:
                t = ("rom" if trom else "ram") if tbl else "-"
                print(f"  {e:5d} {indx:6x} {w:2d} {h:2d} {x:5d} {y:5d} {xs:4x} {ys:4x} {cols:4d} {px:2d}  {idx} {t:5s}  {clp} {win}")
            continue
        nf, hists, worst = analyse(path, vpath, gfx2(g))
        print(f"{g}{a.tag}: {nf} frames, {LINES} visible lines each; per line:")
        print(f"  {'count':8s} {'max':>5s} {'p99.9':>6s} {'p99':>5s} {'mean':>6s}  worst at (frame, line)")
        for k in Counts.__slots__:
            h = hists[k]
            mean = sum(v * n for v, n in h.items()) / sum(h.values())
            print(f"  {k:8s} {worst[k][0]:5d} {pct(h, 0.999):6d} {pct(h, 0.99):5d} {mean:6.1f}  {worst[k][1]}")


if __name__ == "__main__":
    sys.exit(main())
