#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check rtl/cpu/de156/jtosman_deco156.v against MAME's decrypted DE156 program, every word.

    python scripts/de156_decrypt_check.py stadhr96u [zip parent]

Builds the raw maincpu region from the zips (scripts/build_mra.py's loader) into
debug/<set>_maincpu.bin, takes MAME's decrypted region from debug/<set>_maincpu_dec.bin
(scripts/mame/romdump.lua), and runs sim/de156_tb on Icarus Verilog: for each ARM word address a
the module's address into the raw ROM and its decrypted word must equal MAME's word at a. Both
files hold little-endian 32-bit words, as MAME's region does for the ARM.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import build_mra as bm             # noqa: E402
import extract_romstart as ers     # noqa: E402


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    setname = sys.argv[1]
    parent = sys.argv[2] if len(sys.argv) > 2 else None
    text = Path(ers.SRC).read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    recs, unknown = ers.region_records(body, "maincpu")
    assert not unknown, unknown
    zips = []
    for n in [setname] + ([parent] if parent else []):
        for d in [REPO / "roms"] + bm.ROMDIRS:
            if (d / f"{n}.zip").exists():
                zips.append(d / f"{n}.zip")
                break
    import zipfile
    raw = bm.load_region([zipfile.ZipFile(z) for z in zips], recs, bm.region_size(body, "maincpu"))
    out = REPO / "debug" / f"{setname}_maincpu.bin"
    out.write_bytes(raw)
    dec = REPO / "debug" / f"{setname}_maincpu_dec.bin"
    assert dec.exists(), f"{dec} missing: run MAME with scripts/mame/romdump.lua"
    obj = REPO / "obj_iverilog"
    obj.mkdir(exist_ok=True)
    subprocess.run(["iverilog", "-g2012", "-o", str(obj / "de156_tb"),
                    "sim/de156_tb/tb_de156.sv", "rtl/cpu/de156/jtosman_deco156.v"], cwd=REPO, check=True)
    r = subprocess.run(["vvp", str(obj / "de156_tb"), f"+RAW={out.as_posix()}", f"+DEC={dec.as_posix()}"],
                       cwd=REPO, capture_output=True, text=True)
    print(r.stdout.strip())
    sys.exit(0 if "PASS" in r.stdout else 1)


if __name__ == "__main__":
    main()
