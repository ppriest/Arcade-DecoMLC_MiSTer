# Amber a23 (ARMv2a) — provenance and modifications

| Stage | What |
|---|---|
| Original | Conor Santifort's Amber 2 core, OpenCores (`http://www.opencores.org/project,amber`). LGPL-2.1-or-later (file headers). |
| Taken from | `MiSTer-devel/Arcade-Deco156Simple_Mister` at `884705a813c1`, `rtl/osman/amber/`. That copy carries patches by Umberto Parisi (its README, "Thanks"); they are not separated from the OpenCores original here. It runs Osman and the other simpl156 games, a DE156 board, at 7 MHz. |
| Here | Every `.v` of that directory, then the local changes below, marked in the files. |

The include paths are `amber/<file>`: the search path is `rtl/cpu`.

## Upstream test

`sim/amber_tb/upstream/` is Deco156Simple's `tests/amber/` as shipped: a 50-word instruction
program and a SWP program on a Wishbone target with response latencies 1-13, the CPU at one enable
in eight. `sim/amber_tb/run_upstream.sh` runs it on this copy with Icarus Verilog. On arrival: all
eight runs pass (five latencies of the instruction program and warm reset, three of SWP).

## Local changes

1. **The DE156's coprocessor 0** (`a23_decode.v`, `a23_coprocessor.v`, `a23_core.v`). Every MLC
   DE156 program divides through it (MCR c0, c1; CDP; MRC c3, c4) and uses its BCD commands
   (MCR c2, MRC c5); counted in the decrypted programs of stadhr96u, skullfng, hoops96 and acchi
   (`scripts/mame/romdump.lua`). MAME's `de156_cpu_device` (`arm7.cpp`) is the model: sixteen
   registers; c2 = 0, 1, 3 gives BCD add, multiply, subtract of c0 and c1 into c5; CDP gives c3 =
   c0 / c1, c4 = c0 % c1, 0xffffffff when c1 is 0. Amber treated CDP as undefined and took
   register transfers only for its own coprocessor 15 (cache control). Now: transfers and CDP to
   coprocessor 0 execute, every other coprocessor instruction is undefined as on MAME's ARM2, and
   coprocessor 15 is unreachable (the cache stays off). The operations run sequentially, up to
   about 80 clocks; `o_copro_busy` must hold `i_system_rdy` low until they finish.
   `sim/amber_tb/run_cp0.sh`: 37 operand pairs through all four operations, 185 results equal to
   Python ports of MAME's routines, at three bus latencies; the upstream regression still passes.
2. **Registers start at 0** (`a23_register_bank.v`). Amber started and reset them at
   0xdeadbeef. MAME's ARM zeroes them when the CPU starts and leaves them at reset (`arm7.cpp`),
   and stadhr96 stores r2 and r3 before writing them: the first write of the boot trace that
   differed from MAME's (write 113385, `scripts/compare_boot_trace.py`, `sim/core_tb -GDE156=1`).
