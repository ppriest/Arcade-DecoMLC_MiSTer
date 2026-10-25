# DecoMLC: hardware notes

The Data East MLC ("MotherLess Cassette") system, as MAME models it. Each fact cites its source.

Source: MAME `src/mame/dataeast/deco_mlc.cpp` ("mlc" below), `deco_mlc_v.cpp` ("v") and
`deco_mlc.h`, checkout `E:/mame` at `mame0289-1527-gdedb5227403`. The driver changed twice
since the `mame0289` tag (the ARM core unification `da1b03d6dc2` and the `screen_device` split
`774a180df2b`), neither touching behaviour, so MAME 0.289 (`mame.exe -version`) is the matching
binary. `-listxml`, the boot and system traces and the write sweep are from that binary, run with
`-nodrc` (the SH-2 recompiler's fastram paths bypass the Lua taps; `scripts/mame/regions.json`
`mame_args`). Everything here is MAME's model unless marked otherwise.

The user's priority is Avengers in Galactic Storm (`avengrgs`), the one SH-2 set.

## Sets

Fourteen sets, five games, one board. Bytes are loaded bytes from `-listxml`. Every set is
`MACHINE_IMPERFECT_GRAPHICS`; `stadhr96j2` and the three `skullfng` sets are also
`MACHINE_NOT_WORKING` (mlc 1074-1087).

| Set | Parent | Game | Rot | Config | CPU | maincpu | gfx1 | gfx2 | ymz | Total |
|---|---|---|---|---|---|---|---|---|---|---|
| avengrgs | - | Avengers In Galactic Storm (US/Europe 1.0) | 0 | avengrgs, 4bpp | SH7604 | 1 MB | 24 MB | 512 KB | 6 MB | 31.5 MB |
| avengrgsj | avengrgs | Avengers In Galactic Storm (Japan 1.2) | 0 | avengrgs, 4bpp | SH7604 | 1 MB | 24 MB | 512 KB | 6 MB | 31.5 MB |
| stadhr96 | - | Stadium Hero '96 (Europe, EAJ) | 0 | stadhr96, 6bpp, DECO 146 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB |
| stadhr96u | stadhr96 | Stadium Hero '96 (USA, EAH) | 0 | stadhr96 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB |
| stadhr96j | stadhr96 | Stadium Hero '96 (Japan, EAD) | 0 | stadhr96 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB |
| stadhr96j2 | stadhr96 | Stadium Hero '96 (Japan?, EAE), not working | 0 | stadhr96 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB |
| stadhr96k | stadhr96 | Stadium Hero '96 (Korea) | 0 | stadhr96 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB |
| skullfng | - | Skull Fang (Europe 1.13), not working | 270 | mlc_6bpp | DE156 | 1 MB | 12 MB | 512 KB | 4 MB | 17.5 MB |
| skullfngj | skullfng | Skull Fang - Kuhga Gaiden (Japan 1.09) | 270 | mlc_6bpp | DE156 | 1 MB | 12 MB | 512 KB | 4 MB | 17.5 MB |
| skullfnga | skullfng | Skull Fang - Kuhga Gaiden (Asia 1.13) | 270 | mlc_6bpp | DE156 | 1 MB | 12 MB | 512 KB | 4 MB | 17.5 MB |
| hoops96 | - | Hoops '96 (Europe/Asia 2.0) | 0 | mlc_5bpp | DE156 | 1 MB | 10 MB | 128 KB | 4 MB | 15.1 MB |
| hoops95 | hoops96 | Hoops (Europe/Asia 1.7) | 0 | mlc_5bpp | DE156 | 1 MB | 10 MB | 128 KB | 4 MB | 15.1 MB |
| ddream95 | hoops96 | Dunk Dream '95 (Japan 1.4) | 0 | mlc_5bpp | DE156 | 1 MB | 10 MB | 128 KB | 4 MB | 15.1 MB |
| acchi | - | Janken Game Acchi Muite Hoi! (Japan 1.3) | 0 | acchi, 5bpp | DE156 | 1 MB | 20 MB | 512 KB | 4 MB | 25.5 MB |

