# jteeprom (jt9346) — provenance and modifications

| Stage | What |
|---|---|
| Upstream | jotego's JTEEPROM, `jotego/jtcores modules/jteeprom`, GPL-3.0-or-later (`LICENSE`, file headers). Local checkout `E:/jtcores` at `451c630da` (2026-10-11). |
| Here | `jt9346.v` (93C46-compatible, parameterised width), `jt9346_16b8b.v` (8-bit dump wrapper), `LICENSE`, `README.md` and the upstream test `ver/top/` (Cadillacs and Dinosaurs command logs), copied **untouched**. `ver/top/run_iverilog.sh` is this core's one-line runner for the upstream `go.sh` under MSYS2's Icarus Verilog. |

The MLC's 93C45 is a 64 x 16 part (`deco_mlc.cpp:47`, `EEPROM_93C46_16BIT`): `jt9346` with
`AW=6`, `DW=16`. The factory image comes from the set's `.nv` ROM part through the dump port.

## Local changes

None.
