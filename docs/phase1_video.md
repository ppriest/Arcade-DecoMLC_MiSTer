# Phase 1: the sprite engine

The MLC's video is sprites only: `deco_mlc_v.cpp` (v NNN cites a line at mame0289-1527),
transcribed in `scripts/render_model.py`, which with `--zoom mame` is pixel-identical to MAME on the five captures
(`docs/ROADMAP.md`, Progress). The RTL under `rtl/video/` is checked against those captures in
`sim/sprite_tb`. This file is the design: what each block does, the arithmetic, the budget, and
what is knowingly not MAME.

## Timing

`clk_sys` 84 MHz; pixel clock 7 MHz, 442 x 274 (ROADMAP, Clocks): **5304 clocks a line**, 3840
of them visible (320 pixels). MAME's scanline numbers are kept: visible lines are 8-247 (mlc 567),
the clip windows and the raster registers compare against them, and the line counter in
`mlc_video_timing` runs 0-273 with line 248 as vblank start, the list snapshot point
(`write_timing_mame.txt`).

The engine renders one line ahead of scan-out: at the first clock of line L's period it is given
line L+1 (`line_start`, `render_line`), the line buffer swaps banks, and scan-out reads line L
from the other bank. The period is the deadline: at the next `line_start` whatever is unfinished
is dropped (`ovr_ev`), the entries not reached being the lowest-priority ones since the list is
walked front to back (LESSONS, "A back-to-front line buffer cannot drop the right sprites").

## Memory

| Store | Where | Ports | Notes |
|---|---|---|---|
| sprite list, live | `mlc_sprite_list`, 3072 x 16 BRAM | CPU write (16-bit in 32-bit slots, mlc 254-280) | reads return `0xffff` in the upper half |
| sprite list, snapshot | same module, 3072 x 16, read as 128-bit entries | copy at line 248, 3072 clocks; engine read | the copy writes through: a CPU write landing behind the cursor during the copy goes to both (LESSONS, "A snapshot is a race") |
| VRAM | `mlc_vram`, 128 KB | CPU 32-bit write; engine 128-bit read (index blocks) with 32-bit lane select (tile tables) | read live, as MAME (v 308, 506) |
| palette | 2048 x 16 | CPU write; scan-out read | read live at scan-out |
| clip windows | 8 x 4 registers | CPU write | min_y/max_y 10-bit, min_x/max_x clamped to the screen at write (below) |
| IRQ block words 1, 6-14 | registers | CPU write | alpha (v 47), the three raster sets (v 375-392) |
| gfx1 | SDRAM `0x0100000`, 24 MB | engine, 16-byte units, two in flight | one unit = the same 16-pixel row of two consecutive tiles (below) |
| gfx2 | SDRAM `0x1900000`, 512 KB | engine, 16-byte units | index blocks (8 B, half a unit); tile tables (2 B, eight a unit, the last unit held per stream) |
| line buffers | `mlc_line_buffer`, 2 x 320 | engine write, scan-out read | pen index in BRAM; written and shadow flags in registers, cleared in one clock at the swap |

**The deeper layouts (DecoMLC156).** 5bpp (hoops), 6bpp (stadhr96, skullfng) and acchi's own
5-plane layout keep pen bits 0-3 in the 4bpp unit layout below, in the first 16 MB of the window,
and pen bits 4-5 in an extra area 16 MB in: a 16-byte unit is row r of tiles 4k..4k+3, 4 bytes
each, bit 4 from bytes 0-1 and bit 5 from bytes 2-3. A row costs a second unit only when it
leaves the extra unit's four tiles. `mlc_dl_xform.sv` and `mlc_layout.gfx1_dest` give the mapping
per layout; `mlc_layout.py --selftest` decodes tile rows from the transformed image against MAME's
decode, and `sim/download_tb` checks the RTL against it (stadhr96u, hoops96, acchi: every unit).
The colour granule, the shadow bits and the tile count follow the layout (v 20-29, 96, 262-265).

