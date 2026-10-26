#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The DECO 146's read table for rtl/protection/mlc_deco146.sv, from MAME's deco146.cpp port_table.

    python scripts/gen_deco146.py            # write rtl/protection/mlc_deco146_table.hex
    python scripts/gen_deco146.py --check    # and check the packed table against MAME's form

One 32-bit word per read address (address >> 1, 1024 entries):
    [6:0]   RAM word (write_offset >> 1)
    [8:7]   source: 0 RAM, 1 port A, 2 port B, 3 port C
    [28:9]  input nibble j (j = 0..3) at [9+5j +: 5]: {valid, rotate[1:0], dest[1:0]}:
            input nibble j, rotated left by rotate, ORed into output nibble dest
    [29]    use_xor     [30] use_nand
The check expands every packed entry back into MAME's 16 weights and compares them, and runs
MAME's reorder() and the packed form over random data for every entry.

Also importable: Deco146 is a Python port of deco_146_base_device's protection port as the MLC
wires it (no address scramble, the magic read xor on, chip select 0 always), the reference for
sim/deco146_tb.
"""
import random
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import setting   # noqa: E402

DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/dataeast/deco_mlc.cpp")
SRC = DRIVER.parent / "deco146.cpp"
HDR = DRIVER.parent / "deco146.h"
OUT = REPO / "rtl" / "protection" / "mlc_deco146_table.hex"
BLK = 0xFF
PORTS = {"INPUT_PORT_A": 1, "INPUT_PORT_B": 2, "INPUT_PORT_C": 3}


def macros():
    m = {}
    for name, body in re.findall(r"#define\s+(NIB\w+|BLANK_)\s+(.+)", HDR.read_text()):
        m[name] = [BLK if v.strip() == "BLK" else int(v, 16) for v in body.split(",")]
    return m


def table():
    mac = macros()
    text = SRC.read_text()
    body = text[text.index("port_table[] = {"):]
    body = body[:body.index("};")]
    rows = []
    for m in re.finditer(r"\{\s*(\w+)\s*,\s*\{\s*([^}]*)\}\s*,\s*(\d)\s*,\s*(\d)\s*\}", body):
        loc, maps, xr, nd = m.groups()
        weights = sum((mac[x.strip()] for x in maps.split(",") if x.strip()), [])
        assert len(weights) == 16
        rows.append((PORTS.get(loc, 0), 0 if loc in PORTS else int(loc, 16), weights, int(xr), int(nd)))
    assert len(rows) == 1024, len(rows)
    return rows


def pack(src, loc, weights, xr, nd):
    w = (loc >> 1) | src << 7 | xr << 29 | nd << 30
    assert loc % 2 == 0 and loc < 0x100
    for j in range(4):
        q = weights[4 * j:4 * j + 4]
        if all(x == BLK for x in q):
            continue
        dest = q[0] >> 2
        rot = (q[0] - 4 * dest) & 3          # input bit 0 lands at rot within the nibble
        assert q == [4 * dest + ((k + rot) & 3) for k in range(4)], (q, dest, rot)
        w |= (0x10 | rot << 2 | dest) << (9 + 5 * j)
    return w


def unpack_reorder(w, data):
    out = 0
    for j in range(4):
        f = (w >> (9 + 5 * j)) & 0x1F
        if not f & 0x10:
            continue
        rot, dest = (f >> 2) & 3, f & 3
        n = (data >> (4 * j)) & 0xF
        n = ((n << rot) | (n >> (4 - rot))) & 0xF
        out |= n << (4 * dest)
    return out


def reorder(data, weights):
    out = 0
    for i in range(16):
        if data >> i & 1 and weights[i] != BLK:
            out |= 1 << weights[i]
    return out


class Deco146:
    """deco_146_base_device as deco_mlc.cpp wires it: offsets 0-0x7fe, chip select 0, the magic
    read xor 0x44a, ports A-C unbound (0xffff)."""
    def __init__(self, rows):
        self.rows = rows
        self.ram = [[0xFFFF] * 0x80 for _ in range(2)]
        self.bank = 0
        self.nand = 0
        self.xor = 0
        self.latchaddr, self.latchdata, self.latchflag = 0xFFFF, 0, 0

    def write(self, a, data, mask):
        a &= 0x7FF
        self.latchaddr, self.latchdata, self.latchflag = a, data, 1
        comb = lambda old: (old & ~mask | data & mask) & 0xFFFF   # noqa: E731
        if a & 0xFF == 0x2C:
            self.xor = comb(self.xor)
        elif a & 0xFF == 0x36:
            self.nand = comb(self.nand)
        r = self.ram[self.bank]
        r[(a & 0xFF) >> 1] = comb(r[(a & 0xFF) >> 1])

    def read(self, a):
        a &= 0x7FF
        if a == self.latchaddr and self.latchflag:
            self.latchflag = 0
            return self.latchdata
        self.latchflag = 0
        a ^= 0x44A
        src, loc, weights, xr, nd = self.rows[a >> 1]
        d = 0xFFFF if src else self.ram[self.bank][loc >> 1]
        r = reorder(d, weights)
        if xr:
            r ^= self.xor
        if nd:
            r &= ~self.nand & 0xFFFF
        if not src and loc == 0x78:
            self.bank ^= 1
        return r


def main():
    rows = table()
    words = [pack(*r) for r in rows]
    OUT.write_text("".join(f"{w:08x}\n" for w in words))
    print(f"{OUT.relative_to(REPO)}: {len(words)} entries from {SRC}")
    if "--check" in sys.argv:
        rnd = random.Random(146)
        for i, (r, w) in enumerate(zip(rows, words)):
            for _ in range(64):
                d = rnd.getrandbits(16)
                assert reorder(d, r[2]) == unpack_reorder(w, d), (i, hex(d))
            assert reorder(0xFFFF, r[2]) == unpack_reorder(w, 0xFFFF)
        print("check: every packed entry reorders as MAME's weights do (64 random words each)")


if __name__ == "__main__":
    main()
