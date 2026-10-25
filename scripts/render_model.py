#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The MLC sprite system as deco_mlc_v.cpp draws it, from a mame_capture.py directory.

    python scripts/render_model.py debug/avengrgs-attract2400            # render, compare, report
    python scripts/render_model.py debug/avengrgs-attract2400 --save     # also write model.png, diff.png
    python scripts/render_model.py debug/avengrgs-* --stats              # per-line engine statistics

A transcription of draw_sprites(), drawgfxzoomline() and screen_update() (deco_mlc_v.cpp lines
42-585 at mame0289-1527; "v NNN" below cites a line), the model the RTL is checked against
(Phase 1, docs/ROADMAP.md). The model is checked against MAME first: the rendered frame is
compared pixel for pixel with the capture's reference.png.

Inputs, from the capture directory, all big-endian 32-bit slots as the SH-2 reads them:
spritebuf.bin, the list MAME copied at the previous vblank start, which the frame is drawn from
(spriteram.bin, the live list, if absent); vram.bin; clipram.bin; irqram.bin; palette.bin
(16-bit entries in the low half of each slot, deco_mlc.cpp:331); manifest.txt (the frame
number, for auto-flicker); and the set's gfx1 and gfx2 region images, debug/<set>_gfx1.bin and
_gfx2.bin, built from the zip per ROM_START.

MAME draws each scanline at that line's start (VIDEO_UPDATE_SCANLINE, deco_mlc.cpp:570), so a
line sees the RAM as it was then. The game DMAs the top 9 KB of VRAM during line 10 (and the
last 54 words in line 11) and the whole palette during line 11 (docs/write_timing_mame.txt);
the capture's dumps are from the frame's end. palette_prev.bin and vramtop_prev.bin, the same
areas at the end of the previous frame, serve the lines drawn before the DMA: --pal-line and
--vram-line name the first line that sees the new contents.

What MAME leaves undefined is reproduced as MAME has it, not guessed (docs/MAME_KLUDGES.md).
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SCREEN_W, SCREEN_H = 320, 240
VIS_TOP = 8                      # set_visarea rows 8-247 (deco_mlc.cpp:567)
VRAM_TOP = 0x1DC00               # byte offset of the DMA'd top of VRAM (0x29dc00)

# gfx_layout spritelayout_4bpp (deco_mlc.cpp:482-492): 16x16, planes at RGN_FRAC(1,2)+16,
# RGN_FRAC(1,2)+0, 16, 0 (the first plane listed is the pen's MSB), x bit offsets 15..0, rows 32
# bits apart, 512 bits a tile. MAME reads bits MSB-first within a byte.
GFX1_BYTES = 0x1800000
HALF = GFX1_BYTES // 2
ELEMENTS = HALF // 64            # gfx->elements(): 196,608 tiles


class Gfx:
    """Tile rows decoded as MAME's gfx_element decodes them, cached per (tile, row)."""

    def __init__(self, gfx1):
        assert len(gfx1) == GFX1_BYTES, f"gfx1 image is {len(gfx1):#x} bytes, region is {GFX1_BYTES:#x}"
        self.rom = gfx1
        self.cache = {}
        self.wrapped = 0         # tile codes >= elements(), reduced modulo as MAME does (v 96)

    def row(self, tile, r):
        key = (tile, r)
        v = self.cache.get(key)
        if v is not None:
            return v
        if tile >= ELEMENTS:
            self.wrapped += 1
            tile %= ELEMENTS
        base = tile * 64 + r * 4           # the row's 32-bit group, same offset in each half
        a = self.rom[base:base + 4]
        b = self.rom[HALF + base:HALF + base + 4]
        pix = [0] * 16
        for x in range(16):
            bit = 15 - x                   # plane offset 0: pen bit 0 (first half)
            p0 = (a[bit >> 3] >> (7 - (bit & 7))) & 1
            bit1 = 16 + 15 - x             # plane offset 16: pen bit 1 (first half)
            p1 = (a[bit1 >> 3] >> (7 - (bit1 & 7))) & 1
            p2 = (b[bit >> 3] >> (7 - (bit & 7))) & 1       # RGN_FRAC(1,2)+0: bit 2
            p3 = (b[bit1 >> 3] >> (7 - (bit1 & 7))) & 1     # RGN_FRAC(1,2)+16: bit 3
            pix[x] = (p3 << 3) | (p2 << 2) | (p1 << 1) | p0
        self.cache[key] = pix
        return pix


