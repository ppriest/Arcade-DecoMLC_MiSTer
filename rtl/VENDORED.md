# Single-file vendored modules — provenance

Copied from `Arcade-DreamWorld_MiSTer` at `233d1f2` (the files last changed there in `de225e3`),
untouched except as listed below. Each file's header names its author, upstream and licence; the sibling cores'
history is the record of their local fixes.

| File | Upstream | Licence | What |
|---|---|---|---|
| `hiscore.v` | JimmyStones/Hiscores_MiSTer (Alan Steremberg, Jim Gregory) | GPL-3.0-or-later | MAME hiscore.dat save and restore |
| `video/crt_adjust.sv` | rmonic79/Arcade-Raiden_MiSTer (Umberto Parisi), one local fix marked in the file | GPL-3.0-or-later | CRT Adjust: H-Position, V-Shift, H-Size |
| `video/crt_vsize.sv` | rmonic79 (Umberto Parisi) | GPL-3.0-or-later | CRT Adjust: V-Size |
| `video/crt_chain.sv` | the sibling cores (Psikyo, DreamWorld) | GPL-3.0-or-later | the two above in series, parameterised by line length and pixel period |
| `video/screen_rotate_two.sv` | Sorgelig, by way of srg320/Arcade-SKNS_MiSTer | GPL-2.0-or-later | HDMI rotation through the HPS framebuffer |

## Local changes

- `video/crt_chain.sv` (`2b25f70`): during the vertical blank `hb_out` is regenerated from the
  DE window measured on the last picture line. Built from DE alone it stayed high through the
  blank, and `sys/scandoubler.v` then produced no lines or VSync (`docs/LESSONS_LEARNED.md`,
  "HBlank built from DE stops the scandoubler's VSync").
