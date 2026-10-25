# Memory path — provenance

Copied from `Arcade-Seta_MiSTer` at `f4be27d` (2026-10-11), **untouched**:

| File | What |
|---|---|
| `sdram/sdram.sv`, `sdram/sdram_upstream_reference.sv`, `sdram/PROVENANCE.md` | Sorgelig's controller extended to burst-4 (Jackal → Psikyo → Fuuki → Seta); Seta's copy carries the `dq_in` capture fix. Its own provenance file is the record. |
| `sdram_phy.sv` | the `SDRAM_*` pin side |
| `sdram_arbiter.sv` | parameterised N-client hold-until-valid arbiter, one per port |
| `sdram_download.sv` | the HPS byte stream into SDRAM |
| `sdram_narrow_bridge.sv` | 16/32-bit client onto the 64-bit granule port |
| `rom_loader.sv`, `ddram_phy.sv` | fast ROM loading through DDR3 at load time |
| `../../sim/common/sdram_chip_model_wide.sv` (+ its `PROVENANCE.md`) | the command-decoding chip model the controller is tested against |
| `../../sim/sdram_tb/tb_sdram.sv` | Seta's controller bench: write a granule, read it back as a burst, every lane checked. The regression for this directory. |

`seta_sdram_top.sv` was not copied: the port map and region bases are per core
(`rtl/memory/mlc_sdram_top.sv`, from `docs/ROADMAP.md`'s memory plan).

## Local changes

**16-byte granules (`BL8`).** `sdram/sdram.sv` gained a `BL8` parameter: 1 loads burst length
8 into the mode register, captures eight lanes (`STATE_READ0` to `STATE_LAST`, the four fixed lane
captures becoming a loop) and widens `dout0/1/2` to 128 bits; 0 is the Seta behaviour, bit for
bit. `sdram_phy.sv`, `sdram_arbiter.sv` and `sdram_narrow_bridge.sv` take a `GB` parameter
(granule bytes, 8 or 16) for their data widths and the bridge's tag and word select. The sprite
engine's worst lines need the throughput (`docs/ROADMAP.md`, Phase 1 progress; `docs/phase1_video.md`,
"Measured"): a 16-byte unit holds the same row of two consecutive tiles, which the model counts as
serving 44-72% of the rows fetched on the captured frames, and the SH-2's 16-byte cache line is
one transaction. `sim/sdram_tb` and `sim/sdram_cost_tb` run at both settings (`-GBL8=0/1`).

**Refresh interval (`RFS_CYCLES`).** The 670-clock interval became a parameter (default 670, the
Seta behaviour); this core sets 655, 7.80 us at 84 MHz, where 670 is 7.98 us against the chip's
7.8125 us.
