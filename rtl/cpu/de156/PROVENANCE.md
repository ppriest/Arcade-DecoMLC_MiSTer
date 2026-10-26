# DE156 program descramble — provenance and modifications

| Stage | What |
|---|---|
| Upstream | `jtosman_deco156.v`, Andrea Bogazzi, `MiSTer-devel/Arcade-Deco156Simple_Mister` at `884705a813c1`, `rtl/osman/`. GPL-3.0 (JTCORES header; the repository's LICENSE). A port of MAME's `deco156_m.cpp` decrypt. |
| Here | Copied untouched. |

Combinational: for an ARM word address `a` it gives the word address to read from the raw ROM
and the decrypted word. The MLC program is 1 MB, 256K words, so all 18 address bits are used
(Osman's 512 KB used 17).
