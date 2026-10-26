# Data East MLC (Avengers in Galactic Storm) — MiSTer Core Roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.** It asks for one thing outside the
skill's defaults: `clk_sys` at 84 MHz, on a measurement (Clocks).

## Context

Goal: a DE10-nano MiSTer core for the Data East MLC system, emulated by MAME's
`src/mame/dataeast/deco_mlc.cpp` with the `sh7604`, `ymz280b`, `eepromser` and, for the later
sets, `arm7` (DE156), `deco156` and `deco146` devices — a Quartus 17.0.2 SystemVerilog project
producing one `.rbf` and a `.mra` per set, reusing proven open components where they exist.

Assumptions agreed with the user: the repository is `DecoMLC`; the SDRAM module is 32 MB;
Avengers in Galactic Storm (`avengrgs`, `avengrgsj`) comes first. Hardware facts with their
sources are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md); the measurements this plan rests on are
[`write_timing_mame.txt`](write_timing_mame.txt) and [`sprite_load_mame.txt`](sprite_load_mame.txt).

What shapes this project: the two chips that matter exist as proven RTL. srg320's SH7604 runs in
the Saturn, 32X and Super Kaneko Nova System cores at 28.6 MHz and in jotego's CPS3 at 25 MHz;
srg320's YMZ280B runs in SKNS beside it. What is genuinely new:

1. **The sprite engine.** The DE150/DE223 pair has no RTL. A per-scanline engine from
   `deco_mlc_v.cpp`: blocks of up to 16x16 tiles indexed through tables in VRAM or ROM, zoom to
   4x, eight clip windows, raster offset sets, 8bpp pairing, shadow/hilight. The measured load
   (269 tile-row fetches and 3058 line-buffer pixels on one line) sets the clock.
2. **The SH-2 on this board**: the bus controller's chip-select areas, the DMAC doing the
   per-frame palette and VRAM copies, one scanline interrupt auto-vectored at level 1, and the
   ROM behind a 4 KB cache in SDRAM.
3. **Video timing**: the driver has no raw timing. The core takes Data East's standard 7 MHz,
   442 x 274 (`cninja.cpp:1039`), a recorded choice.
4. Later, **the DE156 sets**: the Amber ARM with the fetch-time descramble from the Deco156Simple
   core, 5bpp and 6bpp layouts, the DECO 146 for Stadium Hero, rotation for Skull Fang.

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already
bind decisions here are collected under "Pitfalls that already bind decisions here".

## Progress

**Phase 0 is done; Phase 1 (the software model, then the sprite engine against it) has started.**

- Vendored, each with a `PROVENANCE.md`: jotego's SH7604 with its six tests (`rtl/cpu`),
  srg320's YMZ280B, jt9346, Seta's memory path and chip model, the debug blocks (`14e7349`).
  `tools/sh-elf` builds GNU binutils for the tests' assembler.
- **Criterion 1, met.** Seta's `sdram_tb` passes on arrival (ModelSim). jt9346's upstream test
  runs to completion (it has no automated check). All six SH7604 tests pass through
  `scripts/sh7604_tests.sh` with the files byte-for-byte upstream; what the runner supplies
  around them (a jtframe-shaped tree, two modules the upstream lists omit, `-Wno-fatal`,
  `-O2`, `VL_TIME_CONTEXT`, Icarus options first) is in its header and the PROVENANCE.
- **Criterion 2, met.** `sim/boot_tb` in replay mode: the SH7604 boots `avengrgs` and matches
  MAME's trace for **191,068 writes, every I/O read in order, and every ROM and RAM read MAME
  made in that window** (64,525 distinct), through the RAM test, the first DMAC copy, the
  raster-register setup and into the first interrupt's entry: both exception pushes land at
  the same writes as MAME's. The pushed return address differs by six instructions, the RTL
  taking the interrupt at a later boundary inside a run of instructions that write nothing,
  and every later difference follows from that (registers the handler saves hold later values,
  the main loop's and the handler's input reads interleave differently, so the replayed I/O
  goes out of step). Comparing further needs the main program and the handler as separate
  streams, the Phase 1 trace tooling. On the way two things in the vendored cache were found
  and fixed (`rtl/cpu/sh7604/PROVENANCE.md`, "Local changes"): jotego's copy held the core until
  the BSC took a store and, at that clock, re-issued the same store, so every store that
  followed another went out twice (87 of 210,940 writes at zero wait, 2,789 with eight clocks
  of wait); and it cleared the pending flags when a request completed, which with posted
  writes dropped a store queued behind another (the third of a run of `mov.l rN,@-r15`
  pushes). Both lines are srg320's again; the six upstream tests still pass. The DMAC's writes
  interleave with the CPU's differently from MAME's one-shot transfer, so a window across a
  DMA with waits on the bus stops there.
- **Criterion 3, measured.** Hardware mode, 2 s from reset (boot, title, the first attract
  frames, 197 interrupts at lines 8 and 9), with the cache fixes: **2.18 CPU cycles per
  instruction with 12 clocks of ROM latency**, 6.1% of cycles waited on the bus; 2.15 at zero
  latency; 1.4% fewer instructions executed in the same time. The cache absorbs the SDRAM
  path. In the boot window before the first interrupt: 3.94. Hardware mode also showed the
  RTL taking its first interrupt about 100,000 writes before MAME: the bench holds the level
  until the acknowledge, MAME's `HOLD_LINE` is a pulse the game's mask discards. Which the board
  does is unknown; the core follows MAME (an Interrupts open item).
- **Criterion 4, measured, and it changes the plan.** `rtl/synth_check` at 84 MHz, unconstrained
  apart from the period: worst setup slack **-3.543 ns** (slow 85C), the paths from the cache's
  `IBADDR` into `MULT.MACH` and from the write-back stage into the decode registers, so the
  core's Fmax is about 65 MHz. 4,237 ALMs, 3,486 registers, 4 M10K, 3 DSP blocks. The CPU
  therefore takes the Clocks section's fallback: **its own 42 MHz output of the PLL** (CE 1 in
  2), the wrapper's req/ack registers as the seam into the 84 MHz side, constrained as related
  clocks. SKNS closes the same core at 57 MHz, consistent with this.
