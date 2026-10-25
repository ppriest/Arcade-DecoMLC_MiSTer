# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| Video timing 442 x 274 at 7 MHz, 57.80 Hz | `rtl/video/mlc_video_timing.sv` | The driver has no raw timing (`set_refresh_hz(58)`, 320 x 256, mlc 565-567); Data East's standard from `cninja.cpp:1039` is used | A PCB measurement of the MLC's sync | unverified; MAME's 58 Hz is itself a guess | visible (the refresh rate) |
| VRAM, the clip windows and the raster set are read while a line is drawn; the palette at scan-out | `rtl/video/mlc_sprite_scan.sv`, `mlc_video.sv` | MAME draws line L whole at L's start (`VIDEO_UPDATE_SCANLINE`), so a write during line L shows from L+1; the engine renders L one line early and looks the palette up one line late | Nothing: the per-line architecture; a write mid-line would need the CPU's timing to be MAME's too | the game writes them in lines 9-11, blank in every capture (`render_model.py --pal-line 8 --vram-line 8` changes no pixel); on the board attract frame 3031 differs from MAME on line 8 only, 32 pixels, a state MAME saw mid-line (`debug/hw/par_2.png`) | visible (one line, rare) |
| Sync pulse positions | `rtl/video/mlc_video_timing.sv:63-64` | hs at pixels 360-391, vs at lines 256-258: chosen, not measured | Phase 2's framework integration sets them from the scaler's needs | � | tooling |
| The YMZ280B's clock enable is held while a sample read misses its held units | `rtl/sound/mlc_ymz_mem.sv` (`stall`) | the chip reads at a fixed point of its cycle; a read the held units cannot answer (a voice's first after key-on) waits for SDRAM, so the chip's timing slips | nothing practical: the chip's own cycle has no wait | `sim/ymz_tb +MEM=1`: 37 chip clocks lost in 30 s, output 94.7% identical to the direct-ROM run and tracking MAME's model equally (0.9935) | latent |
| Narrower than 16-bit stores to the sprite list and the palette are not supported | `rtl/mlc_core.sv` (`list_we`, `pal_we`) | both RAMs are 16 bits wide with one write enable; the boot trace has only 32-bit stores to either (ffffffff masks) | byte lanes on both RAMs | `sim/core_tb` prints a message if one happens; none in 60 frames | latent |
| Button names without a cited source | `scripts/build_mra.py` BUTTONS | Light Punch, Heavy Punch, Light Kick, Heavy Kick are the project owner's correction of names taken from MAME by observation; the source is not recorded here. Observed alone in MAME, button 1 attacked, 2 jumped, 3 dashed, 4 threw the shield (`debug/buttons/`) | the source cited: the operator's manual or the cabinet's labels | unverified in this repository | visible (the OSD's names) |
| SDRAM_CLK phase estimated | `rtl/pll/pll_0002.v` (5952 ps = 180 degrees at 84 MHz, the Psikyo/Fuuki setting at 85.9 MHz; avengrgs runs with it, `debug/hw/avengrgs_loaded.png`; 270 degrees was never tried with the ROM present) | the MiSTer convention, not swept on this board | a sweep with `scripts/sdram_check.py`-style read-back once the core runs | unverified | latent |
| The volume byte's gain (255 - v) / 255 is taken as (g + g[7]) / 256 | `rtl/mlc_core.sv` (`vol_g9`) | no divide; g * 256/255 rounded to an integer of 0-256 | a 16-bit reciprocal constant: g * 257 >> 16 | at most 1 LSB of 256 off: exact at g = 0 and 255; the game's 0x7f gives 129/256 against 128/255, 0.4% high | latent |
| A YMZ280B access holds the SH-2 for about 0.3 us | `rtl/mlc_core.sv` (`B_YMZ`) | the chip loses a strobe edge on its enable clock, so the glue waits for an enable, then holds the strobe two chip clocks and releases it two more; MAME's write is instant | the chip's bus timing from its datasheet, if the CPU's timing is ever made the board's | unverified against the board | latent |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
