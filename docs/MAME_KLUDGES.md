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
| Zoom | v 56-62, 399-450: 16.16 steps; each tile restarts its source at `floor(xbase + bx * xinc)` with its own `dx = (16 << 16) / width`, so tiles of one sprite land on different steps and the sprite's width is not the scaled width. The source row from `(bby << 16) / (yscale << 8)` | rows copied (8-step divider). Columns not copied: one source accumulator across the sprite's tiles, `step = ceil(2^32 / xs)`, destination `floor(xbase) + k` sampling source `k * step` (mamedev/mame#16417's step, with its start at `floor` rather than `ceil`, which matches MAME's columns on avengrgs' half-size text). Model against MAME, pixels differing per 76800: avengrgs attract 1500/2400/3300 0/55/0, play 1800/2700 776/7442; hoops96 900/1800 0/2366; acchi 0/65; skullfng 372/1006; stadhr96u 900/1800 8204/12014. `render_model.py --zoom mame` gives MAME's (`docs/phase1_video.md`) | A PCB capture of a zoomed sprite |
| List double buffer | v 540-545: "Spriteram is definitely double buffered"; copied at vblank start | copies, `mlc_sprite_list.sv` | — |
| Auto-flicker parity | v 170, 278, 310: `frame_number() & 1` | copies with the core's own frame counter; the phase differs from MAME's | — |
| Pen 0 fill | v 553: "Pen 0 fill colour confirmed from Skull Fang level 2" | copies, `mlc_video.sv` | — |

## The DE156 sets (DecoMLC156)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| CPU clock doubled | mlc 1072, 1080: `set_clock_scale(2.0)` on the DE156 at 7 MHz, "avoids hangs"; the 7 MHz itself "measured on pin 90" | copies: the Amber at 14 MHz, 1 in 6 of 84 MHz (`rtl/cpu/mlc_de156.sv`). The Amber's cycle counts are not MAME's ARM's, so equal clocks are not equal speed | the game's speed against a PCB at 7 MHz |
| The DE156's coprocessor 0 | `arm7.cpp` de156_cpu_device: BCD add, multiply, subtract and a divide, "exact behavior of the actual DE156 is unknown"; a divide by 0 gives 0xffffffff, "unverified" | copies, `rtl/cpu/amber/a23_coprocessor.v` | a decap or a test program on the board |
| No address exception, LDR PC rounding up | `arm7.cpp` de156_cpu_device: `m_address_exception = false`, `m_ldr_pc_round_up = true` | not copied: the Amber raises no address exception for the MLC's addresses; an LDR of an unaligned PC is not checked | a trace that reaches either |
| Registers at power-on | `arm7.cpp`: all zero | copies (`rtl/cpu/amber/PROVENANCE.md`, change 2) | - |
| DECO 146 | `deco146.cpp`: a table from a Super Shanghai chip's analysis; the MLC's magic read xor 0x44a | copies, `rtl/protection/mlc_deco146.sv`; `sim/deco146_tb` against a port of MAME's device | - |

## The scanline interrupt (both builds)

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Fires every frame | `df450c1` (the `skullfng` branch of `E:/mame`, Paul Priest): the timer is re-armed for the same line when it fires, so the line register is compared every frame until rewritten; before it, the interrupt was one-shot | copies, `rtl/mlc_core.sv` (`line_armed` stays set). avengrgs' frame 599 and 10 s of sound in `sim/core_tb` are byte-identical either way | the board |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| YMZ280B (`rtl/sound/ymz280b`) | linear interpolation between a voice's samples with 9 bits of phase (`ymz280b.cpp:450`) | 6 bits (`PHASE_FRAC[8:3]`) | a few units a sample; the module is derived from MAME, not silicon, so this is precision, not evidence | a recording of the chip |