- **Criterion 5, measured.** `sim/sdram_cost_tb`: one granule read on the vendored controller at
  84 MHz is 12 clocks request to acknowledge (12.4 mean, 21 with a refresh), **13.4 clocks per
  read end to end** back to back, against the 11 the fetch budget assumed. The worst attract
  line's 269 pixel fetches alone are then 3,605 clocks, 68% of the line, before tables and
  index blocks: the memory plan's "bank-interleaving read path" item moves from option to
  Phase 2 work, or the sprite ROM layout goes row-major so consecutive tiles' rows burst
  together. The licence question to srg320 has not been asked.

Phase 1:

- **The software model is pixel-identical to MAME on five captures** (`scripts/render_model.py`:
  attract frames 1500, 2400, 3300 and play frames 1800, 2700, each 320 x 240 against the
  capture's `reference.png`). It draws from the list MAME copied at the previous vblank start
  (`spritebuf.bin`) and from the previous frame's palette and VRAM top for the lines before the
  game's DMA (`capture.lua` `CORE_PREV`); on these five frames the pre-DMA state changes no
  pixel, since the first lines are blank. The five lists use shadow (up to 18 entries), 8bpp
  pairs (up to 14), ROM and VRAM index blocks, ROM and VRAM tile tables, zoom from 0x40 to 0x100
  and clip windows 0-2 (all 8-247 x 0-319); none uses raster mode, auto-flicker or the upper
  clip bit. Per line the model counts at most 25 blocks, 332 tile rows and 320 written pixels.

- **The sprite engine renders the five captures pixel-identical to MAME in Verilator**
  (`rtl/video/`, `sim/sprite_tb`, `docs/phase1_video.md`): the list snapshot and candidate
  walk, the per-line scanner with the two-level index path, raster sets and clip windows, the
  drawer with zoom by reciprocal table and an 8-step divider, 8bpp pairs, shadow flags, the
  written flag in registers, the overrun counter. No multiply or divide operator. The granules
  fetched per line equal the model's count on every line that finishes.
- **The fetch budget is the limit, measured.** At zero SDRAM latency the worst captured line
  takes 3011 of 5304 clocks; at the measured 13.4 clocks a granule, 36 of the 1200 captured lines
  run into the deadline (attract2400 and play2700, lines of 265-298 granules). The frames still
  match because what was cut was off-screen or covered. Phase 2's read path has its number: the
  worst line needs about 4000 clocks of fetch at one activate per granule.

Phase 2:

- **The read path is built and measured.** 16-byte units at burst 8 on the vendored controller,
  the engine fetching through two arbiter slots with the stream's last unit held. On the real
  memory path in Verilator (`sim/sprite_tb +SDRAM=1`: arbiter, phy, `sdram.sv`, the chip model
  loaded with the 32 MB image) all five captures are pixel-identical to MAME with no line over
  budget; the worst line takes 3907 of 5304 clocks (attract2400, line 160; `docs/phase1_video.md`,
  "Measured").

- **The download is proved byte for byte.** `scripts/build_mra.py` writes the avengrgs `.mra`
  (the program's word-swapped interleave found by trial against ROM_START) and proves its image
  with `mra.py`; `sim/download_tb` streams the whole 33 MB through the ioctl interface into
  `mlc_sdram_top` and reads every unit back equal to `scripts/mlc_layout.py`'s image, the gfx1
  permutation (`mlc_dl_xform`) included.
- **The board boots in Verilator.** `rtl/mlc_core.sv` and `rtl/mlc_top.sv` on the chip model
  (`sim/core_tb`): the Data East logo and INSERT COIN at frame 59, two interrupts a frame from
  frame 23, and the bus trace equal to MAME's boot for 191,068 writes, up to the first interrupt
  entry, where the interrupt's timing against the raster parts them (as the Phase 0 bench did).
  The buttons are named for what each does in MAME (`scripts/mame/buttons.lua`).

- **Avengers runs on the DE10-nano.** The `DecoMLC_stp` build (timing met: 0.859 ns worst setup)
  boots `avengrgs` to its attract mode: the demo fight with INSERT COIN
  (`debug/hw/avengrgs_loaded.png`), two interrupts a frame (probe C: 6588 in 3318 frames), the
  program read through the DDR3 fast load and the 16-byte read path (probe R: the reset vectors
  at 8 and 12 read `0x00000200`, `0x2011FFFC`, as the image holds). Silent.
- **The board's frames equal MAME's.** Native screenshots matched against every MAME attract
  frame from 300 to 4200 (`scripts/match_frame.py`, `scripts/mame/snap_range.lua`): identical to
  frames 2242 and 2359; 3031 differs on its first line only (32 pixels), where MAME drew line 8
  from a state that exists in neither the previous nor the current frame's RAM, a mid-line write
  the core's CPU timing does not reproduce (`HACKS.md`, live reads). Two fixes came from this: the
  game's reset is released at line 0 as MAME starts it, and the frame parity for auto-flicker
  sprites starts where the board's matches showed (an effect sprite MAME draws on even frames).
- **Standard features in.** Flip screen, verified on the board through the OSD: the flipped
  screenshot equals MAME frame 2362 rotated 180 degrees (and `sim/sprite_tb +FLIP=1` on two
  captures). Hiscore on main RAM's second port, CRT Adjust, HDMI rotation sharing DDR3 with the
  loader, vertical crop, OSD masking. 429 of 553 M10K, timing met (0.461 ns). Hiscore, CRT Adjust
  and rotation are not yet checked on the board; there is no sound, so no audio mix option.
- **Inputs reach the game.** Through the remote API's raw keys and `mame_keys`: a coin gives
  CREDIT=1, Start opens the mode select, Attack (left Ctrl) picks Story mode and opens the
  character select (`debug/hw/coin_1.png`, `start_1.png`, `attack_1.png`). Pads are not tried.

Phase 3 (sound) is in progress:

- **The chip against MAME.** srg320's YMZ280B with four marked local changes
  (`rtl/sound/ymz280b/PROVENANCE.md`), replaying MAME's register writes (`sim/ymz_tb`): 0.994
  correlation against a Python port of MAME's chip (`scripts/ymz_model.py`), 0.976-0.978 against
  MAME's WAV. Through `mlc_ymz_mem` on a modelled SDRAM: 37 chip clocks held in 30 s, the same
  correlation.
- **In the board.** The chip behind 0x600000/0x600004, its samples on SDRAM port 2, the volume
  byte, the OSD's Audio Mix. `sim/core_tb +AUDIO=1`, 600 frames from reset: 572 chip writes, 3 held
  chip clocks, correlation 0.956 with MAME's WAV at one lag over 10 s, rms 887 against 882.
- **Built.** `DecoMLC_stp` at `dc6b0a8`: timing met (0.073 ns), deployed. Not yet heard on the
  board.

Phase 4 (the DE156 sets, DecoMLC156) is in progress:

- **The CPU.** The Amber a23 ARMv2a from Deco156Simple (`rtl/cpu/amber`), with MAME's DE156
  coprocessor 0 added (BCD arithmetic and a divide, used by every DE156 program) and its
  registers starting at 0 as MAME's do. The program descrambled at fetch (`rtl/cpu/de156`): all
  262144 words of stadhr96u, skullfng, hoops96 and acchi equal MAME's decrypted region. Run at
  14 MHz, MAME's 7 MHz times its clock scale. `sim/core_tb -GDE156=1` boots stadhr96u: its first
  182001 bus writes equal MAME's, where the two take an interrupt at different instructions.
- **The DECO 146** in RTL, the whole of MAME's device as the MLC wires it
  (`rtl/protection/mlc_deco146.sv`): 129965 random reads equal a port of MAME's.
- **The scanline interrupt** fires every frame at its line, as MAME `df450c1` has it.
- **Video.** Every layout (4bpp, 5bpp, 6bpp, acchi) in the engine, the download transform and the
  model. The engine draws a line at its start with the registers latched then (stadhr96 rewrites
  the raster words on every other line) and the picture is shown a line later. The model
  replays MAME's mid-frame register writes per line. RTL, model and MAME pixel-identical on
  attract frames 900 and 1800 of stadhr96u, skullfng, hoops96 and acchi (`sim/sprite_tb`; stadhr96u
  on the real SDRAM path too: worst line 4229 of 5304 clocks), and on avengrgs.
- **Sound variants.** acchi's sample ROM read unscrambled; mlc_5bpp's swapped routes summed into
  both speakers.
- **The whole board.** `sim/core_tb -GDE156=1` stadhr96u, 900 frames: frames 600 and 899
  pixel-identical to MAME frames 562 and 861. The Amber runs on the 42 MHz clock (it misses 84
  MHz by 6.4 ns), the program is stored by ARM address, and an 8 KB cache serves its reads.
  The heaviest attract lines still overrun (`HACKS.md`).
- **Built.** `DecoMLC156_stp` at `cdcb4c0`: timing met (0.236 ns), 64% of the ALMs, deployed with
  the DE156 `.mra` files in `_dev` and the four zips.
- **On the board.** Native screenshots of each parent's attract, matched against MAME frames
  300-3600 (`scripts/match_frame.py`; `debug/hw/`): stadhr96 three of three pixel-identical
  (frames 1503, 2461, 2923), skullfng three of three (1460, 1924, 2480, against MAME's ROT270
  frames turned back), hoops96 three of three (1482, 1989, 2502), acchi three of five (1511, 2015,
  2715); one acchi shot is 108 pixels off frame 2123 in a 14 x 14 corner of the animated logo,
  one was past frame 3600. Skull Fang's HDMI rotation read from the rotator's DDR3 buffer
  (0x24000000, the game paused): 720 of 720 sampled pixels equal the native frame turned 90
  degrees counter-clockwise, MAME's ROT270 orientation; a MiSTer screenshot never shows it.
- **The SDRAM controller at 126 MHz** behind queued ports (`ec0538e`): `sim/core_tb` stadhr96u, 900
  frames, no line overruns (770 before). `DecoMLC156_stp` at `ec0538e`: timing met (0.441 ns), 459
  of 553 RAM blocks. On the board, 12 of 12 attract screenshots pixel-identical to MAME frames:
  stadhr96 (1619, 2090, 2557), skullfng (1535, 2051, 2565, with Flip Screen on in the saved OSD
  settings: equal to MAME's frames turned 180 degrees), hoops96 (1539, 2038, 2536), acchi (1605,
  2103, 2600) (`debug/hw/c126_*`).
- **Sprite X zoom from one source accumulator** across a sprite's tiles, by the user's decision,
  where MAME restarts each tile (`MAME_KLUDGES.md`, "Zoom", with the per-capture differences).
  `sim/sprite_tb`: the RTL's pens equal the model's on all 14 captures, both memory paths; on
  the SDRAM path no line over budget, stadhr96u-attract440's worst 4723 of 5304 (4476 before).
  Not yet on the board.
- **Not yet:** the sound of the DE156 sets by ear; play past attract; the
  release build; the Avengers build with the 126 MHz controller.

## Game scope

| Set | Parent | Game | Rot | Config | CPU | maincpu | gfx1 | gfx2 | ymz | Total | MAME |
|---|---|---|---|---|---|---|---|---|---|---|---|
| avengrgs | - | Avengers In Galactic Storm (US/Europe 1.0) | 0 | avengrgs, 4bpp | SH7604 | 1 MB | 24 MB | 512 KB | 6 MB | 31.5 MB | imperfect gfx |
| avengrgsj | avengrgs | Avengers In Galactic Storm (Japan 1.2) | 0 | avengrgs, 4bpp | SH7604 | 1 MB | 24 MB | 512 KB | 6 MB | 31.5 MB | imperfect gfx |
| stadhr96 (+u, j, k) | - | Stadium Hero '96 | 0 | 6bpp, DECO 146 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB | imperfect gfx |
| stadhr96j2 | stadhr96 | Stadium Hero '96 (EAE) | 0 | 6bpp, DECO 146 | DE156 | 1 MB | 24 MB | 512 KB | 4 MB | 29.5 MB | not working |
| skullfng (+j, a) | - | Skull Fang | 270 | 6bpp | DE156 | 1 MB | 12 MB | 512 KB | 4 MB | 17.5 MB | not working |
| hoops96, hoops95, ddream95 | hoops96 | Hoops / Dunk Dream '95 | 0 | 5bpp | DE156 | 1 MB | 10 MB | 128 KB | 4 MB | 15.1 MB | imperfect gfx |
| acchi | - | Janken Game Acchi Muite Hoi! | 0 | acchi 5bpp | DE156 | 1 MB | 20 MB | 512 KB | 4 MB | 25.5 MB | imperfect gfx |

Loaded bytes from `-listxml` (`HARDWARE_NOTES.md`, Sets). gfx1 and ymz are byte-identical
within each family and stored once per set image.

### Scope decision

- **In scope:** all fourteen sets — one memory map, one screen, one chipset, every set within
  the 32 MB module. Two `.rbf`s from one project: `DecoMLC` for the SH-2 sets, `DecoMLC156`
  for the encrypted-ARM (DE156) sets (the user's decision, Phase 2).
- **Out of the first scope:** the twelve DE156 sets — a second CPU with its descramble, three
  more tile layouts, the DECO 146, rotation; and MAME itself marks Skull Fang not working.
- **First-target set:** `avengrgs` — the user's priority, the plain SH-2 with no protection.
- **Second target:** `avengrgsj` (same hardware, other program and index ROM), then `stadhr96u`
  as the first DE156 set (Stadium Hero is the other 24 MB game; the 146 is startup-only).

## Hardware reality (from the driver, not assumption)

Every value below is read out of the MAME driver or a device file and cites file and line
(`HARDWARE_NOTES.md` has the long form). A value from a PCB note or a trace says so.

### Chips

| Tag | Part | Clock | Role |
|---|---|---|---|
| maincpu | Hitachi SH7604 (SH-2) | 42/2 = 21 MHz (mlc 542) | main CPU, 4 KB cache, DMAC used every frame (system trace) |
| ymz | Yamaha YMZ280B | 42/3 = 14 MHz (mlc 565) | 8-channel ADPCM/PCM, stereo, no IRQ wired |
| eeprom | 93C45, 64 x 16 | bit-banged (mlc 176-196) | all configuration; factory image per set |
| DE150, DE223 | Data East customs | - | the sprite system (mlc 43-44) |
| XC3130 | Xilinx | - | bus controller (mlc 45) |
| maincpu (later) | DE156, encrypted ARM | 42/6 = 7 MHz (mlc 573) | the other twelve sets |

### Clocks

Board: one 42 MHz crystal (mlc 31). SH-2 /2, YMZ280B /3, DE156 /6. Vsync "58 Hz" (mlc 54).
The pixel clock is not in the driver (`HARDWARE_NOTES.md`, Clocks).

**Proposed: `clk_sys` 84 MHz = 12 x 7 MHz, SDRAM on the same clock (1x).** Above the 48 MHz
default, for a measured shortfall:

| At 7 MHz, 442 pixels a line | clocks a line | worst line, attract | worst line, play |
|---|---|---|---|
| 42 MHz (6 x pixel) | 2652 | 3058 line-buffer pixel writes: 115% of the line | 2459: 93% |
| 84 MHz (12 x pixel) | 5304 | 58%, 78% with four clocks of setup per row | 46%, 64% |

`sprite_load_mame.txt`: the game draws its backgrounds as 16-tile-wide blocks at half scale and
its fighters as 8bpp pairs, so one line is up to 269 tile-row fetches and 3058 written pixels.
A line-buffer writer at one pixel a clock does not fit a 42 MHz line; two pixels a clock would
need a read-modify-write pair per clock for the first-opaque-wins rule and still leave 75% of the
line used. 63 MHz (9 x pixel) fits the pixels at 77% and overruns with the per-row setup. 84 MHz
is the lowest integer multiple of 7 MHz that fits with margin, and it keeps the SDRAM at 1x.

| Clock | From 84 MHz | Exact |
|---|---|---|
| pixel 7 MHz | `ce_pix` 1 in 12 | yes |
| SH-2 21 MHz | on the 42 MHz PLL output, `CE_R`/`CE_F` each 1 in 2 (the phasing jotego's README specifies) | yes |
| YMZ280B 14 MHz | 1 in 6 | yes |
| DE156 7 MHz (later) | 1 in 12 | yes |
| SDRAM_CLK | 84 MHz, phase from the eye measurement at bring-up | - |

If the pixel clock turns out to be 42/8 = 5.25 MHz, 84 MHz still divides it (1 in 16).

**Video timing: 7 MHz, H total 442, V total 274, visible 320 x 240 at rows 8-247, 57.80 Hz** —
Data East's standard for this resolution (`cninja.cpp:1039`, `fghthist.cpp:950`, `dragngun.cpp:1102`,
all `28 MHz / 4, 442, 0, 320, 274, 8, 248`), and MAME's MLC visible rows are the same 8-247. A
choice, recorded in `HACKS.md` on first use: MAME's own 320 x 256 at 58 Hz is a placeholder. The
scanline register keeps MAME's line numbers; lines 256-273 are blanking the game cannot address.
5304 clocks a line, 1,453,296 a frame.

**The SH7604 runs on a 42 MHz output of the same PLL** (`CE_R`/`CE_F` 1 in 2), behind the
jtsh7604 wrapper's registered req/ack seam into the 84 MHz side: two clocks of one PLL at an
integer ratio, constrained as related clocks, not an asynchronous crossing. Measured (Phase 0,
`rtl/synth_check`): on an 84 MHz clock the core's worst setup slack is -3.543 ns, Fmax about
65 MHz, the paths inside the cache-to-multiplier and write-back-to-decode logic; SKNS and
Saturn close it at 57.27 MHz with a 1-in-2 enable, jotego's CPS3 at 48 MHz. Every other block
stays on 84 MHz. The seam's two directions each hold their value for a full 42 MHz cycle.

**Catch-up:** the board's SH-2 reads ROM with one wait state (WCR 0x15CD, system trace), about
95 ns; a random 8-byte SDRAM granule is about 11 clocks at 84 MHz, 131 ns, plus arbitration. The
cache hides most of it; Phase 0 measures the CPI on game code with interrupts replayed, and a
stall-repaying enable (extra `CE` pairs while a stall counter is positive) is the remedy if the
game runs slow.

### Interrupts

One source, the programmable scanline interrupt: IRQ word 5 (0x200014) arms the line, -1
disarms (mlc 237-243); the timer asserts IRL level 1 `HOLD_LINE` (mlc 198-202, 1048); any write
to word 4 (0x200010) clears it (234-236). The INTC stays at reset defaults, so the SH-2
auto-vectors to vector 64 at 0x100 (`sh7604.cpp:388-397`; 474 reads of 0x100 in 240 frames).
The game takes two a frame, at lines 8 and 9 (`write_timing_mame.txt`): the first re-arms for 9
and writes a raster word, the second writes the clip windows, reads inputs, runs the two DMAC
copies and re-arms for 8. `SR.I` is 1 in the handlers, 0 in the main loop.

The core reproduces MAME: the line register compared against the line counter in MAME's
coordinates, the ack as MAME's. `HOLD_LINE` on MAME's SH-2 is a pulse: an interrupt the mask
blocks at that instant is lost, and the game runs its first frames at mask 15 with the line
register at 248, so MAME takes its first interrupt only at write 191,069. A level held until
the acknowledge is taken 100,000 writes earlier (Phase 0 bench, hardware mode). Which the
board does is unknown; the core keeps MAME's pulse (`MAME_KLUDGES.md`), with the toggling
"vblank" read at 0x200070 and the 0xFFFFFFFF status reads.

### Memory map

`avengrgs_map` (mlc 304-325); `HARDWARE_NOTES.md` has every row. The bus decodes A[23:0]; the
SH-2's chip-select areas (VRAM and YMZ through CS1, one IRQ word through CS2) only carry the
BSC's per-area wait and width settings (BCR2 0x00BC, WCR 0x15CD).

| Address | What | Where in the core |
|---|---|---|
| 000000-0FFFFF | program ROM, 1 MB | SDRAM, CPU port |
| 100000-11FFFF | main RAM, 128 KB | BRAM |
| 200000-20007F | IRQ block: ack, line, alpha, raster sets | registers |
| 200080-2000FF | clip RAM, 8 windows x 4 | registers |
| 204000-206FFF | sprite list, 16-bit in 32-bit slots | BRAM, snapshot at vblank start |
| 280000-29FFFF | VRAM: index blocks, tile tables | BRAM, read live |
| 300000-307FFF | palette, 2048 x 16 in 32-bit slots | BRAM, read live at scan-out |
| 400000, 440000-44001F | inputs, EEPROM DO, two 0xFFFFFFFF ports | glue |
| 500000 | EEPROM CS/CLK/DI, master volume | glue, jt9346 |
| 600000-600007 | YMZ280B, byte lane 3 | YMZ280B |
| FFFFFE00-FFFFFFFF | SH7604 on-chip | inside the CPU |

### Video

One layer: sprites (`HARDWARE_NOTES.md`, Video). 384 list entries of 8 words; each names an
index block in VRAM (16 B) or gfx2 ROM (8 B) giving size (1-16 x 1-16 tiles), offsets, flips and
an 18-bit tile, directly or through a 16-bit table in ROM or a 32-bit table in VRAM. Zoom 10 bits
each way (0x100 = 1.0, to 4x), eight clip windows, three raster offset sets, 8bpp pairing,
shadow/hilight by colour range. First opaque pixel wins: entry 0 is on top (v 107, 124). Pen 0
backdrop. Palette 2048 x xBGR_555. Tiles 16x16, 4bpp as two plane pairs 12 MB apart in the
region (mlc 468-478). MAME: zoom and raster models unverified (mlc 98-102).

### Sound

YMZ280B at 14 MHz, sample ROM 6 MB with a load-time address permutation that is a wiring of
the address lines (mlc 1001-1019; `HARDWARE_NOTES.md`, Sound). Master volume byte at 0x500000.

### Protection

None on avengrgs. DE156 ROM descramble and the DECO 146 belong to Phase 4.

### Per-game configuration

The `.mra` mod byte: CPU (SH-2 / DE156), tile layout (4bpp / 5bpp / 6bpp / acchi), DECO 146
present, rotation, sound ROM unscrambled (acchi), YMZ channel swap (hoops), and the EEPROM factory
image as a ROM part. Avengers: all zero, plus its `.nv` image.

## Component reuse map

Every row's "source" is a file that was located and whose header was read.

| block | plan | source |
|---|---|---|
| SH7604 | Port jotego's copy of srg320's SH7604 with its `jtsh7604` req/ack wrapper and six Verilator tests, run unchanged on arrival; SKNS's copy as the cross-check | `E:/jtcores` at `451c630da`, `modules/jtframe/hdl/cpu/sh7604/*.sv`, `jtsh7604.sv`, `ver/cpu/sh7604_*`; `srg320/Arcade-SKNS_MiSTer rtl/SH/SH7604` (no licence file; open item) |
| YMZ280B | Port srg320's, BSD-3-Clause "derived from MAME's ymz280b", 24-bit byte memory port; add per-channel 8-byte prefetch and the address permutation in the wrapper | `srg320/Arcade-SKNS_MiSTer rtl/SKNS/YMZ280B.sv`, `YMZ280B_pkg.sv`; Cave's GPL-3 rewrite as the second reading |
| 93C46 EEPROM | jotego `jt9346` (16-bit), from the Deco156Simple core | `MiSTer-devel/Arcade-Deco156Simple_Mister rtl/jteeprom/jt9346.v` (GPL-3.0); `jt5911` in Seta as the fallback |
| sprite engine | Written from `deco_mlc_v.cpp` against a software model; the Psikyo per-scanline zoom path as the shape (buffered list, per-frame candidates, per-line engine, double line buffer) | `Arcade-Psikyo_MiSTer rtl/video/` (pattern only) |
| SDRAM controller, arbiters, download | Seta's copy of Sorgelig's `sdram.sv` (burst-4, `dq_in` fix), three fixed-priority ports | `Arcade-Seta_MiSTer rtl/memory/sdram/` |
| DDR3 fast load | Psikyo/Seta `rom_loader.sv`, `ddram_*` | `Arcade-Seta_MiSTer rtl/memory/` |
| CRT Adjust, hiscore, pause, debug | rmonic79 `crt_adjust.sv`, JimmyStones `hiscore.v`, Fuuki `pause_control.sv`, Seta `rtl/debug/` | sibling cores, per `cpus_and_vendored.md` |
| HDMI rotation (Skull Fang, Phase 4) | Sorgelig `screen_rotate_two.sv` | sibling cores |
| DE156 (Phase 4) | Amber `a23` plus `jtosman_deco156.v` fetch-time descramble | `MiSTer-devel/Arcade-Deco156Simple_Mister` (GPL-3.0) |
| DECO 146 (Phase 4) | Written from `deco146.cpp` for the startup check | `src/mame/dataeast/deco146.cpp` |

## On-chip RAM budget

M10K blocks, 1 KB each at the widths used, of 553. The framework baseline is DreamWorld's fit
(`42baf8e`): 52 for `sys/` and the scaler, 43 for CRT Adjust with v-size.

| Block | M10K |
|---|---|
| main RAM, 128 KB (CPU port; hiscore and state borrow it) | 128 |
| VRAM, 128 KB (CPU/DMAC write port, engine read port) | 128 |
| sprite list, live + snapshot, 2 x 3072 x 16 | 12 |
| palette, 2048 x 16 | 4 |
| line buffers, 2 x 320 x 15 (11 colour, 2 shadow, written, spare) | 2 |
| SH7604 cache, 4 KB + tags | ~6 |
| SDRAM download and port FIFOs | ~4 |
| hiscore | ~4 |
| framework (`sys/`, scaler) | 52 |
| CRT Adjust with v-size | 43 |
| **total** | **~383 (69%)** |

The ones to watch are the two 128 KB RAMs: the trace shows the game using both nearly in full,
and a second read port on either would replicate it (LESSONS, "Driving a dual-port RAM's second
read port"). The engine's index-block and table reads share one VRAM port; hiscore and the state
engine borrow the CPU's main-RAM port. CRT v-size is the first thing to drop if a fit says so;
main RAM into SDRAM behind the SH-2 cache is the fallback after that.

## Memory plan

SDRAM, 32 MB, on `clk_sys`. Layout (the RTL's localparams become the source of truth; the `.mra`
generator reads them):

| Region | Base | Size | Client |
|---|---|---|---|
| maincpu | 0x0000000 | 1 MB | port 1, the SH-2 (32-bit words; a 16-byte unit is one cache line) |
| gfx1 | 0x0100000 | 24 MB | port 0, sprite pixels, one 16-byte unit the same row of two tiles |
| gfx2 | 0x1900000 | 512 KB | port 0, index blocks (8 B, half a unit) and tile tables (2 B, eight a unit) |
| ymz | 0x1980000 | 6 MB | port 2, YMZ280B through sixteen held 16-byte units (`mlc_ymz_mem`) |
| end | 0x1F80000 | | 512 KB spare; stadhr96's image is 2 MB shorter |

**gfx1 is stored as 16-byte units, the same row of two consecutive tiles** (`scripts/mlc_layout.py`,
`docs/phase1_video.md` "gfx1 layout"): MAME's region keeps the two plane pairs 12 MB apart (mlc
482-492); the download path's `mlc_dl_xform` moves region byte `a` (`h = a >= 0xC00000`, `o = a -
h * 0xC00000`) to `{o[23:7], o[5:2], o[6], h, o[1:0]}`. The controller runs burst 8 (`sdram.sv`
`BL8`, `rtl/memory/PROVENANCE.md`): 17.9 clocks a unit back to back, measured, against 13.4 for an
8-byte granule, and the model counts 44-72% of the rows fetched on the captures as served by the
stream's previous unit. 6bpp rows (12 B) fit the same unit in Phase 4.

**Fetch budget per line, 5304 clocks at 84 MHz, one 8-byte granule 13.4 clocks on the vendored
controller** (measured, `sim/sdram_cost_tb`: 12 request to acknowledge, 13.4 end to end back to
back with refreshes):

| Client | Worst line (attract) | Granules | Clocks | Share |
|---|---|---|---|---|
| sprite pixels | 269 rows | 269 | 3605 | 68% |
| ROM tile tables | 141 entries, consecutive within a block | ~36 | 482 | 9% |
| ROM index blocks | 40 blocks if all in ROM | 40 | 536 | 10% |
| YMZ280B | 8 channels, at most 37 bytes a line, prefetched | ~5 | 67 | 1% |
| SH-2 | the remainder | ~45 | 614 | 12% |

At the worst line that leaves the CPU 12%; on an average line (114-169 rows) sprites take
29-43%. So Phase 2 builds the read path for throughput rather than taking the controller as
it is: either a bank-interleaving read sequence on `sdram.sv` (activate the next bank while
the current burst runs, toward 6-7 clocks a granule) or a row-major sprite ROM layout so the
rows of consecutive tiles are one longer burst, decided on the model's count of how many
fetched rows come from consecutive tiles. The CPU's 6% stall share over the first two seconds
(Phase 0 CPI) was measured at 12 clocks of ROM latency without contention.

The sprite side is pipelined: the fetch for row n+1 is issued while row n is written, so the
granule cost is throughput, not latency. The sprite port has priority; the CPU port second; the
YMZ last, its prefetch buffers sized for eight correlated streams (LESSONS, "Size a prefetch
buffer for correlated consumers"). On an average line sprites take 24-35% and the CPU has the
rest; the Phase 0 CPI measurement says whether the worst lines slow the game, and if they do the
options are a bank-interleaving read path (granule cost toward 6-7 clocks) before any clock
change. DDR3 at load time only (fast ROM loading); no DDR3 client during play.

**Snapshot and latch points** (`write_timing_mame.txt`): the sprite list is copied at vblank
start (line 248; the game's last list write of a frame is by line 150, the copy takes 3072 clocks)
and a per-frame candidate list is built from it in the blanking lines (384 entries, each needing
its index block for height, offset and scale). VRAM, the palette, the clip windows and the
raster registers are read live, as MAME reads them: the game writes them at lines 8-11 of the
visible area and MAME's per-scanline update sees them from the next line. The palette is applied
at scan-out from the line buffer's colour index, which is when MAME's per-line draw resolves it.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the hardware is
suspected to do, and what would settle it. Already known: the 0x200070 toggle, the 0xFFFFFFFF
ports, the interrupt line model, the zoom and raster models, the DE156 clock scale.

**Where a vendored module and MAME disagree, record it and keep the module.** A silicon-derived
disagreement is evidence about the chip; MAME's is evidence about MAME. It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct. First entries: the 7 MHz / 442 x 274 timing, the 16-byte 6bpp granule.

**Transcribe the reference literally first, then look for the chip.** Build MAME's version, get
pixel-exact agreement with captured references, and only then experiment — with the experiment on
an OSD switch so it is an A/B, not a rebuild.

**Two `.rbf`s, one project: `DecoMLC` (SH7604) and `DecoMLC156` (DE156, the encrypted ARM)**
(the user's decision, Phase 2). Everything but the CPU and its bus glue is shared RTL; each
revision instantiates only its own CPU, so neither carries the other's logic and timing. Each
`.mra` names its `<rbf>` (`scripts/build_mra.py`); per-set differences within a family are
mod-byte configuration. No underscore in either name: release files are
`Arcade-<rbf>_YYYYMMDD.rbf` and `check_release_mras.py` splits at the last underscore.

**Four Quartus revisions:** `DecoMLC`, `DecoMLC_stp`, `DecoMLC156`, `DecoMLC156_stp`; each
`_stp` differs from its release twin only by the `DEBUG_ISSP` macro, the 156 pair by a `CPU_DE156`
macro selecting the CPU. `DecoMLC156` is created when Phase 4 starts. See
[`WORKFLOW.md`](WORKFLOW.md).

**Licence: GPL-3.0-or-later.** jt9346, the Deco156Simple modules, the Seta memory path and the
framework are GPL; the SH7604's own licence is an open item that cannot lower it. Every
dependency, what it obliges and the release checklist are in [`THIRD-PARTY.md`](../THIRD-PARTY.md).
`sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM.** The list latched at vblank start, a
per-frame candidate list, a per-scanline engine, a double-buffered line buffer. The board had no
frame buffer: the driver renders per scanline from a vblank copy of the list (v 535-547, 566).

**Draw in list order, first opaque pixel wins, drop the tail on overrun.** `drawgfxzoomline`
writes a pixel only where none has landed (v 107, 124), so entry 0 is on top and the chip's order
is the list's. The line buffer carries a written flag; an entry that does not finish in the
line's budget is the lowest-priority one, which is what a chip with a time limit would drop. A
saturating overrun counter on the debug page, paired with lines drawn.

**No multiplies, no divides, in 2D pipelines.** MAME divides twice per sprite-line (v 62, 439);
the engine uses a 1024-entry reciprocal table for `16 << 16 / width` and steps a 16.16
accumulator, and the row select `bby * 256 / yscale` by the same table on `yscale`. Shifts,
masks, adds and accumulators elsewhere; WORKFLOW §14.

**`clk_sys` 84 MHz, SDRAM 1x, on the sprite-load measurement** (Clocks). The SH7604's domain is
decided by its Phase 0 synthesis check, not assumed.

**Main RAM and VRAM in BRAM.** The trace shows both nearly full and the game's DMAC writing 17 KB
into VRAM and the palette every frame; the SH-2 at 21 MHz with a 4 KB cache would not tolerate
them behind SDRAM. 256 blocks, 46% of the device, accepted in the RAM budget.

**The YMZ280B reads its ROM through sixteen held 16-byte units** (`rtl/sound/mlc_ymz_mem.sv`),
shared by the voices with clock replacement: a hit answers at once and fetches the unit after it,
a miss (a voice's first read after key-on) holds the chip's clock enable until its unit arrives.
On 30 s of attract writes, 37 chip clocks were held (`sim/ymz_tb +MEM=1`, `HACKS.md`).

**State is reachable from the first RTL.** Every RAM behind a borrowable port, the SH7604's
registers already a register file, a `docs/STATE.md` inventory kept as blocks land
(`savestates.md`). The state dump is built before any savestate ships.

## Pitfalls that already bind decisions here

Entries from [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) that are not general advice but already
constrain something written above. Read the entry, not the summary.

| Entry | What it binds here |
|---|---|
| "Read both halves of a mechanism: the draw loop AND the pixel op" | first opaque wins, entry 0 on top; the overrun policy drops the tail |
| "A swap is not a copy" | the sprite list is copied at vblank start, never ping-ponged |
| "[Seta] A snapshot is a race with whoever writes the thing being copied" | the copy starts at line 248 when the writer is quiet (last write by line 150) and is atomic against writes that land anyway |
| "[Seta] Latch the sprite list and the video registers at the same point unless evidence separates them" | VRAM, palette, clip and raster registers are deliberately live: the sweep and MAME's per-scanline update are the evidence, recorded in the memory plan |
| "[Seta] Estimate the worst case from the hardware's iteration, not from the frames you looked at" | the RTL carries a per-line worst counter from the first video build; the Python count is the estimate, not the measurement |
| "[Seta] A double buffer puts the renderer TWO lines ahead" and "Put a time budget just below the period" | the line engine's start and cutoff |
| "[MS32] A CPI measured on the power-on RAM test is a CPI of the RAM test" | Phase 0's CPI is measured on attract-mode game code with the interrupt replayed |
| "Choose SDRAM over DDRAM for hard real-time fetch budgets" | sprite ROM on SDRAM; DDR3 at load time only |
| "Size a prefetch buffer for correlated consumers, not average bandwidth" | the YMZ280B's eight channel buffers |
| "Driving a dual-port RAM's second read port can silently REPLICATE the whole array"; "A true dual-port RAM must be ONE always block" | main RAM and VRAM port sharing; the RAM template modules |
| "[MS32] Past about 90% of M10K, count blocks, not bits" | the budget above is in blocks |
| "Memory transport: req/valid contracts, latency, byte order" | the `jtsh7604` req/ack wrapper onto the SDRAM port; the gfx1 permutation at the seam |
| "ROM loading: .mra, byte order, deployment" | `ROM_LOAD32_WORD_SWAP` program interleave; the gfx1 and ymz permutations proved with `mra.py` before hardware |
| "[GX] A game that reads its EEPROM without writing it needs the driver's default image" | the `.nv` image is a ROM part in every `.mra` |

## Phased roadmap

**Phase 0 — Vendoring spike and the measurements. The gate.**

Vendor the SH7604 (jotego's copy, `jtsh7604` wrapper and tests), the YMZ280B, `jt9346`, the
Seta memory path and the debug blocks into `rtl/` with a `PROVENANCE.md` per directory. Run every
upstream testbench unchanged before editing anything. Stand the CPU up in `rtl/synth_check/`
with the bus wrapper and the memory transport and nothing else. Port `--coin` into
`mame_capture.py` from the DreamWorld copy for the play captures.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.** — Met: `sdram_tb` passes;
   the six SH7604 tests pass through `scripts/sh7604_tests.sh` with the test files untouched
   (what the runner supplies is in its header); jt9346's runs to completion, it has no check.
2. **The CPU boots `avengrgs` and matches MAME's bus trace**, diffed access by access (MAME's
   SH-2 fetches 16-bit halves: compare by 32-bit word; ROM reads as a superset), every peripheral
   stubbed to what MAME returns: the two 0xFFFFFFFF ports, the 0x200070 toggle, the EEPROM image.
   Through the BSC settings, the cache and the DMAC the game programs (system trace, frame 2).
   — Met: 191,068 writes, every I/O read, every ROM and RAM read, into the first interrupt's
   entry (Progress), after two restorations in the vendored cache (its PROVENANCE).
3. **Measured CPI on attract-mode game code** against 21 MHz, with the two interrupts replayed at
   lines 8 and 9, split between execution and SDRAM stall. — Met: 2.18 at 12 clocks of ROM
   latency, 2.15 at zero, 6.1% of cycles stalled, over the first two seconds (Progress).
4. **Standalone Fmax and area for the SH7604 at 84 MHz with a 1-in-4 enable**, with the
   constraint that proves it committed with the measurement. This decides the CPU's clock domain
   (Clocks). — Met: slack -3.543 ns at 84 MHz, 4,237 ALMs, 3 DSP, 4 M10K (`rtl/synth_check`);
   the CPU goes on the 42 MHz PLL output (Clocks).
5. **The granule cost of the vendored controller at 84 MHz, measured in a bench**, against the
   fetch budget table; and the SH7604's licence settled with srg320, or jotego's provenance
   note accepted as the record. — Measured: 13.4 clocks a granule, the budget table and the
   Phase 2 read-path item follow (Memory plan); the licence recorded through jotego's GPL-3 redistribution, the user's decision. — Met.

**Phase 1 — Video, against a software model.**

`scripts/render_model.py` reproducing `deco_mlc_v.cpp` from a `mame_capture.py` directory (list
snapshot, VRAM, clip, IRQ block, palette, gfx1 and gfx2 from the zip), pixel-exact on the five
captured attract frames and on play captures; then the engine in Verilator against the model:
the candidate list, the per-line walk, the two-level index path, zoom by reciprocal table, clip
windows, raster sets, 8bpp pairs, shadow/hilight, the written flag, the overrun counter. Exit
criteria: `avengrgs` renders frames pixel-identical to MAME's for the captured scenes, silent,
in simulation; the per-line worst counter agrees with `sprite_load_mame.txt` on those frames.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM backend with the three ports, the ROM download path with the gfx1 permutation, `.mra`
generation checked with `mra.py`, inputs (two sticks, four buttons, named from the manual),
the EEPROM with its factory image, the ISSP probe and the OSD debug page. The standard feature
set: Pause suspending the SH-2, CRT Adjust (and v-size if BRAM allows), hiscore, fast DDR ROM
loading, HDMI scaling and crop, HDMI rotation, audio mix, HDMI-only options hidden under direct
video, CRT Adjust parameters hidden until enabled, and flip screen from a fake DIP through one
path, worked out for the sprite engine. Exit criteria: `avengrgs` and `avengrgsj` boot, take a
coin and play on a DE10-nano, silent, with native screenshots matching MAME frames.

**Phase 3 — Sound.**

The YMZ280B with the ROM address permutation wired at the SDRAM seam, the eight prefetch
buffers, the master volume byte, stereo through the mix option. Exit criteria: register-write
traces captured from MAME reproduce correct audio, by ear and by a decoded capture against
MAME's output.

**Phase 4 — The rest of the list, and accuracy.**

The DE156 sets: the Amber ARM at 7 MHz with the fetch-time descramble, the 5bpp and 6bpp
layouts and the 16-byte granule, hoops' fifth plane rearranged by the loader, the DECO 146
startup check for Stadium Hero, rotation for Skull Fang, the channel swap for hoops. Every
clone's `.mra`. `docs/MAME_KLUDGES.md` and `docs/HACKS.md` are the deliverables that say what is
still not right and what would settle it.

**Phase 5 — The real video timing and the DE156 clock.** A decision with evidence rather than a
default: a PCB measurement of the pixel clock and line rate would replace the 442 x 274 choice,
and MAME's doubled DE156 clock (mlc 1058) is a kludge the core need not copy if Skull Fang runs
right at 7 MHz.

**Phase 6 — Savestates, state dumps and cheats.** Optional but desirable. Not before Phase 4, but
the RTL is written for it from Phase 1 (`savestates.md`): reachable RAM ports, a `docs/STATE.md`
inventory, addressable chip state. The state dump and its simulator loader are worth building
before the savestate itself, because they make hardware bugs reproducible in a bench.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces,
  VRAM and register dumps at known frames, palette dumps, register-write logs, the per-frame
  sprite-load dumps. WORKFLOW §9 applies; `-nodrc` for every SH-2 run.
- **The software model comes before the RTL.** The model is checked against MAME first; the RTL
  against the model.
- **Every vendored module is verified against MAME before it is wired to anything**, and its own
  testbench is the regression for every later change to it.
- **Layouts are verified before ROMs are involved**: every `gfx_layout` gets the "every bit of a
  tile exactly once" check; the gfx1 permutation is proved with `mra.py` against the region image.
- **`.mra` files are generated, not written**, re-read byte-for-byte against an image built from
  `ROM_START`, and gated on an XML well-formedness check before deploy.
- **Worst cases are measured in the RTL**, not modelled: saturating counters with no reset port,
  each paired with a total; the per-line worst counter compared with `sprite_load_mame.txt`.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**, `Template.*` renamed to `DecoMLC.*` and split into
the `DecoMLC_stp` and `DecoMLC` revisions; the Quartus 13 project dropped. Quartus **17.0.2**.
Conventions are in [`WORKFLOW.md`](WORKFLOW.md) and the skill's `CONVENTIONS.md`.

## Open items

**The pixel clock and line timing are a choice.** Known: 42 MHz crystal, "58 Hz", Data East's
7 MHz / 442 x 274 on its other 320 x 240 boards. Assumed: the same here. Closed by a PCB
measurement or footage with a known capture clock.

~~**The SH7604's licence.**~~ Closed: recorded as GPL-3.0-or-later through jotego's
redistribution in jtcores, by the user's decision at the end of Phase 0
(`rtl/cpu/sh7604/PROVENANCE.md`, `THIRD-PARTY.md`); a statement from srg320 would be added.

**The SH7604's clock domain.** Closed by Phase 0 exit criterion 4.

**0x44001C and 0x200070.** MAME returns constants and a toggle; the game runs on them. Closed by
the boot and system trace comparison in Phase 0; a PCB would be the only way to learn more.

**Line 9-11 ordering of the DMAC copies against the renderer.** MAME draws each line as the beam
reaches it and the DMA lands at lines 10-11; the engine draws a line ahead. Closed by the Phase 1
frame comparison on captures that straddle those lines; a one-line difference becomes a kludge
entry.

**The RAM budget is an estimate.** Closed by the first fit of the full design.

## Next steps

1. Approval of this roadmap, including 84 MHz.
2. Phase 0: vendor the SH7604 with its tests; run them; the synthesis check at 84 MHz.
3. Phase 0: the boot trace comparison; the CPI measurement; the granule-cost bench.