**gfx1 layout** (`scripts/mlc_layout.py`, `rtl/memory/mlc_dl_xform.sv`). MAME's region keeps a
tile's two plane pairs `RGN_FRAC(1,2)` = 12 MB apart (mlc 482-492): row r of tile t is bytes
`t*64 + r*4 .. +3` in each half. The SDRAM image stores 16-byte units: row r of tiles 2k and
2k+1, each tile's eight bytes as `a0 a1 a2 a3 b0 b1 b2 b3` (first half, second half). Region byte
`a`, with `h = a >= 0xC00000` and `o = a - h * 0xC00000`, lands at `GFX1_BASE + {o[23:7], o[5:2],
o[6], h, o[1:0]}`; the unit for (t, r) is at `GFX1_BASE + ((t >> 1) * 16 + r) * 16`, tile t in
its half `t & 1`. Pixel x (0 = left) of a row is `{ {b2,b3}[x], {b0,b1}[x], {a2,a3}[x], {a0,a1}[x]
}`, each pair read as a big-endian 16-bit word (MAME's `readbit` is MSB-first within a byte;
planes v 487). A unit's byte k is `rdata[8k+7:8k]`. The download path applies the transform
(`mlc_dl_xform`); the download bench checks it byte for byte against `mlc_layout.py`. On the five
captures the model counts 44-72% of the rows fetched as served by the stream's previous unit.

**Tile codes** are 18 bits (`hibits << 2 | 0xffff`, v 500); the gfx has 196,608 tiles (`0x30000`)
and MAME reduces the code modulo that (v 96); the engine subtracts `0x30000` once when the code is
at or above it, the same result for codes below `0x60000`. No capture reaches it
(`render_model.py` counts them).

## The engine, per line

Three stages, decoupled by a FIFO of hits, so the scan of entries that miss the line overlaps the
drawing of those that hit.

**Candidate list, once a frame** (`mlc_sprite_list`, after the snapshot copy): the 384 entries
walked as v 161-171 does, in order: at entry i, if entry i+1 has bits `0x1000` and `0x8000` the pair
(main i+1, colour and second block from i) is one candidate and the walk skips both; else entry i
is a candidate if enabled (bit 15) and not flicker-skipped (bit `0x2000` with the frame parity);
disabled entries are dropped. Output: up to 384 of {index, pair}. 384 clocks.

**Scanner** (`mlc_sprite_scan`), per candidate, in list order:

1. Read the entry (one 128-bit read; the pair's first entry too).
2. Clip window: `clipper = swap(bits 9:8) | bit 11 << 2` (v 245-251); skip if `scanline < min_y`
   or `> max_y`.
3. Index block: VRAM (16 B, one read) or gfx2 ROM (8 B, one granule, the scanner waits); fields
   per v 274-335; skip on the block's flicker bit.
4. y: with `fy` the XOR of the list and block flips, `coef_y = fy ? yoffs - 16h + 1 : -yoffs`,
   `ybase_int = y + ((coef_y * yscale) >>> 8)` (v 404-410 with `yscale_frac = yscale << 8`),
   `bby = scanline - ybase_int`. Hit if `bby >= 0` and `bby * 16 < h * yscale`, which is v
   439-444's `by < h` exactly: `by = floor(bby * 256 / yscale) >> 4 = floor(bby * 16 / yscale)`.
   The two products share one radix-4 stepper over `yscale`'s ten bits, five clocks.
5. Raster set (v 362-397): `x`, `y` offsets added before step 4; `extra_x_scale` carried.

A hit carries the entry's and the block's fields and `bby` into the FIFO (16 deep; the scanner
stalls when it is full). Cost about nine clocks per VRAM-block candidate, about twenty for a
ROM-block one, so 92 enabled entries (the most in the five lists) are about 900 clocks and a
pathological list of 384 about 3500, under the drawer's worst case and in parallel with it.

**Setup** (`mlc_sprite_draw`, first stage), per hit, overlapping the previous hit's rows:

- `srcline = floor(bby * 256 / yscale)`: an eight-step restoring divider (the quotient is below
  256 because the hit test holds); `by = srcline >> 4`; `srcline &= 15`, `15 - srcline` if `fy`.
- `xs = xscale * extra_x_scale` (ten steps; `xscale << 8` when the raster set is off, v 356);
  `coef_x = fx ? xoffs - 16w + 1 : -xoffs`; `xbase = (x << 16) + coef_x * xs` (v 412-418);
  `xinc = xs << 4`.
- `count0 = by * w` (v 456-469, with `h - 1 - by` for `fy` and `w - 1 - bx` for `fx`): stepped.

**Row loop** (second stage, `R`), for `bx` in `0..w-1`, issuing ahead of the emitter:

- `tile = sprite + count`, `tile2 = sprite2 + count`; if the block is a table (v 474-522): VRAM
  table one read, ROM table one granule (held: consecutive tiles read consecutive entries, so a
  granule serves four); `color_offset` from the entry's top nibble in the 12-bit format.
- `realxbase = xbase + bx * xinc`, accumulated; `sx = realxbase >>> 16`, `frac = realxbase[15:0]`;
  `width = (xs * 16 + frac) >> 16` (v 56), MAME's span `[sx, sx + width)`. It only decides the
  fetch: a tile more than two pixels right of the window ends the hit, one more than two pixels
  left of it is pushed as a walk (no unit, nothing written). The accumulator's span is within two
  pixels of MAME's (the step rounded up by under 2^-16 over at most 256 columns).
- `S` computes `step = ceil(2^32 / xs)` once per hit with a 33-step bit-serial divider, skipped for
  xs = 1.0 and when xs equals the previous hit's; a step above 0x7fffffff (xs under 2^-15) or
  xs = 0 draws nothing (v 46).
- Unit fetch: the unit holding the row of `tile` (and of `tile2` in 8bpp) unless it is the
  stream's last one (then the emitter's copy serves). Requests go through the engine's two
  arbiter slots, so two are in flight; the answers come back in issue order into the row FIFO,
  the row's descriptor into a four-deep queue. The emitter takes a row from the queue, pops its
  new unit(s) from the FIFO, and then writes pixels. A line's end flushes both, drops the
  answers still in flight and forgets the streams' last units.