def u16_slots(b):
    """16-bit words from big-endian 32-bit slots (the low half of each)."""
    return [int.from_bytes(b[i + 2:i + 4], "big") for i in range(0, len(b), 4)]


def u32_words(b):
    return [int.from_bytes(b[i:i + 4], "big") for i in range(0, len(b), 4)]


def sign11(v):
    """v 216-217: an 11-bit position, bit 10 the sign."""
    return v - 0x800 if v & 0x400 else v


def s32(v):
    return v - (1 << 32) if v & 0x80000000 else v


def pal5(v):
    return (v << 3) | (v >> 2)


def pens_from(slots):
    """palette_device::xBGR_555 (xBBBBBGGGGGRRRRR): R in bits 4:0, G 9:5, B 14:10. 0xRRGGBB."""
    return [(pal5(c & 31) << 16) | (pal5((c >> 5) & 31) << 8) | pal5((c >> 10) & 31) for c in slots[:2048]]


class Capture:
    def __init__(self, d):
        d = Path(d)
        self.dir = d
        spr = d / "spritebuf.bin"
        self.from_buffer = spr.exists()
        if not self.from_buffer:
            spr = d / "spriteram.bin"
        self.spr = u16_slots(spr.read_bytes())            # 0xC00 words: 384 entries of 8
        self.vram = (d / "vram.bin").read_bytes()         # 128 KB
        self.clip = u32_words((d / "clipram.bin").read_bytes())
        self.irq = u32_words((d / "irqram.bin").read_bytes())
        self.pal = u16_slots((d / "palette.bin").read_bytes())
        self.pal_prev = self.vram_prev = None
        p = d / "palette_prev.bin"
        if p.exists():
            self.pal_prev = u16_slots(p.read_bytes())
        p = d / "vramtop_prev.bin"
        if p.exists():
            top = p.read_bytes()
            self.vram_prev = self.vram[:VRAM_TOP] + top
            assert len(self.vram_prev) == len(self.vram)
        self.frame = 0
        self.set = None
        for line in (d / "manifest.txt").read_text().splitlines():
            if line.startswith("frame "):
                self.frame = int(line.split()[1])
            if line.startswith("set "):
                self.set = line.split()[1]


