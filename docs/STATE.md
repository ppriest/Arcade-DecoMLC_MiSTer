# DecoMLC state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| sprite list, live | `mlc_sprite_list.live` | 16 x 3072 | 6144 | yes (CPU port) |
| sprite list, snapshot | `mlc_sprite_list.lane[0-7].mem` | 8 x (16 x 384) | 6144 | yes, or re-copy at the restore vblank |
| candidate list | `mlc_sprite_list.cand_mem` | 10 x 384 | 480 | no: rebuilt from the snapshot each vblank |
| VRAM | `mlc_vram.lane[0-3].mem` | 4 x (32 x 8192) | 131072 | yes (CPU port) |
| palette | `mlc_video.pal` | 16 x 2048 | 4096 | yes (CPU port) |
| line buffers | `mlc_line_buffer.pen`, `wr_a/b`, `fl_a/b` | 11 x 1024 + 2 x 320 x 3 | 1408 + 240 | no: per line |
| hit FIFO | `mlc_sprite_engine.u_fifo` | 128 x 16 | 256 | no: per line |
| main RAM | `mlc_core.ram` | 32 x 32768 | 131072 | yes (CPU port) |
| IRQ block, clip RAM as read back | `mlc_core.irq_ram`, `clip_ram` | 2 x (32 x 32) | 256 | yes |
| EEPROM | `mlc_core.u_eeprom` (jt9346) | 16 x 64 | 128 | yes: the dump port, and MiSTer's NVRAM save |
| YMZ280B registers and voice state | `mlc_core.u_ymz`: its `YMZ_REG_RAM` and `YMZ_CH_RAM` instances, `MEMADDR`, `ENC`, `FLG`, the enables | 8 voices | ~200 | yes, tier 2: no state port yet |
| SH7604 | `rtl/cpu/sh7604` | registers, the 4 KB cache, the DMAC | yes, tier 2: no state port yet (`PROVENANCE.md`) |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| clip windows | `mlc_video.clip_*` | 4 x 80 | yes | `m_clip_ram` |
| raster sets, alpha | `mlc_video.ras_*`, `alpha_on` | 96 + 1 | yes | `m_irq_ram` words 1, 6-14 |
| frame parity | `mlc_video.parity` (input) | 1 | yes | `screen.frame_number() & 1` |
| line register, armed, interrupt pending | `mlc_core.line_reg`, `line_armed`, `irq_pending` | 32 + 2 | yes | `m_irq_ram[5]`, the raster timer, the IRQ line |
| 0x200070 toggle, EEPROM port, volume | `mlc_core.vbl_toggle`, `ee_port`, `volume` | 1 + 8 + 8 | yes | `m_vbl_i`, the 93C45's lines, the volume byte |
| video counters | `mlc_video_timing.hpos/vpos/div` | 22 | restore point: line 248 | `screen` |
| engine FSMs | `mlc_sprite_scan`, `mlc_sprite_draw` | — | no: idle at the restore point | — |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| DE150/DE223 sprite system | `rtl/video/` | RAMs through the CPU ports; registers written through `reg_we` | 1 | all per-frame state is in the RAMs and registers above |
| YMZ280B | `rtl/sound/ymz280b` (srg320's) | registers and voice state in small RAMs inside the module; nothing reaches them from outside | 2 | the bus sequencer `mlc_core.y_*` is idle between CPU accesses |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| candidate list, line buffers, hit FIFO, held gfx2 granules | rebuilt from the snapshot and VRAM every vblank or line |
| `mlc_ymz_mem`'s held sample units | a cache of the ROM: dropped on restore, refetched on the next read |

## Frame alignment

Restore point: the start of line 248 (`vbl_start`), before the list copy, so the snapshot and
candidate list are rebuilt from the restored live list. The line buffer's bank bit need not be
saved: both banks are empty at that point.