- Pixels, one a clock, from one source accumulator `s` and one screen x `d` per hit: the hit's
  first tile sets `s = 0`, `d = floor(xbase)`; each clock samples drawn tile `s >> 20`, column
  `(s >> 16) & 15` (mirrored when `fx`; R fetched the mirrored tile for that position), then
  `s += step`, `d += 1`, until `s` leaves the row's tile. A walked tile goes eight pixels a clock
  while eight fit. Left and right clipping (v 78-90) is the write condition `clip_l <= x <=
  clip_r`; the skipped pixels cost their clocks. A pixel is written when the pen is not 0 (v 113,
  130; 8bpp: `(c1 << 4) | c2`) and `written[x]` is clear. A shadow entry (`shadow_mode` from
  colour bits 8:7, v 263, with the alpha word's bits 7:6 set, v 101) only ORs its flags into
  `flags[x]` where `written[x]` is clear; any other entry writes the pen and ORs its
  `shadow_mode` into the flags (v 114, 132-133). MAME restarts each tile at its own
  `floor(realxbase)` with its own step (`MAME_KLUDGES.md`, "Zoom").

**Pen index** is `16 * (color % 256) + c` (v 95), 12 bits; 8bpp pairs can exceed 2047, which MAME
reads past its palette. The engine keeps 11 bits (`MAME_KLUDGES.md`).

**Scan-out** (`mlc_video`): per pixel, the pen from the display bank (pen 0 where `written` is
clear, v 553), the palette entry (xBGR_555, `pal5bit` each: `{v, v[4:2]}`), then the shadow pass
on the 8-bit channels: flags 1 `(v & 0xfe) >> 1`, flags 2 the same `| 0x80`, flags 3 nothing (v
572-580).

## Clip windows at write time

MAME clamps the window's x range to the screen when drawing (v 259-260). The registers hold the
clamped values: `min_x` to `0..320` (320 means nothing visible), `max_x` to `-1..319`, as 10-bit
signed; `min_y`, `max_y` to `0..1023`. The visible result is the same.

## What is knowingly not MAME

- **RAM read live during a line.** MAME draws line L whole at L's start (`VIDEO_UPDATE_SCANLINE`),
  so a VRAM, palette, clip or raster write during line L shows from L+1. The engine reads VRAM
  and the registers while rendering L (one line early) and the palette at scan-out (one line
  late). The game writes all of them in lines 9-11, which are blank in every capture; the model's
  `--pal-line`/`--vram-line` show no pixel depends on it. The CPU's timing differs anyway.
- **Frame parity.** Auto-flicker uses the frame counter's parity (v 170, 278, 310); MAME's and the
  core's counters start at different points. The bench sets the parity from the capture.
- **Overrun.** MAME never runs out of time. The engine drops the tail of the list on a line that
  does and counts it; the bench's worst line against `sprite_load_mame.txt` says how far that is.

## Budget as estimated before the bench, worst attract line (`sprite_load_mame.txt`, frame 1436 line 141)

| Stage | Work | Clocks |
|---|---|---|
| scanner | 40 blocks of 92 enabled entries | ~900, in parallel |
| rows | 269 granules at 13.4 | 3605 |
| ROM tables | 141 entries, ~36 granules | ~480 |
| pixels | 3058 writes at one a clock, overlapping the fetches | hidden under 3605 unless a row is wider than its fetch |
| setup | 40 hits x ~25, overlapping rows | hidden |
| total | | ~4100 of 5304 |

The estimate missed that the emitter's one pixel a clock over every row's width, not the writes,
is the other limit; "Measured" below has the bench's numbers.

## Measured

`sim/sprite_tb` on the five captures, a full frame each, on the real memory path (`+SDRAM=1`:
`sdram_arbiter`, `sdram_phy`, `sdram.sv` at BL8, the command-decoding chip model loaded with the
32 MB image). With MAME's zoom every frame was pixel-identical to MAME's `reference.png`; no line runs over its
5304 clocks, and the units the engine fetches per line equal the model's count on every line
(`render_model.py --rtl --stats`). With the single zoom accumulator the RTL's pens equal the
model's on every capture, and the model differs from MAME where zoom is used (`MAME_KLUDGES.md`).

| Capture | units, worst line | clocks, worst line | lines over budget |
|---|---|---|---|
| attract1500 | 55 | 1585 | 0 |
| attract2400 | 138 | 4076 (line 160) | 0 |
| attract3300 | 65 | 2071 | 0 |
| play1800 | 132 | 3283 | 0 |
| play2700 | 140 | 3312 | 0 |

On attract2400's line 160 (332 tile rows, 25 blocks): the emitter is busy 2384 clocks (one pixel
a clock over every row's width, clipped pixels included), the row stage waits 1725 clocks for
units and 831 for a place in the row queue, the scanner takes 1894 clocks for 92 candidates,
overlapped. The 16-byte unit on the vendored controller costs 17.9 clocks back to back
(`sim/sdram_cost_tb -GBL8=1`) against 13.4 for 8 bytes, and serves two tiles' rows.

The first version of this engine fetched one 8-byte granule per row and waited for each: at the
measured 13.4 clocks it ran 36 of these 1200 lines into the deadline. The unit layout, the held
unit per stream and the two slots are what closed that. The emitter's one pixel a clock is the
next limit (2384 of 3907 on the worst line); two pixels a clock through the pen RAM's second
port is the known option, not taken.

## Bench: `sim/sprite_tb`

`scripts/run_verilator.sh sprite_tb +CAPTURE=debug/avengrgs-attract2400 [+PARITY=n] [+ROMLAT=n] [+SDRAM=1]`.
Loads the capture through the CPU-side write ports (list, VRAM, palette, clip, IRQ block), runs
one frame of the real line cadence (5304 clocks a line) through `mlc_video`, writes the scan-out
to `<capture>/rtl.rgb` and `rtl_lines.txt` (per line: clocks used, units fetched, pixel writes,
overrun, and the stages' busy clocks). The engine's two slots are served by a behavioural model
(16-byte units from the region images, in request order, `ROMLAT` clocks each) or, with
`+SDRAM=1`, by the real path and the chip model loaded from `debug/<set>_sdram.bin`
(`scripts/mlc_layout.py --image`). `scripts/render_model.py <capture> --rtl --stats` compares
`rtl.rgb` with `reference.png` pixel for pixel, the line buffer's pens with the model's, and the
units per line with the model's count; `scripts/compare_line_trace.py` diffs one scanline's rows
against `+DBG=2 +TRACE=<line>`.
