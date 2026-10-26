#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the coprocessor-0 test for sim/amber_tb/tb_cp0.sv.

An ARM program (hand-encoded: LDR from a literal pool, MCR/MRC/CDP p0, STR, a branch to self)
puts each operand pair through BCD add, multiply, subtract and the divide, and stores c5, c3, c4
to RAM. The expected words come from Python ports of MAME's de156_cpu_device (arm7.cpp):
bcd_to_decimal, decimal_to_bcd, the c2 commands and the CDP. Writes program.hex (little-endian
words, from address 0) and expect.hex (the result block at 0x4000, in store order).
"""
import random
import sys
from pathlib import Path

M = 0xFFFFFFFF


def bcd_to_decimal(v):
    acc, mul = 0, 1
    for _ in range(8):
        acc = (acc + (v & 0xF) * mul) & M
        mul = (mul * 10) & M
        v >>= 4
    return acc


def decimal_to_bcd(v):
    acc, div = 0, 10
    for i in range(8):
        t = v % div
        v -= t
        t //= div // 10
        acc += t << (i * 4)
        div *= 10
    return acc & M


def bcd(cmd, c0, c1):
    v0, v1 = bcd_to_decimal(c0), bcd_to_decimal(c1)
    r = {0: (v0 + v1) & M, 1: (v0 * v1) & M, 3: (v0 - v1) & M}[cmd]
    return decimal_to_bcd(r)


def div(c0, c1):
    return (0xFFFFFFFF, 0xFFFFFFFF) if c1 == 0 else (c0 // c1, c0 % c1)


def to_bcd(n):
    return int(str(n), 16)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "obj_iverilog")
    out.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(156)
    pairs = [(0, 0), (1, 0), (0x99999999, 1), (0x12345678, 0x87654321), (0xFFFFFFFF, 0xFFFFFFFF),
             (0x00000005, 0x00000007), (0x80000000, 3), (0xFFFFFFFF, 1), (7, 0x80000001)]
    pairs += [(to_bcd(rnd.randrange(10**8)), to_bcd(rnd.randrange(10**8))) for _ in range(12)]
    pairs += [(rnd.getrandbits(32), rnd.getrandbits(32)) for _ in range(8)]
    pairs += [(rnd.getrandbits(32), rnd.getrandbits(12)) for _ in range(8)]

    code, pool, expect = [], [], []

    def lit(v):
        pool.append(v)
        return len(pool) - 1

    loads = []          # (code index, rd, pool index): LDR rd, [pc, #off], fixed up below
    def ldr(rd, v):
        loads.append((len(code), rd, lit(v)))
        code.append(0)

    def mcr(crn, rd): code.append(0xEE000010 | crn << 16 | rd << 12)
    def mrc(crn, rd): code.append(0xEE100010 | crn << 16 | rd << 12)
    def cdp():        code.append(0xEE000000)
    def str_(rd, off): code.append(0xE58A0000 | rd << 12 | off)   # STR rd, [r10, #off]
    def add_r10(n):   code.append(0xE28AA000 | n)                 # ADD r10, r10, #n

    ldr(10, 0x4000)
    for c0, c1 in pairs:
        ldr(0, c0); ldr(1, c1)
        mcr(0, 0); mcr(1, 1)
        for cmd in (0, 1, 3):
            ldr(2, cmd); mcr(2, 2); mrc(5, 3); str_(3, 0); add_r10(4)
            expect.append(bcd(cmd, c0, c1))
        cdp(); mrc(3, 4); mrc(4, 5); str_(4, 0); str_(5, 4); add_r10(8)
        q, r = div(c0, c1)
        expect += [q, r]
    ldr(6, 0x5A); ldr(7, 0x3FFC); code.append(0xE5876000)            # STR r6, [r7]: done
    code.append(0xEAFFFFFE)                                          # B .
    base = len(code)
    for i, rd, p in loads:
        off = (base + p) * 4 - (i * 4 + 8)
        assert 0 <= off < 4096
        code[i] = 0xE59F0000 | rd << 12 | off
    words = code + pool
    assert len(words) * 4 < 0x3FFC
    (out / "cp0_program.hex").write_text("".join(f"{w:08x}\n" for w in words))
    (out / "cp0_expect.hex").write_text("".join(f"{w:08x}\n" for w in expect))
    print(f"{len(pairs)} pairs, {len(words)} program words, {len(expect)} results")


if __name__ == "__main__":
    main()
