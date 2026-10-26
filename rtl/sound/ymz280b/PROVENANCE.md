# YMZ280B — provenance and modifications

| Stage | What |
|---|---|
| Upstream | srg320's `YMZ280B.sv` and `YMZ280B_pkg.sv`, `srg320/Arcade-SKNS_MiSTer rtl/SKNS/`, at `001965f1` (2026-09-18). Header: `//license:BSD-3-Clause (derived from MAME's ymz280b)`. Runs in that core beside the same SH7604 at 14.3 MHz. |
| Here | Copied, then four local changes, each marked in the file (Local changes, below). |

No testbench ships upstream. Verification is against MAME register-write traces in Phase 3
(`docs/ROADMAP.md`), and by ear on the board.

## Interface

8-bit register port (`A`, `DI`, `DO`, `RD_N`, `WR_N`, `CS_N`), 24-bit byte memory port (`MA`,
`MDI`, `MOE_N`), 16-bit stereo out, `CE` for the chip clock (14 MHz here, 1 in 6 of 84 MHz),
`SND_EN` per-channel enables for debugging. `rtl/sound/mlc_ymz_mem.sv` (not in this directory)
puts sixteen held 16-byte units between `MA`/`MDI` and the SDRAM port and permutes the address
lines as `deco_mlc.cpp`'s `descramble_sound` does (`docs/HARDWARE_NOTES.md`, Sound).

## Local changes

Found against `scripts/ymz_model.py`, a Python port of MAME's `ymz280b.cpp` that matches MAME's
own WAV output (correlation 0.997, equal rms, `sim/ymz_tb` notes), replaying avengrgs's register
writes from MAME (`scripts/mame/ymzlog.lua`). Before them the chip's output correlated with
MAME's at 0.04 and ran several times louder; after, 0.994 against the model and 0.976 to 0.978
against MAME's resampled WAV, at equal loudness. Each is marked in the file.

1. **`YMZ280B.sv`, key-on: one step before the start.** A phase overflow advances the position
   and then decodes, so from `{ST,0}` the first sample decoded was the one after the start and
   every voice ran one nibble (or PCM sample) ahead of MAME, whose `generate_*` read the position
   and then advance. Key-on now loads the start minus one step (1, 2 or 4 by mode).
2. **`YMZ280B_pkg.sv` `ADPCMSignalCalc`: MAME's rounding.** `(step * diff) / 8` truncates toward
   zero in MAME (`ymz280b.cpp:184`); the arithmetic shift rounded a negative product down and
   decoding the first avengrgs sample drifted from MAME's by -7084 after 30,000 nibbles.
3. **`YMZ280B_pkg.sv` `Interpolate`, `VolCalc`: the samples sign-extended by hand.** Each
   multiplied a signed sample by an unsigned operand (the phase; `{1'b0,LEVEL}`), so the multiply
   was unsigned and negative samples were zero-extended. Casting both operands with `$signed`
   still gave wrong products in Verilator 5.050; sign-extending the sample to the product's width
   and multiplying unsigned is unambiguous in every tool.

4. **`YMZ280B.sv` `YMZ_CH_RAM`: the registered-read model in synthesis.** The altdpram branch
   read the MLAB combinationally and the ADPCM state RAM's path into `OP4.WD` missed 84 MHz by
   0.9 ns (`DecoMLC_stp` build of `6692151`); placed in M10K instead, the block's output delay
   missed it by the same (`764be6c`), so the RAMs are registers (`ramstyle "logic"`, 8 words each).
   The module's own simulation model registers the read; every reader samples `Q` on a chip enable, several clocks after its address settles, so
   the two give the same results at the 1-in-6 enable, and the bench results above are this
   model's.

**Writes on a chip-enable clock are lost (not changed, worked around).** `REG_WR` is set on the
clock the bus write's edge is seen and cleared on the chip's cycle enable, the clear written
last; a write whose edge falls on that clock is dropped, about one in 36. The core's glue
starts every write on the clock after a chip enable (`rtl/mlc_core.sv`; `sim/ymz_tb`). Seen as
avengrgs's first key-on at 4.537 s never taking.

**What remains different from MAME.** The chip interpolates between samples with 6 bits of phase
(`PHASE_FRAC[8:3]`), MAME with 9; the residual after the fixes above is that, a few units a
sample (`docs/MAME_KLUDGES.md`, vendored modules).
