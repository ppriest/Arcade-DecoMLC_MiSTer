#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Random DECO 146 operations and MAME's answers (scripts/gen_deco146.py Deco146) for tb_deco146.

    python sim/deco146_tb/gen_ops.py [n] -> obj_iverilog/deco146_ops.hex
One line per operation: {kind[3:0], addr[11:0], be[1:0] in 15:14 of the mask word...}, see tb.
Format: hex words "K AAA DDDD M EEEE": kind 0 read / 1 write, address, data, byte mask, expected.
"""
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import gen_deco146 as g   # noqa: E402


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
    rows = g.table()
    m = g.Deco146(rows)
    rnd = random.Random(1146)
    # read addresses whose entry is the bank word, after the magic xor
    bank_reads = [(i << 1) ^ 0x44A for i, r in enumerate(rows) if r[0] == 0 and r[1] == 0x78]
    out = []
    last_w = 0
    for _ in range(n):
        k = rnd.random()
        if k < 0.35:
            a = rnd.choice([0x2C, 0x36, rnd.randrange(0, 0x800, 2), rnd.randrange(0, 0x800, 2) | 0x100])
            d = rnd.getrandbits(16)
            mask = rnd.choice([0xFFFF, 0xFFFF, 0xFF00, 0x00FF])
            m.write(a, d, mask)
            last_w = a
            out.append(f"1 {a:03x} {d:04x} {mask:04x} 0000")
        else:
            a = rnd.choice([last_w, rnd.choice(bank_reads), rnd.randrange(0, 0x800, 2), rnd.randrange(0, 0x800, 2)])
            e = m.read(a)
            out.append(f"0 {a:03x} 0000 0000 {e:04x}")
    (REPO / "obj_iverilog").mkdir(exist_ok=True)
    (REPO / "obj_iverilog" / "deco146_ops.txt").write_text("\n".join(out) + "\n")
    print(f"{n} operations, {sum(1 for o in out if o[0] == '0')} reads")


if __name__ == "__main__":
    main()
