# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/dataeast/deco_mlc.cpp` (mlc) and `deco_mlc_v.cpp` (v) unless
named. MAME commit: `mame0289-1527-gdedb5227403`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Every set is `MACHINE_IMPERFECT_GRAPHICS`; `stadhr96j2` and the Skull Fang sets are
`MACHINE_NOT_WORKING`.

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Clip window select | v 243-251: "this mapping seems odd, but is correct for Skull Fang and StadHr96": bits 9:8 swapped, bit 11 as the third bit, "where is the high bit?" | copies, `mlc_sprite_scan.sv` (clipper) | A set that uses more than four windows |
| Raster sets | v 358-397: "I think we need some hardware tests"; bit 10 enables, bits 8:7 pick IRQ words 6, 9 or 12 as y offset, x offset, x scale; "avengrgs doesn't even enable this" | copies, `mlc_sprite_scan.sv`, `mlc_sprite_draw.sv` (xs = xscale * extra) | stadhr96's rasters on hardware |
| Alpha word | v 47, 100-101: IRQ word 1 bits 7:6 "0xc0: Shadow, 0: Alpha or Pre-shadowed, other bits unknown"; a shadow-coloured sprite only marks pixels when they are set | copies: `alpha_on`, `mlc_video.sv`; shadow by colour bits 8:7 (v 263), only bit 7 reachable at 4bpp | — |
| 8bpp pairs | v 163-166, 267-271, 337-351: the entry after one with 0x1000 supplies the second block and the first supplies the colour; "TODO: 8bpp and shadow can use simultaneously?" | copies, `mlc_sprite_list.sv` (pairing), `mlc_sprite_draw.sv` | — |
| Pen index past the palette | v 95, 132: `16 * color + c` with an 8bpp `c` can exceed 2047; MAME reads past its 2048 pens | differs: the index keeps 11 bits (`lb_pen`); `render_model.py` raises on it so a capture that does it is noticed | A capture that does it |
| Tile code wrap | v 96: `code % elements()`, 196,608 tiles | copies by one subtraction (`code_w`); `render_model.py` counts them | — |
| Zoom | v 56-62, 399-450: 16.16 steps, `dx = (16 << 16) / width`, the source row from `(bby << 16) / (yscale << 8)` | copies exactly: a reciprocal table and an 8-step divider (`docs/phase1_video.md`) | A PCB capture of a zoomed sprite |
| List double buffer | v 540-545: "Spriteram is definitely double buffered"; copied at vblank start | copies, `mlc_sprite_list.sv` | — |
| Auto-flicker parity | v 170, 278, 310: `frame_number() & 1` | copies with the core's own frame counter; the phase differs from MAME's | — |
| Pen 0 fill | v 553: "Pen 0 fill colour confirmed from Skull Fang level 2" | copies, `mlc_video.sv` | — |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| YMZ280B (`rtl/sound/ymz280b`) | linear interpolation between a voice's samples with 9 bits of phase (`ymz280b.cpp:450`) | 6 bits (`PHASE_FRAC[8:3]`) | a few units a sample; the module is derived from MAME, not silicon, so this is precision, not evidence | a recording of the chip |