Region layouts: program is two 512 KB ROMs, `ROM_LOAD32_WORD_SWAP` for avengrgs (mlc 655-656),
`ROM_LOAD32_WORD` for the DE156 sets; gfx1 is `ROM_LOAD16_BYTE` pairs of 2 MB (4 MB for
stadhr96), plus for hoops a fifth plane loaded `ROM_LOAD32_WORD_SWAP` at 0x800000 that "needs
rearranging to decode" (mlc 841); gfx2 is one ROM, 128 KB at offset 0x20000 of a 512 KB
`ROMREGION_ERASEFF` region for hoops (mlc 843-844); ymz is 2 MB or 4 MB ROMs, skullfng's loaded
at 0x200000-0x5fffff of 8 MB `ROMREGION_ERASE00` (mlc 918-920). Most sets carry a 128-byte
`eeprom` region holding the factory EEPROM image (`avengrgs.nv`, mlc 681-682).

Region CRCs compared across sets: gfx1 and ymz are byte-identical within every family (avengrgs
x2, stadhr96 x5, skullfng x3, hoops x3), so each family stores them once; program and gfx2 differ
per set except skullfng's gfx2 (CRC `0d3ae757` under three names) and hoops' (CRC `9490041c`
under two). stadhr96's gfx2 has three variants across five sets.

All fourteen sets verify against the local ROMs (`mame -verifyroms`, 14 of 14 OK).

Avengers' board (mlc 639-651): SH2 QFP144 at 21 MHz (42/2); program in two 4M x 16 EPROMs
(27C4096); MCG graphics and sample ROMs are surface-mounted 16 Mbit mask ROMs; mcg-01 was dumped
in 8-bit mode because it read with fixed bits in 16-bit mode.

## CPUs and chips

