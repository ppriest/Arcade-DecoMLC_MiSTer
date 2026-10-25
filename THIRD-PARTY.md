# Third-party components

## Licence of this core

**GPL-3.0-or-later** (`LICENSE`). The strictest dependency sets it: the SH7604 as redistributed
in jtcores, jt9346, the memory path and debug blocks inherited from the sibling cores, and the
MiSTer framework (GPL-2.0-or-later, compatible). Nothing here is dual-licensed; a relicensing
of this core's own files could not free the vendored ones.

Every file of this core's own starts with `// SPDX-License-Identifier: GPL-3.0-or-later` and a
copyright line. Vendored files keep their upstream headers; a modified one carries a change
notice at the change (GPLv3 §5(a)) and an entry in its directory's `PROVENANCE.md`.

## Dependencies

Each directory's `PROVENANCE.md` has the exact commit and every local change.

| Component | Upstream | Licence as stated | Taken | Modified |
|---|---|---|---|---|
| SH7604 (SH-2) and `jtsh7604` wrapper, `rtl/cpu/` | srg320's model (`MiSTer-devel/Saturn_MiSTer`, `S32X_MiSTer`, `srg320/Arcade-SKNS_MiSTer`), redistributed by jotego in `jotego/jtcores` `modules/jtframe/hdl/cpu/` | srg320's files carry no licence; **recorded as GPL-3.0-or-later through jotego's redistribution in jtcores (its LICENSE)**, the user's decision at the end of Phase 0; a statement from srg320 would be added here | the core, the wrapper, the region decode, six Verilator tests, jtframe's RAM/SDRAM/C++ model files the cache test needs | two lines of `CACHE.sv` restored to srg320's (`rtl/cpu/sh7604/PROVENANCE.md`) |
| YMZ280B, `rtl/sound/ymz280b/` | `srg320/Arcade-SKNS_MiSTer rtl/SKNS/` | BSD-3-Clause, "derived from MAME's ymz280b" (file header) | `YMZ280B.sv`, `YMZ280B_pkg.sv` | no |
| jt9346 EEPROM, `rtl/jteeprom/` | `jotego/jtcores modules/jteeprom` | GPL-3.0-or-later (its LICENSE, file headers) | `jt9346.v`, `jt9346_16b8b.v`, the upstream test | no |
| SDRAM controller and memory path, `rtl/memory/` | Sorgelig's `sdram.v` through Psikyo, Fuuki and Seta (`rtl/memory/sdram/PROVENANCE.md`) | GPL-3.0-or-later | the controller, arbiter, download, bridge, loader, DDR3 PHY, the chip model and its bench | no |
| Debug blocks, `rtl/debug/` | `Arcade-Seta_MiSTer`, `Arcade-Fuuki_MiSTer` | GPL-3.0-or-later | probe, counter, tracer, pause control | no |
| hiscore, CRT Adjust, HDMI rotation: `rtl/hiscore.v`, `rtl/video/crt_*.sv`, `rtl/video/screen_rotate_two.sv` | JimmyStones/Hiscores_MiSTer; rmonic79/Arcade-Raiden_MiSTer; Sorgelig via srg320/Arcade-SKNS_MiSTer; all by way of `Arcade-DreamWorld_MiSTer` (`rtl/VENDORED.md`) | GPL-3.0-or-later; `screen_rotate_two.sv` GPL-2.0-or-later | the five files | no (rmonic79's own marked fix in `crt_adjust.sv` came with it) |
| MiSTer framework, `sys/` | `MiSTer-devel/Template_MiSTer` | GPL-2.0-or-later | as shipped | never |
| GNU binutils for `sh-elf`, `tools/sh-elf/` | gnu.org, 2.45 | GPL-3.0-or-later | built locally for the SH7604 tests; only its README is committed | no |

## Reference material that is not code

MAME (`src/mame/dataeast/deco_mlc.cpp`, `deco_mlc_v.cpp`, `deco156.cpp`, `deco146.cpp`, the
`sh/`, `ymz280b` and `eepromser` devices), BSD-3-Clause: the specification this core is
written against. `scripts/render_model.py` transcribes `deco_mlc_v.cpp`; `docs/MAME_KLUDGES.md`
lists what is copied knowingly.

## Open questions

None. The SH7604's upstream author has not stated a licence; the record above says what this
core relies on.

## Release checklist

- every `PROVENANCE.md` current, every local change listed and marked in the file
- an SPDX header on every file of ours
- `sys/` unmodified against `Template_MiSTer`
- `LICENSE` is the GPL-3.0 text; the README's licence section agrees with this file
- this table has a row for every directory under `rtl/` that is not ours