class Model:
    def __init__(self, cap, gfx, gfx2, pal_line=12, vram_line=11, parity=None):
        self.cap = cap
        self.gfx = gfx
        self.gfx2 = gfx2
        # video_start (v 20-29) with a 4bpp gfx: granularity 16, 0x800 / 16 = 0x80 colours
        self.colour_mask = 0x7F
        self.shadow_mask = 0x80 | 0x100
        self.shadow_shift = 11 - 4
        self.pens_post = pens_from(cap.pal)
        self.pens_pre = pens_from(cap.pal_prev) if cap.pal_prev else self.pens_post
        self.vram_post = cap.vram
        self.vram_pre = cap.vram_prev if cap.vram_prev else cap.vram
        self.pal_line = pal_line
        self.vram_line = vram_line
        self.parity = (cap.frame & 1) if parity is None else parity
        self.vram = self.vram_post
        self.pens = self.pens_post
        self.stats = None
        self.trace_line = None

    def vram_u32(self, index):
        o = index * 4
        return int.from_bytes(self.vram[o:o + 4], "big")

    # --- drawgfxzoomline (v 42-141) -----------------------------------------------------
    def draw_row(self, dest, pri, clip_l, clip_r, code1, code2, color, flipx, sx, use8bpp,
                 scalex, srcline, shadow_mode):
        if not scalex:
            return 0
        alpha_mode = self.cap.irq[1] & 0xC0
        width = (scalex * 16 + (sx & 0xFFFF)) >> 16
        sx >>= 16
        if not width:
            return 0
        dx = (16 << 16) // width
        ex = sx + width
        x_index = (width - 1) * dx if flipx else 0
        if flipx:
            dx = -dx
        if sx < clip_l:
            pixels = clip_l - sx
            sx += pixels
            x_index += pixels * dx
        if ex > clip_r + 1:
            ex = clip_r + 1
        if ex <= sx:
            return 0
        src1 = self.gfx.row(code1, srcline)
        src2 = self.gfx.row(code2, srcline) if use8bpp else None
        pal_base = 16 * (color % 256)     # gfx(0): colorbase 0, 256 colours (deco_mlc.cpp:531)
        drawn = 0
        if shadow_mode and alpha_mode:
            for x in range(sx, ex):
                if not (pri[x] & 0x80):
                    c = src1[x_index >> 16]
                    if use8bpp:
                        c = (c << 4) | src2[x_index >> 16]
                    if c != 0:
                        pri[x] |= shadow_mode
                x_index += dx
        else:
            for x in range(sx, ex):
                if not (pri[x] & 0x80):
                    c = src1[x_index >> 16]
                    if use8bpp:
                        c = (c << 4) | src2[x_index >> 16]
                    if c != 0:
                        dest[x] = pal_base + c
                        pri[x] |= 0x80 | shadow_mode
                        drawn += 1
                x_index += dx
        return drawn

    # --- draw_sprites (v 144-533) -------------------------------------------------------
    def draw_line(self, scanline, dest, pri, stat=None):
        cap = self.cap
        spr = cap.spr
        parity = self.parity
        offs = 0
        while offs < 0xC00:
            use8bpp = (offs + 8 < 0xC00) and (spr[offs + 8 + 1] & 0x1000) and (spr[offs + 8] & 0x8000)
            if use8bpp:
                offs += 8
            if not (spr[offs] & 0x8000):
                offs += 8
                continue
            if (spr[offs + 1] & 0x2000) and parity:
                offs += 8
                continue
            y = sign11(spr[offs + 2] & 0x7FF)
            x = sign11(spr[offs + 3] & 0x7FF)
            fx = spr[offs + 1] & 0x8000
            fy = spr[offs + 1] & 0x4000
            color = spr[offs + 1] & 0xFF
            raster_select = (spr[offs + 1] & 0x0180) >> 7
            raster_mode = (spr[offs + 1] >> 10) & 1
            clipper = (spr[offs + 1] >> 8) & 3
            indx = spr[offs] & 0x7FFF
            yscale = spr[offs + 4] & 0x3FF
            xscale = spr[offs + 5] & 0x3FF
            color_offset = 0
            clipper = ((clipper & 2) >> 1) | ((clipper & 1) << 1)
            if (spr[offs + 1] >> 10) & 2:
                clipper |= 4
            min_y = cap.clip[clipper * 4]
            max_y = cap.clip[clipper * 4 + 1]
            if scanline < min_y or scanline > max_y:
                offs += 8
                continue
            # user_clip (v 259-260): the window's x range as signed 32-bit, cut to the screen
            clip_l = max(s32(cap.clip[clipper * 4 + 2]), 0)
            clip_r = min(s32(cap.clip[clipper * 4 + 3]), SCREEN_W - 1)
            shadow_mode = (color & self.shadow_mask) >> self.shadow_shift
            color &= self.colour_mask
            if use8bpp:
                color = spr[offs + 1 - 8] & 0x7F
            sprite2 = 0
            if stat is not None and indx & 0x4000:
                stat["fetch"] += 1                      # the index block from gfx2 (v 276)
                stat["units"] += 1
            if indx & 0x4000:
                p = self.gfx2[indx * 8:indx * 8 + 8]
                if (p[5] & 1) and parity:
                    offs += 8
                    continue
                h = p[1] & 0xF
                w = p[3] & 0xF
                h = h or 16
                w = w or 16
                sprite = (p[7] << 8) | p[6] | ((p[4] & 3) << 16)
                yoffs = p[0]
                xoffs = p[2]
                fy1 = (p[1] & 0x10) >> 4
                fx1 = (p[3] & 0x10) >> 4
                tile_format = p[4] & 0x80
                block_is_table = bool(p[4] & 0xC0)
                hibits = 0
                table_in_rom = 0
            else:
                i4 = (indx & 0x1FFF) * 4
                p0, p1, p2, p3 = (self.vram_u32(i4 + k) for k in range(4))
                if (p2 & 0x100) and parity:
                    offs += 8
                    continue
                h = (p0 >> 8) & 0xF
                w = (p1 >> 8) & 0xF
                h = h or 16
                w = w or 16
                sprite = ((p2 & 3) << 16) | (p3 & 0xFFFF)
                block_is_table = bool(p2 & 0xC0)
                tile_format = p2 & 0x80
                hibits = (p2 & 0x3C) << 10
                table_in_rom = p2 & 3
                yoffs = p0 & 0xFF
                xoffs = p1 & 0xFF
                fy1 = (p0 & 0x1000) >> 12
                fx1 = (p1 & 0x1000) >> 12
            if use8bpp:
                i2 = spr[offs - 8] & 0x7FFF
                if i2 & 0x4000:
                    q = self.gfx2[i2 * 8:i2 * 8 + 8]
                    sprite2 = (q[7] << 8) | q[6]
                else:
                    j4 = (i2 & 0x1FFF) * 4
                    sprite2 = ((self.vram_u32(j4 + 2) & 3) << 16) | (self.vram_u32(j4 + 3) & 0xFFFF)
            if fx1:
                fx ^= 0x8000
            if fy1:
                fy ^= 0x4000
            extra_x_scale = 0x100
            if raster_mode and raster_select in (1, 2, 3):
                base = {1: 6, 2: 9, 3: 12}[raster_select]
                extra_y_off = cap.irq[base] & 0x7FF
                extra_x_off = cap.irq[base + 1] & 0x7FF
                extra_x_scale = cap.irq[base + 2] & 0x3FF
                if extra_x_off & 0x400:
                    extra_x_off -= 0x800
                if extra_y_off & 0x400:
                    extra_y_off -= 0x800
                x += extra_x_off
                y += extra_y_off
            yscale_frac = yscale << 8
            real_h = h * 16
            xs = xscale * extra_x_scale
            ybase = y << 16
            yinc = yscale_frac * 16
            if fy:
                ybase += (yoffs - 15) * yscale_frac - (h - 1) * yinc
            else:
                ybase -= yoffs * yscale_frac
            xbase = x << 16
            xinc = xs * 16
            if fx:
                xbase += (xoffs - 15) * xs - (w - 1) * xinc
            else:
                xbase -= xoffs * xs
            ratio = (yscale_frac * real_h) // real_h          # v 427: yscale_frac
            if not ratio:
                offs += 8
                continue
            bby = scanline - (ybase >> 16)                   # C >> on a signed int: floor
            if bby < 0:
                offs += 8
                continue
            srcline = (bby << 16) // ratio
            by = srcline >> 4
            if by >= h:
                offs += 8
                continue
            srcline &= 0xF
            if fy:
                srcline = 15 - srcline
            if stat is not None:
                stat["blocks"] += 1
                if use8bpp and (spr[offs - 8] & 0x4000):
                    stat["fetch"] += 1                  # the pair's second block from gfx2 (v 342)
                    stat["units"] += 1
            tr = (self.trace_line == scanline)
            if tr:
                print(f"HIT entry {offs // 8} pair {int(bool(use8bpp))} bby {bby} y {y} x {x} yoffs {yoffs} xoffs {xoffs} h {h} w {w} fx {int(bool(fx))} fy {int(bool(fy))} "
                      f"xs {xs:x} yscale {yscale:x} sprite {sprite:x} sprite2 {sprite2:x} tbl {int(block_is_table)} rom {int(bool(table_in_rom))} "
                      f"fmt {int(bool(tile_format))} hib {hibits:x} color {color:x} shadow {shadow_mode} srcline {srcline} by {by} xbase {xbase:x}")
            for bx in range(w):
                realxbase = xbase + bx * xinc
                if fx:
                    count = (h - 1 - by) * w + (w - 1 - bx) if fy else by * w + (w - 1 - bx)
                else:
                    count = (h - 1 - by) * w + bx if fy else by * w + bx
                tile = sprite + count
                tile2 = sprite2 + count
                if block_is_table:
                    if table_in_rom:
                        t = self.gfx2[tile * 2] | (self.gfx2[tile * 2 + 1] << 8)
                        t2 = (self.gfx2[tile2 * 2] | (self.gfx2[tile2 * 2 + 1] << 8)) if use8bpp else 0
                        if tile_format:
                            color_offset = (t & 0xF000) >> 12
                            tile = (t & 0x0FFF) | hibits
                            tile2 = (t2 & 0x0FFF) | hibits
                        else:
                            color_offset = 0
                            tile = (t & 0xFFFF) | (hibits << 2)
                            tile2 = (t2 & 0xFFFF) | (hibits << 2)
                    else:
                        t = self.vram_u32(tile & 0x7FFF) & 0xFFFF
                        if tile_format:
                            color_offset = (t & 0xF000) >> 12
                            tile = (t & 0x0FFF) | hibits
                        else:
                            color_offset = 0
                            tile = (t & 0xFFFF) | (hibits << 2)
                        tile2 = 0
                if stat is not None:
                    stat["rows"] += 1
                    # what the engine fetches for this row (docs/phase1_video.md): the pixel
                    # granule(s) of a row that is not entirely outside the window, and a gfx2
                    # table granule whenever the stream's granule address changes
                    rsx = realxbase >> 16
                    rw_ = (xs * 16 + (realxbase & 0xFFFF)) >> 16
                    if xs and rw_ and rsx <= clip_r and rsx + rw_ > clip_l:
                        stat["fetch"] += 2 if use8bpp else 1
                        # rows a 16-byte unit (row r of tiles 2k, 2k+1) held per stream serves
                        ua = ((tile % ELEMENTS) >> 1, srcline)
                        if ua == stat["unitA"]:
                            stat["pairhit"] += 1
                        else:
                            stat["units"] += 1
                        stat["unitA"] = ua
                        if use8bpp:
                            ub = ((tile2 % ELEMENTS) >> 1, srcline)
                            if ub == stat["unitB"]:
                                stat["pairhit"] += 1
                            else:
                                stat["units"] += 1
                            stat["unitB"] = ub
                        if block_is_table and table_in_rom:
                            ga = ((sprite + count) * 2) & ~15          # a 16-byte unit of 8 entries
                            if ga != stat["holdA"]:
                                stat["holdA"] = ga
                                stat["fetch"] += 1
                                stat["units"] += 1
                            if use8bpp:
                                gb = ((sprite2 + count) * 2) & ~15
                                if gb != stat["holdB"]:
                                    stat["holdB"] = gb
                                    stat["fetch"] += 1
                                    stat["units"] += 1
                if tr:
                    rw = (xs * 16 + (realxbase & 0xFFFF)) >> 16
                    print(f"   ROW bx {bx} tile {tile % ELEMENTS:x} tile2 {tile2:x} coloff {color_offset} sx {realxbase >> 16} width {rw}")
                n = self.draw_row(dest, pri, clip_l, clip_r, tile, tile2, color + color_offset,
                                  fx, realxbase, use8bpp, xs, srcline, shadow_mode)
                if stat is not None:
                    stat["pixels"] += n
            offs += 8

    # --- screen_update (v 549-585), one call per scanline --------------------------------
    def render(self, stats=False):
        img = np.zeros((SCREEN_H, SCREEN_W, 3), dtype=np.uint8)
        self.penmap = np.zeros((SCREEN_H, SCREEN_W), dtype=np.uint16)   # {written, 2'b0, flags, pen}
        self.stats = [] if stats else None
        hold = (-1, -1)
        unit = (None, None)
        for row in range(SCREEN_H):
            scanline = row + VIS_TOP
            self.pens = self.pens_post if scanline >= self.pal_line else self.pens_pre
            self.vram = self.vram_post if scanline >= self.vram_line else self.vram_pre
            pen0 = self.pens[0]
            dest = [0] * SCREEN_W
            pri = [0] * SCREEN_W
            stat = {"blocks": 0, "rows": 0, "pixels": 0, "fetch": 0, "holdA": hold[0], "holdB": hold[1],
                    "pairhit": 0, "unitA": unit[0], "unitB": unit[1], "units": 0} if stats else None
            self.draw_line(scanline, dest, pri, stat)
            if stats:
                hold = (stat["holdA"], stat["holdB"])          # the table holds survive across lines;
                unit = (None, None)                             # the row units are forgotten at line_start
                self.stats.append(stat)
            for x in range(SCREEN_W):
                self.penmap[row, x] = ((pri[x] >> 7) << 15) | ((pri[x] & 3) << 11) | (dest[x] if pri[x] & 0x80 else 0)
                col = self.pens[dest[x]] if (pri[x] & 0x80) else pen0     # v 553: pen 0 fill
                flag = pri[x] & 3
                if flag and flag != 3:                                      # v 572-580
                    if flag & 1:
                        col = (col & 0xFEFEFE) >> 1
                    else:
                        col = ((col & 0xFEFEFE) >> 1) | 0x808080
                img[row, x] = ((col >> 16) & 0xFF, (col >> 8) & 0xFF, col & 0xFF)
        return img