The main board (DE-0444-1, mlc 17-55) holds the RAM, the two video customs, the sound and I/O;
the CPU and ROMs are on the game board (mlc 56-59). Clocks are from the one 42 MHz crystal.

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu (avengrgs) | Hitachi SH7604 (SH-2) | 42/2 = 21 MHz, "confirmed on real board" (mlc 542, 646) | main CPU | srg320's `SH7604` (`MiSTer-devel/Saturn_MiSTer`, `S32X_MiSTer`, `srg320/Arcade-SKNS_MiSTer` `rtl/SH/SH7604`); jotego's copy with tests, `jtcores/modules/jtframe/hdl/cpu/sh7604` + `jtsh7604.sv` (local checkout `E:/jtcores` at `451c630da`). See Feasibility. |
| maincpu (others) | DE156, an encrypted ARM | 42/6 = 7 MHz, "measured on pin 90" (mlc 87, 573) | main CPU | Amber `a23` ARM core as used by `MiSTer-devel/Archie_MiSTer` and `MiSTer-devel/Arcade-Deco156Simple_Mister` (GPL-3.0), whose `jtosman_deco156.v` descrambles the ROM at fetch time |
| ymz | Yamaha YMZ280B | 42/3 = 14 MHz (mlc 42, 565); output rate clock/384 = 36.458 kHz (`ymz280b.cpp:550`) | 8-channel ADPCM/PCM, DAC YAC513 | `srg320/Arcade-SKNS_MiSTer rtl/SKNS/YMZ280B.sv` (844 lines, header "BSD-3-Clause (derived from MAME's ymz280b)", 24-bit byte memory port); `MiSTer-devel/Arcade-Cave_MiSTer rtl/cave/YMZ280B.sv` (GPL-3.0, SystemVerilog rewrite of nullobject's Chisel) |
| eeprom | 93C45, "equivalent to 93C46", 128 bytes (mlc 47), 16-bit (mlc 545) | bit-banged | config, no DIP switches | jotego `jt5911`/`jt9346` (sibling cores, Deco156Simple `rtl/jteeprom`) |
| ioprot (stadhr96) | DECO 146 | - | protection, "barely used, only checked at startup" (mlc 89-90) | none known; `deco146.cpp` is 1458 lines |
| DE150, DE223 | Data East customs, "GFX" (mlc 43-44) | - | the sprite system | none: written from `deco_mlc_v.cpp` |
| XC3130 | Xilinx, "Bus Controller?" (mlc 45) | - | address decode | the core's bus glue |

MAME runs the DE156 at twice its clock, "the timing in the ARM core isn't as accurate as it
should be" (mlc 1053-1058, 1066): a MAME kludge, not a board fact.

## Clocks

| Clock | Source |
|---|---|
| 42 MHz crystal | PCB layout (mlc 31); SH-2 /2 (542), DE156 /6 (573), YMZ280B /3 (565) |
| Vsync 58 Hz | Guru's note (mlc 54); `set_refresh_hz(58)` (551) |
| Pixel clock | **unknown.** No `set_raw`: `set_size(320, 256)`, `set_visarea(0, 319, 8, 247)` (551-553) with no blanking columns, which `-listxml` turns into 4.75136 MHz (320 x 256 x 58). |

Divisions of 42 MHz that fit a 15 kHz monitor: /6 = 7 MHz (the pixel rate of Data East's
16-bit boards) and /8 = 5.25 MHz. At 58 Hz a frame is 120,690 or 90,517 pixel clocks; neither
gives an integer line count at a plausible H total, so 58 Hz is rounded or the division is
another one. Closing it needs a PCB measurement (H rate or pixel clock) or footage with a known
capture clock. The clock plan built on this is the roadmap's Clocks section: with the pixel clock
a division of 42 MHz, `clk_sys` = 42 MHz keeps every clock exact (SH-2 at /2 with alternating
`CE_R`/`CE_F` as the SKNS core runs it, YMZ at /3, ARM at /6, pixel at /6 or /8); 48 MHz would
need fractional enables for all of them and cannot divide to 7 MHz.

## Video

From `deco_mlc_v.cpp`. One layer: sprites, drawn per scanline from a list of blocks that index
tiles directly or through tables in RAM or ROM, with zoom, clipping windows, shadow/hilight and
an 8bpp pairing mode (v 4-11).

- **Screen**: 320x240 visible (rows 8-247 of 256), 58 Hz (mlc 551-553). ROT0; skullfng ROT270.
  Aspect 4:3 (3:4 for skullfng).
- **Palette**: 2048 entries, xBGR_555, 16-bit entries in the low half of 32-bit slots at
  0x300000-0x307fff (mlc 317, 559-560). Bit 15: "Not verified what palette highest bits actually
  do" (mlc 101). Pen 0 is the backdrop, "confirmed from Skull Fang level 2" (v 553). Colour base
  per bpp: 256 colours of 16 (4bpp), 128 of 32 (5bpp), 64 of 64 (6bpp) (mlc 516-530); colours
  above that range select shadow mode (v 22-28, 262-265).
- **Sprite list** ("spriteram 1"): 0x3000 bytes at 0x204000, 16-bit words in 32-bit slots (the
  upper half reads 0xffff, mlc 253-282), 384 entries of 8 words. Copied to a buffer at the rising
  edge of vblank and drawn from the buffer: "Spriteram is definitely double buffered, as the vram
  lookup tables are often updated a frame after spriteram is setup" (v 535-547).
  Entry (v 173-191): word 0 bit 15 enable, bit 14 index in ROM rather than RAM, bits 13:0 index;
  word 1 bit 15 X flip, 14 Y flip, 13 auto-flicker (skip odd frames, v 170), 12 pair with the
  next entry as 8bpp, 11 upper clip bit, 10 raster mode, 9:8 clip window (bits swapped, v 245),
  7 raster set high bit, 6:0 colour; word 2 Y (11 bits, bit 10 negative, v 213-217); word 3 X
  likewise; words 4-5 Y and X scale, 10 bits, 0x100 = 1.0.
- **Index block** ("spriteram 2", v 193-210): in VRAM, 16 bytes per block (four 32-bit words,
  low 16 bits used), 8192 blocks covering the whole 128 KB (v 305-336); or in the gfx2 ROM, 8
  bytes per block, indices 0x4000-0x7fff at ROM offsets 0x20000-0x3ffff (v 274-304). Fields:
  width and height in tiles (0 = 16), X/Y offset, flips, 18-bit tile index, auto-flicker, and
  the table mode: bits 0xc0 say the tile index addresses a table instead of a tile; bit 0x80 the
  table entry is 12-bit tile + 4-bit colour, else 16-bit tile; bits 0x3c high tile bits after
  the lookup; bits 0x03 (RAM blocks only) the table is in ROM (16-bit entries at `gfx2 + tile*2`)
  rather than VRAM (32-bit entries at `vram + (tile & 0x7fff)`) (v 474-521).
- **Drawing** (v 144-533), per scanline, in list order, the first opaque pixel winning
  (`pri[x] & 0x80`, v 107, 124): entry 0 is on top. Clip: 8 windows of 4 words (min Y, max Y,
  min X, max X) in clip RAM, window from word 1 bits 9:8 (swapped) and bit 11 (v 236-259).
  Source row: `(line - top) * 256 / yscale` (v 399-450), a divide per sprite-line; the row's
  `w` tiles each draw 16 pixels stretched to `xscale * 16 / 256` with `dx = (16 << 16) / width`
  (v 56-62), a second divide. Scale is 10 bits, so a tile row covers up to 64 pixels.
- **Raster sets** (v 223-234, 356-397): with word 1 bit 10 set, the raster select (bits 7 and
  8:9) picks one of three register triplets in the IRQ block, words 6-8, 9-11, 12-14 (Y offset,
  X offset, X zoom), added to the sprite. MAME: "avengrgs doesn't even enable this" (v 225-233).
- **8bpp** (v 163-168, 267-271, 338-353, 474-505): entry N paired with N+1 combines two 4bpp
  tiles, `c = (c1 << 4) | c2`, palette base from the preceding block's colour.
- **Shadow / hilight** (v 104-118, 568-581): colour bits above the bpp range set 2 flag bits per
  pixel instead of drawing; the final pass halves the pixel (shadow) or halves and adds 0x808080
  (hilight) when exactly one flag is set. Mode gated by IRQ word 1 bits 7:6 (v 47, 106).
- **Tiles**: 16x16. 4bpp (avengrgs): two planes from the low ROM half and two from the high
  half, a row being 32 bits in each (mlc 468-478): 64 + 64 bytes a tile, 196,608 tiles in 24 MB,
  the two halves 12 MB apart. 5bpp (hoops), 6bpp (stadhr96, skullfng), acchi's own 5bpp layout
  (mlc 480-514).
- **MAME's own list** (mlc 98-102): "blending, raster effect features aren't fully emulated";
  8bpp and shadow together unverified; palette high bits; "Zoom algorithm is incorrect/unverified"
  against PCB footage (`https://www.youtube.com/watch?v=eCwAVt0GbhQ`). These go in
  `MAME_KLUDGES.md` as they are built.

## Memory map

`avengrgs_map` (mlc 304-325); the DE156 maps are the same addresses without the mirror
(327-356), stadhr96 adding the DECO 146 at 0x70f000-0x70ffff (354).

| Address | What | Line |
|---|---|---|
| 000000-0FFFFF | program ROM, 1 MB | 306 |
| 100000-11FFFF | main RAM, 128 KB | 307 |
| 200000-20007F | IRQ block, 32 words, written through `irq_ram_w`; reads: 200000, 200004, 20007C return 0xFFFFFFFF, 200070 toggles every read ("Todo: Vblank probably in $10", 145-152), 200074 the scanline counter (169-173) | 308-313 |
| 200080-2000FF | clip RAM, 8 windows x 4 words | 314 |
| 204000-206FFF | sprite list, 16-bit in 32-bit slots | 315 |
| 280000-29FFFF | VRAM, 128 KB: index blocks and tile tables | 316 |
| 300000-307FFF | palette, 2048 x 16-bit in 32-bit slots | 317 |
| 400000 | inputs: P1 bits 0-7 (joystick, buttons 1-3, Start), P2 bits 8-15, coins 16-17 and 20-21, service 18 and 22, test 19, EEPROM DO bit 23 (active high), P1 button 4 bit 24, P2 button 4 bit 27 | 318, 359-394 |
| 440000, 440004 | P3 and P4 in bits 16-23 (the 50-pin extra-controls connector, mlc 49-51) | 319-320 |
| 440008 | reads 0xFFFFFFFF | 321, 123-126 |
| 44001C | reads 0xFFFFFFFF, writes ignored; "vbl loop ... avengrgs tests other bits too" | 322, 128-143 |
| 500000 | write: bits 8-15 EEPROM (bit 0 DI, bit 1 CLK, bit 2 CS); bits 0-7 master volume, gain (255 - data) / 255, "probably logarithmic" | 323, 176-196 |
| 600000, 600004 | YMZ280B address and data, byte lane 3 | 324 |
| FFFFFE00-FFFFFFFF | SH7604 on-chip registers (`sh7604.cpp:257-359`) | |

The SH-2 program addresses VRAM and the YMZ280B through chip-select area 1 (`0x022xxxxx`,
`0x026xxxxx`) and IRQ word 2 through area 2 (`0x04200008`), everything else through area 0
(system trace, `debug/avengrgs-sys`). MAME's SH-2 masks addresses with 0xC7FFFFFF
(`sh7604.cpp:35`), dropping the cache-through bit, and the driver's `.mirror(0xff000000)` folds
the areas onto one decode. The board's bus controller therefore decodes A[23:0] with the SH-2's
CS lines carrying only each area's wait-state and width settings.

**Bus controller settings the game writes at boot** (system trace, frame 2): BCR1 = 0x0000,
BCR2 = 0x00BC (areas 1 and 2 32-bit, area 3 16-bit), WCR = 0x15CD; cache CCR 0x00, 0x10, 0x11
(purge, then enable). DVCR written once (0x0001); FRT, SCI, WDT, UBC and the INTC registers are
not written in 240 frames.

## Interrupts

One source: the programmable scanline interrupt. Writing IRQ word 5 (0x200014) arms a timer for
that screen line, -1 disarms (mlc 237-243); the timer asserts the CPU's line `HOLD_LINE`
(198-202); any write to word 4 (0x200010) clears it (234-236). Level 1 on the SH-2 (`m_irqLevel`,
mlc 1048), the ARM IRQ line on DE156 (1059).

With the INTC at reset defaults the SH-2 auto-vectors IRL level 1 to vector 64 + 1/2 = 64
(`sh7604.cpp:388-397`), address 0x100: 474 reads of 0x100 in 240 frames, two a frame (system
trace). The game's code starts at 0x200, so the vector table is 128 entries.

What the game does with it (system trace frames 150-151; write sweep): both interrupts land at
the top of the visible area, one line apart. At line 8 the handler acknowledges, re-arms for
line 9 and writes raster word 7; at line 9 the handler acknowledges, writes the 8 clip windows,
IRQ word 2, reads the inputs, programs DMAC channel 0 for 9 KB from RAM 0x100000 to VRAM
0x29DC00-0x29FFFF and then 8 KB from RAM 0x102400 to the whole palette (SAR/DAR/TCR/CHCR
0x5E01, DMAOR 1), writes IRQ word 1 = 0xFFFFFFFF, re-arms for line 8. The main program then
writes the sprite list across lines 13-150 (attract) or 16-63 (play) and idles. Lines 248 and
249 appear only in the first frames after reset. The SR interrupt mask is 1 inside the handlers,
0 in the main loop.

MAME's TODO "avengrgs - doesn't generate enough line interrupts?" (mlc 93) and the toggling
"vblank" read (145-152) say the real relation between this counter and the display is a guess;
the frame work landing in MAME's first visible lines is part of that guess. The core follows
MAME.

## Sound

YMZ280B at 14 MHz: 8 channels of 4-bit ADPCM, 8-bit or 16-bit PCM from a 24-bit byte address
space, stereo out, no interrupt wired. The avengrgs sample ROM (3 x 2 MB) is descrambled at load
(mlc 1001-1019): `addr = bitswap<24>(x, 23,22,21, 0, 20,19,...,1)`, so the chip's address `a`
reads the dump at `x` with `x[0] = a[20]`, `x[20:1] = a[19:0]`, `x[23:21] = a[23:21]`: a wiring
of the address lines, no copy. acchi's ROMs are not scrambled (1064). hoops swaps the channels
and MAME suspects mono (608-617). Master volume is the byte at 0x500000 (189-192).

## EEPROM and configuration

93C45, 64 x 16, through 0x500000 byte 1 and input bit 23 (mlc 176-196, 385). No DIP switches:
every option is set from the test menu into the EEPROM (`PORT_SERVICE_NO_TOGGLE`, 381), and the
driver loads a factory image per set (the `eeprom` region) so the game boots configured. Flip
screen, if offered, is a fake DIP. The game writes the port about 200 times a frame (system
trace), so the EEPROM bit-banging is continuous.

## Inputs

Two 8-way joysticks, 4 buttons each, Start x2, Coin 1-4, Service 1-2, Test; P3 and P4 with 3
buttons on the extra ports (mlc 359-464). `-listxml` says 4 players; Avengers is a 2-player
fighter. Button names come from the manual in the controls phase.

## Protection

avengrgs: none, a plain SH-2 with a plain ROM. DE156 sets: the program ROM is scrambled by
address and data (`deco156.cpp`, 135 lines: a per-word address XOR cascade, 16 two-bit data XORs
by address, four 32-bit bitswaps by word index), the same transform for every DE156 game;
Deco156Simple's `jtosman_deco156.v` applies it at fetch so the raw ROM stays in SDRAM.
stadhr96: DECO 146 at startup only.

## MAME kludges in the driver

Inherited deliberately, each to be logged in `MAME_KLUDGES.md` when built: 0x200070 toggling on
every read (145-152); 0x200000, 0x200004, 0x20007C, 0x440008, 0x44001C reading 0xFFFFFFFF
(123-167); the avengrgs speedup, a read handler that idles the CPU at PC 0x3234/0x32DC
(1024-1032, 1049), not reproduced; DE156 clock x2 (1058, 1066); the zoom and raster models.

## RAM on the board, RAM the game touches

The main board carries six 32Kx8 SRAMs, 192 KB (mlc 22-23, 31-34, 48); MAME declares 128 KB main
RAM, 128 KB VRAM, 6 KB sprite list, 4 KB palette and 256 bytes of registers, 266 KB. Either the
game board carries RAM (Skull Fang's layout shows none, mlc 61-85; Avengers' is not drawn) or
MAME's sizes are generous. In 240 frames from reset (system trace) the game writes main RAM
0x100000-0x115FFF and the stack page 0x11F000-0x11FFFF (23 of 32 4 KB pages), VRAM
0x280100-0x293FFF and 0x29D000-0x29FFFF (23 of 32), the whole sprite list and palette. Both big
RAMs are effectively full size.

## Feasibility

A large board by the skill's definition: a 32-bit CPU at 21 MHz, 31.5 MB of ROM, a sprite chip
with two levels of indirection and no RTL.

**The nearest existing core is srg320's `Arcade-SKNS_MiSTer`** (Super Kaneko Nova System): the
same SH7604 at 28.6 MHz, the same YMZ280B, zooming sprites, ROM sets of comparable size, running
on the DE10-nano from a 57.27 MHz `clk_sys` with the CPU enabled every second clock and a
114.5 MHz RAM clock. The CPU and sound chip are therefore proven on this FPGA at a higher clock
than the MLC needs; jotego runs the same SH7604 at 25 MHz from 48 MHz through a fractional
enable (`jtcores/cores/cps3/cfg/mem.yaml`, `jtframe_frac_cen`). The Saturn core fits two of them
with its own video and sound.

Blocking unknowns, and what closes each:

1. **Pixel clock and line timing** (Clocks above). Unknown; MAME's 320x256 is a placeholder.
   Closed by a PCB measurement or footage with a known capture clock. Without one the core takes
   42/6 = 7 MHz, 58 Hz, and records the choice in `HACKS.md`; `clk_sys` follows it.
2. **SH7604 RTL: licence, Fmax, area.** srg320's repositories carry no licence file and the
   SH files no header; jotego's copy is under jtcores (GPL-3.0) with Verilator tests
   (`ver/cpu/sh7604_trace`, `_async_mem`, `_cache`, `_dmac_abort`, `_dmac_readback`,
   `_bsc_dbus_marker`) and a bus-timing README. Closed in Phase 0: the licence by asking, Fmax
   and area by the standalone synthesis check. The game uses the cache, the BSC and DMAC
   channel 0 (above), so those parts of the model are on the path; the FRT, SCI, WDT, DIVU and
   UBC are not.
3. **Sprite engine line budget.** MAME draws every sprite; the DE150/DE223 limit is unknown.
   Per tile per line: an index block (16 B VRAM or 8 B ROM), a table entry (2 B ROM or 4 B VRAM)
   when in table mode, then 2 x 4 B of pixels (3 x 4 B at 6bpp, 4 x 4 B at 8bpp) from SDRAM,
   stretched up to 64 pixels. 384 entries of up to 16 tiles a line. Measured
   (`sprite_load_mame.txt`, 1800 frames of attract and of play): up to 269 tile-row fetches,
   3058 line-buffer pixels, 141 ROM table entries and 40 blocks on one line. That is more than
   a 42 MHz line at one pixel a clock and sets the roadmap's clock.
4. **On-chip RAM.** Main RAM and VRAM at 128 KB each are 256 of the 553 M10K blocks, before the
   SH-2 cache, the palette, the sprite list and its snapshot, line buffers and the framework. The
   trace shows both effectively full. Closed by the Phase 0 CPI measurement: main RAM in SDRAM
   behind the SH-2 cache is the fallback if the budget does not close.
5. **Interrupt and status semantics.** 0x44001C and 0x200070 are constants and a toggle in
   MAME; the game runs on them, so the core copies them. Whether the two-interrupt cadence at
   lines 8-9 matches the board cannot be known without a PCB; the Phase 0 trace comparison
   against MAME is the criterion.
6. **Zoom.** Two divides per sprite-line in MAME, with the algorithm itself unverified (mlc
   102). Reciprocal tables (1024 entries) replace the divides; the algorithm follows MAME.

Not blocking, but shaping the design: the DMAC writes the whole palette and 9 KB of VRAM at
lines 9-11 of the visible area, after the sprite list snapshot, so both are live RAMs with a CPU
write port during display; the sprite list is written across the visible frame and must be
snapshotted at vblank start, as MAME does.

ROM: 31.5 MB for avengrgs fits a 32 MB SDRAM module once, with 0.5 MB spare; 29.5 MB for
stadhr96. DDR3 at load time only. The module size is the user's decision; it changes nothing for
Avengers but the margin.

Scope: Avengers first. The DE156 sets add the Amber ARM with the fetch-time descramble, the 5bpp
and 6bpp layouts (hoops' fifth plane needs rearranging in the loader), the DECO 146 for stadhr96,
and for skullfng a MAME that is itself `MACHINE_NOT_WORKING` ("random hangs sometimes", mlc 96).
