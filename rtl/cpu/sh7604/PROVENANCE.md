# SH7604 — provenance and modifications

## Chain of custody

| Stage | What |
|---|---|
| Upstream | srg320's SH7604 (SH-2) model: `rtl/SH/SH7604/*.sv` and `rtl/SH/core/*.sv` in `MiSTer-devel/Saturn_MiSTer`, `MiSTer-devel/S32X_MiSTer` and `srg320/Arcade-SKNS_MiSTer`. None of those repositories carries a LICENSE file and the files have no licence header. **Recorded as GPL-3.0-or-later through jotego's redistribution in jtcores**, by the user's decision at the end of Phase 0; if srg320 states a licence, it is added here. |
| Then | jotego vendored it into jtframe, `modules/jtframe/hdl/cpu/sh7604/`, as "SH7604 files" (`7049923cb`, 2026-03-14), for the CPS3 core, under jtcores' GPL-3.0, and added `jtsh7604.sv` (a req/ack wrapper), `SH_core_trace.sv` (a committed-instruction trace for benches), six Verilator tests and `README.md` (bus timing notes). |
| Here | Copied from the local jtcores checkout `E:/jtcores` at `451c630da` (2026-10-11), **untouched**: every `.sv` in this directory, `README.md`, `../jtsh7604.sv`, `../jtsh7604_cps3_region.v` (the CPS3 region decode the wrapper instantiates; jotego's test runners do not list it, so they only build where Verilator can find it beside the wrapper), and `tests/` (the six `modules/jtframe/ver/cpu/sh7604_*` directories without their generated `.bin`, `.o` and `obj_dir/`). |

`upstream_srg320/` holds srg320's own copy for diffing: `srg320/Arcade-SKNS_MiSTer` at
`001965f1` (2026-09-18), `rtl/SH/SH7604/*.sv` plus `rtl/SH/core/*.sv`. It is newer than the
base jotego imported, so a diff against it mixes srg320's later edits with jotego's; it is not
compiled (`scripts/run_sim.sh` and `files.qip` leave it out).

## What jotego changed, from `diff -w` against `upstream_srg320/`

Lines that differ ignoring whitespace (the raw diff is dominated by reformatting):

| File | Lines | What |
|---|---|---|
| `SH7604.sv` | 110 | `BUS_STB` and `BUS_DBUS_RD` outputs (a bus-beat marker for the wrapper); CPS3 decryption inputs passed to the cache; the debug block (`USED_ADDR`, `HOOK`, `DBG_CNT`) removed; bus strobes forced idle for cache-data-area accesses (`README.md`, "Cache Data Area Bus Suppression") |
| `CACHE.sv` | 359 | CPS3 opcode decryption in the cache fill path; Saturn behaviours restored after an earlier edit (`0529e8703` read purge, `8632cb8f0` data mirror) |
| `BSC.sv` | 116 | the bus-beat marker; `e4a3ca622` "restore Saturn SDRAM RCD shortcut"; `cae01852a` decode read flags |
| `DMAC.sv` | 204 | abort and readback behaviour covered by `tests/sh7604_dmac_abort` and `_readback` |
| `SH_core.sv`, `SH_pkg.sv`, `SH_regfile.sv`, `SH_mem.sv`, `SH7604_mem.sv` | 227, 451, 61, 125, 163 | the trace taps for `SH_core_trace.sv`; `5c96ce2b4` "restore Saturn illegal NOP decode"; memory array templates |
| `MULT.sv` | 4 | |
| `DIVU`, `FRT`, `INTC`, `MSBY`, `SCI`, `UBC`, `WDT`, `SH7604_pkg` | 0 | identical |

`git -C E:/jtcores log -- modules/jtframe/hdl/cpu/sh7604` is the record of each change.

## Local changes

**`CACHE.sv`, `CBUS_BUSY`: srg320's expression restored** (one term removed, marked at the
line). Jotego's copy adds `(IBUS_WRITE && !IO_AREA)` to the core's busy, so a store holds the
core until the BSC has taken the write. At the cache clock where it does (`!IBUS_WAIT`, the
cache drops `IBREQ`), the core's request for the same store is still up, so the write branch
takes it for a new one, sets `IBUS_WRITE_PEND`, and re-issues it one cache clock later: on the
avengrgs boot every store that followed another store without a gap went out on the bus
twice, 87 of 210,940 writes with zero-wait memory and 2,789 with eight clocks of wait
(`scripts/compare_boot_trace.py dups`; the sequence in `sim/boot_tb` with `+WATCH=187677`).
srg320's cache posts the write: the core moves on once the cache has it, the request drops
before the external cycle ends, and the pending path serves only a genuinely new store. That is
how the Saturn, 32X and SKNS cores run it. The jtsh7604 wrapper latches the BSC's address and
data on `BUS_STB`, so posting loses nothing on this core's bus.

**`CACHE.sv`, the `!IBUS_WAIT` completion block: srg320's form restored** (two lines removed,
marked at the block). Jotego's copy clears `IBUS_WRITE_PEND` and `IBUS_READ_PEND` when the
in-flight request completes. With posted writes a second store can be pending at that clock;
clearing its flag drops it before it is issued and `CBUS_BUSY` tells the core it is done. On
the avengrgs boot a run of `mov.l rN,@-r15` pushes lost its third store (write 190,831). In
jotego's scheme no write could pend behind another, so the clears were harmless there.
Both changes together make the cache's request path srg320's again; the CPS3 decryption hooks
and the bus-beat marker, jotego's additions this core also uses, are untouched.

## Tests

**Result on arrival: all six pass** through `scripts/sh7604_tests.sh` (Verilator 5.050, Icarus
13.0, binutils 2.45 for `sh-elf-as`): `sh7604_trace` (2358 cycles), `sh7604_async_mem`
(349,191 cycles), `sh7604_cache` (10,873 cycles, 29 cache requests), `sh7604_bsc_dbus_marker`,
`sh7604_dmac_abort`, `sh7604_dmac_readback`. The test files are byte-for-byte upstream; what the
runner supplies around them is listed in its header (the jtframe-shaped tree of junctions, two
modules copied beside the Verilator tests, `-Wno-fatal`, `-O2`, `VL_TIME_CONTEXT`, Icarus
options before file names). `tests/jtframe/` holds the jtframe RAM, SDRAM and C++ SDRAM-model
files the cache test needs, copied unchanged from the same checkout.

`tests/*/sim.sh` are the upstream runners, unchanged: they assemble each test program with
`sh-elf-as` (built under `tools/sh-elf`, see its README), build the bench with Verilator and run
it. They expect `JTFRAME` to point at a jtframe tree; `scripts/sh7604_tests.sh` runs them against
this directory. As shipped at `451c630da` they do not build, in jotego's tree either: the wrapper
instantiates `jtsh7604_cps3_region`, which their file lists omit (the tests predate it), and the
wrapper's `cps3_region` pins are left unconnected. The runner copies the region module beside each
test, which is where Verilator looks; nothing else is changed. Results are recorded in
`docs/ROADMAP.md`, Phase 0.

## How it is used here

`jtsh7604` with `UBC_DISABLE`, `SCI_DISABLE`, `WDT_DISABLE` set and `cps3_crypt_mode = 3'b010`
(no decryption). The clock-enable phasing is the one `README.md` specifies: `ce_r` one clock in
four, `ce_f` two clocks later (21 MHz from `clk_sys` 84 MHz). The game programs the BSC, the cache
and DMAC channel 0 (`docs/HARDWARE_NOTES.md`, "Bus controller settings"); the FRT, SCI, WDT, DIVU
and UBC are not used by Avengers.