def load_roms(set_name):
    g1 = (REPO / "debug" / f"{set_name}_gfx1.bin").read_bytes()
    g2 = (REPO / "debug" / f"{set_name}_gfx2.bin").read_bytes()
    return g1, g2


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+")
    ap.add_argument("--save", action="store_true", help="write model.png and diff.png beside the capture")
    ap.add_argument("--stats", action="store_true", help="per-line blocks, tile rows and pixels drawn")
    ap.add_argument("--pal-line", type=int, default=12, help="first scanline drawn with the frame-end palette")
    ap.add_argument("--vram-line", type=int, default=11, help="first scanline drawn with the frame-end VRAM top")
    ap.add_argument("--parity", type=int, choices=(0, 1), help="override the frame parity for auto-flicker")
    ap.add_argument("--rtl", action="store_true", help="also compare the capture's rtl.rgb (sim/sprite_tb) with MAME")
    ap.add_argument("--flip", action="store_true", help="rtl.rgb was rendered with flip screen: compare with MAME's frame rotated 180 degrees")
    ap.add_argument("--trace-line", type=int, help="print every hit and row of this scanline (MAME numbering)")
    a = ap.parse_args()
    rc = 0
    roms = {}
    for c in a.captures:
        cap = Capture(c)
        if cap.set not in roms:
            roms[cap.set] = load_roms(cap.set)
        g1, g2 = roms[cap.set]
        gfx = Gfx(g1)
        model = Model(cap, gfx, g2, a.pal_line, a.vram_line, a.parity)
        model.trace_line = a.trace_line
        img = model.render(stats=a.stats)
        ref = np.asarray(Image.open(Path(c) / "reference.png").convert("RGB"))
        if ref.shape != img.shape:
            print(f"{c}: reference is {ref.shape[1]}x{ref.shape[0]}, model {SCREEN_W}x{SCREEN_H}")
            rc = 1
            continue
        diff = np.any(ref != img, axis=2)
        n = int(diff.sum())
        notes = []
        if not cap.from_buffer:
            notes.append("no spritebuf.bin: drawn from the live list")
        if cap.pal_prev is None or cap.vram_prev is None:
            notes.append("no prev dumps: every line drawn from the frame-end RAM")
        if gfx.wrapped:
            notes.append(f"{gfx.wrapped} tile codes beyond the region, wrapped as MAME does")
        note = f" ({'; '.join(notes)})" if notes else ""
        if n == 0:
            print(f"{c}: frame {cap.frame}: pixel-identical to MAME{note}")
        else:
            rc = 1
            ys, xs = np.nonzero(diff)
            rows = sorted(set(ys.tolist()))
            print(f"{c}: frame {cap.frame}: {n} of {SCREEN_W * SCREEN_H} pixels differ on {len(rows)} rows "
                  f"(screen rows {rows[0]}-{rows[-1]}); first at ({xs[0]},{ys[0]}) model "
                  f"{tuple(int(v) for v in img[ys[0], xs[0]])} MAME {tuple(int(v) for v in ref[ys[0], xs[0]])}{note}")
        if a.rtl:
            raw = (Path(c) / "rtl.rgb").read_bytes()
            rtl = np.frombuffer(raw, dtype=np.uint8).reshape(SCREEN_H, SCREEN_W, 3)
            if a.flip:
                rtl = np.ascontiguousarray(np.rot90(rtl, 2))      # back to the unflipped frame
            rd = np.any(ref != rtl, axis=2)
            m = int(rd.sum())
            if m == 0:
                print(f"   RTL: pixel-identical to MAME")
            else:
                rc = 1
                ys, xs = np.nonzero(rd)
                rows = sorted(set(ys.tolist()))
                print(f"   RTL: {m} pixels differ from MAME on {len(rows)} rows (screen rows {rows[0]}-{rows[-1]}); "
                      f"first at ({xs[0]},{ys[0]}) RTL {tuple(int(v) for v in rtl[ys[0], xs[0]])} "
                      f"MAME {tuple(int(v) for v in ref[ys[0], xs[0]])}")
                d = np.zeros_like(img)
                d[rd] = (255, 0, 255)
                Image.fromarray(d).save(Path(c) / "rtl_diff.png")
                Image.fromarray(rtl).save(Path(c) / "rtl.png")
            pens_path = Path(c) / "rtl_pens.bin"
            if pens_path.exists() and not a.flip:
                rp = np.frombuffer(pens_path.read_bytes(), dtype=">u2").reshape(SCREEN_H, SCREEN_W)
                rp = np.where(rp & 0x8000, rp, rp & 0x1800)      # an unwritten pen is stale RAM
                pd = rp != model.penmap
                print(f"   RTL pens: {int(pd.sum())} pixels differ from the model")
                ys, xs = np.nonzero(pd)
                for k in range(min(12, len(ys))):
                    y, x = int(ys[k]), int(xs[k])
                    print(f"      ({x},{y}) model {model.penmap[y, x]:04x} RTL {rp[y, x]:04x}")
        if a.save:
            Image.fromarray(img).save(Path(c) / "model.png")
            d = np.zeros_like(img)
            d[diff] = (255, 0, 255)
            Image.fromarray(d).save(Path(c) / "diff.png")
        if a.stats:
            rows_ = [s["rows"] for s in model.stats]
            pix = [s["pixels"] for s in model.stats]
            blk = [s["blocks"] for s in model.stats]
            fet = [s["units"] for s in model.stats]
            ph = [s["pairhit"] for s in model.stats]
            worst = max(range(SCREEN_H), key=lambda i: fet[i])
            print(f"   16-byte units: {sum(ph)} of {sum(s['fetch'] for s in model.stats)} fetches held by the stream's "
                  f"last unit ({100 * sum(ph) / max(1, sum(s['fetch'] for s in model.stats)):.0f}%)")
            print(f"   per line: blocks max {max(blk)} mean {sum(blk) / SCREEN_H:.1f}; tile rows max {max(rows_)} "
                  f"mean {sum(rows_) / SCREEN_H:.1f}; units max {max(fet)} (scanline {worst + VIS_TOP}) "
                  f"mean {sum(fet) / SCREEN_H:.1f}; pixels written max {max(pix)} mean {sum(pix) / SCREEN_H:.1f}")
            lines_path = Path(c) / "rtl_lines.txt"
            if a.rtl and lines_path.exists():
                bad = []
                for ln in lines_path.read_text().splitlines()[1:]:
                    f = ln.split()
                    if int(f[2]) != fet[int(f[0]) - VIS_TOP]:
                        bad.append((int(f[0]), int(f[2]), fet[int(f[0]) - VIS_TOP]))
                if bad:
                    print(f"   RTL units differ from the model on {len(bad)} lines, first {bad[:5]} (line, RTL, model)")
                else:
                    print(f"   RTL units per line equal the model's on every line")
    return rc


if __name__ == "__main__":
    sys.exit(main())
