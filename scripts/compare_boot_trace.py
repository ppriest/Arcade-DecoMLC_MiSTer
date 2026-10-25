#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff the RTL CPU's boot against MAME's. Phase 0.

    python scripts/compare_boot_trace.py replay  <set>   # MAME's I/O reads -> replay file
    python scripts/compare_boot_trace.py compare <set>   # RTL trace vs MAME trace

Inputs: debug/<set>-boot/<set>_boot.trace (scripts/mame_boot_trace.py) and
<set>_rtl.trace, written by the boot bench in the same "seq rw addr mask data"
format: bus-aligned address, byte-lane mask. ROM and work-RAM ranges come from
regions.json "trace" "rom"/"ram"; everything else is I/O and is replayed.
Written for a 32-bit bus; merge_halves() handles a CPU that splits accesses in two.

WHAT IS COMPARED, AND WHAT IS NOT

  * WRITES, strictly, in order: address, lanes, and data under the mask. This
    is the strong check. A CPU that executes the same program correctly makes
    the same writes with the same data in the same order, whatever it does
    with the bus in between.
  * NON-ROM READS, in order: these are the replayed I/O reads. A mismatch means
    the RTL asked a peripheral a different question from MAME's CPU.
  * ROM FETCHES, as a superset only. A prefetching CPU core and MAME's do
    not, so two correct CPUs read the same words in different orders and the
    RTL reads words MAME never asks for (LESSONS_LEARNED, "[Seta] Two cores
    that both boot correctly still fetch different words, so compare as a
    subsequence with duplicates collapsed"). What is checked is that every ROM
    word MAME read inside the RTL's window, the RTL also read.

The RTL trace is shorter than MAME's by design; it is compared up to the
number of writes it reached.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import regions  # noqa: E402

# regions.json "trace": "rom" and "ram" are lists of [lo, hi] hex strings, inclusive.
_T = regions().get("trace", {})
ROM = [(int(lo, 16), int(hi, 16)) for lo, hi in _T.get("rom", [])]
RAM = [(int(lo, 16), int(hi, 16)) for lo, hi in _T.get("ram", [])]
# "internal": CPU-internal registers MAME's tap sees (an SH-2's on-chip map) and the external
# bus never does; dropped from both traces. "vectors": a read there marks an interrupt taken.
INTERNAL = [(int(lo, 16), int(hi, 16)) for lo, hi in _T.get("internal", [])]
VEC = tuple(int(v, 16) for v in _T.get("vectors", ["0", "0"]))
# "irq_pushes": writes the CPU's exception entry makes before it reads the vector (an SH-2
# pushes SR and PC: 2), so the bench raises the interrupt before them, not after.
IRQ_PUSHES = int(_T.get("irq_pushes", 0))


def load(path):
    rows = []
    for ln in open(path, encoding="utf8"):
        if ln.startswith("#") or not ln.strip():
            continue
        f = ln.split()
        if len(f) != 5:
            continue   # a truncated or padded line (a run cut short); the rest is still valid
        seq, rw, a, m, d = f
        m = int(m, 16)
        a = int(a, 16)
        if any(lo <= a <= hi for lo, hi in INTERNAL):
            continue
        rows.append((int(seq), rw, a, m, int(d, 16) & m))
    return rows


def merge_halves(rows):
    """Join two consecutive accesses to the same dword into one.

    A CPU narrower than the bus splits a wide access in two, and MAME's tap may
    report one side split and the other whole (on KonamiGX: instruction fetches
    split, data accesses whole). Unmerged, the traces fall one entry out of step
    at every such access, which also skews the write-count comparison window.
    Both sides are normalised the same way: an adjacent pair with the same
    direction, the same aligned address and disjoint lanes becomes one access.
    """
    out = []
    for r in rows:
        if out:
            s0, rw0, a0, m0, d0 = out[-1]
            _, rw1, a1, m1, d1 = r
            # reads only: a CPU writes a halfword pair as two accesses on both sides, and
            # the RTL's pair sits adjacent when the fetches between them hit its cache
            if rw0 == rw1 == "r" and a0 == a1 and not (m0 & m1):
                out[-1] = (s0, rw0, a0, m0 | m1, d0 | d1)
                continue
        out.append(r)
    return out


def is_rom(a):
    return any(lo <= a <= hi for lo, hi in ROM)


def is_ram(a):
    return any(lo <= a <= hi for lo, hi in RAM)


def cmd_replay(game):
    """MAME's I/O reads, in order, and the write count at which each interrupt was taken
    (a read of the vector table), so the bench raises its interrupt where MAME took it
    (LESSONS, "[Silkroad] Raise a boot bench's interrupt where MAME took it")."""
    mame = REPO / "debug" / f"{game}-boot" / f"{game}_boot.trace"
    out = REPO / "debug" / f"{game}-boot" / f"{game}_replay.txt"
    irq = REPO / "debug" / f"{game}-boot" / f"{game}_irq.txt"
    n = ni = writes = 0
    with open(out, "w", encoding="utf8") as f, open(irq, "w", encoding="utf8") as g:
        for seq, rw, a, m, d in load(mame):
            if rw == "w":
                writes += 1
            elif VEC[1] > VEC[0] and VEC[0] <= a <= VEC[1]:
                g.write(f"{writes - IRQ_PUSHES}\n")
                ni += 1
            elif not is_rom(a) and not is_ram(a):
                f.write(f"{a:06X} {m:08X} {d:08X}\n")
                n += 1
    print(f"{n} I/O reads -> {out}; {ni} interrupts -> {irq}")
    return 0


def cmd_compare(game):
    base = REPO / "debug" / f"{game}-boot"
    raw_mame = load(base / f"{game}_boot.trace")
    raw_rtl = load(base / f"{game}_rtl.trace")
    if not raw_rtl:
        sys.exit("the RTL trace is empty -- did the bench run?")
    mame = merge_halves(raw_mame)
    rtl = merge_halves(raw_rtl)
    print(f"merged split halves: MAME {len(raw_mame)} -> {len(mame)} accesses, "
          f"RTL {len(raw_rtl)} -> {len(rtl)}")

    mw = [(a, m, d) for _, rw, a, m, d in mame if rw == "w"]
    rw_ = [(a, m, d) for _, rw, a, m, d in rtl if rw == "w"]
    rc = 0

    # --- writes, strictly in order
    n = len(rw_)
    first = next((i for i in range(min(n, len(mw))) if rw_[i] != mw[i]), None)
    if first is None and n <= len(mw):
        print(f"WRITES    {n} of {n} match MAME in address, lanes, data and order")
    else:
        rc = 1
        if first is None:
            print(f"WRITES    the RTL made {n} writes, MAME only {len(mw)} in its trace")
        else:
            print(f"WRITES    MISMATCH at write {first + 1} of {n}:")
            for i in range(max(0, first - 3), min(first + 4, n, len(mw))):
                flag = "  <--" if i == first else ""
                a1, m1, d1 = mw[i]
                a2, m2, d2 = rw_[i]
                print(f"    #{i + 1:<6} MAME {a1:06X} {m1:08X} {d1:08X}   "
                      f"RTL {a2:06X} {m2:08X} {d2:08X}{flag}")

    # How far into MAME's trace does the RTL's progress reach? Up to the
    # MAME access that made the RTL's last write.
    wseen = 0
    mame_cut = len(mame)
    for i, (_, rw, *_rest) in enumerate(mame):
        if rw == "w":
            wseen += 1
            if wseen == n:
                mame_cut = i + 1
                break
    window = mame[:mame_cut]

    # --- I/O reads, in order (not RAM: a CPU with a data cache reads RAM when it
    # misses, MAME's reads it every time; RAM reads are covered below, like ROM)
    mio = [(a, m, d) for _, rw, a, m, d in window if rw == "r" and not is_rom(a) and not is_ram(a)]
    rio = [(a, m, d) for _, rw, a, m, d in rtl if rw == "r" and not is_rom(a) and not is_ram(a)]
    k = min(len(mio), len(rio))
    bad = next((i for i in range(k) if mio[i] != rio[i]), None)
    if bad is None and len(mio) == len(rio):
        print(f"I/O READS {len(rio)} of {len(rio)} match MAME in order")
    else:
        rc = 1
        print(f"I/O READS MAME {len(mio)}, RTL {len(rio)}; first difference at "
              f"{bad + 1 if bad is not None else k + 1}")

    # --- ROM fetches, superset
    mrom = {(a, m) for _, rw, a, m, d in window if rw == "r" and (is_rom(a) or is_ram(a))}
    # Coverage is per BYTE LANE, not per (address, mask) pair: the RTL may have
    # read a whole dword where MAME read one half, or two halves where MAME
    # read the dword, and either way the lanes MAME asked for were read.
    rlanes = {}
    for _, rw, a, m, d in rtl:
        if rw == "r" and (is_rom(a) or is_ram(a)):
            rlanes[a] = rlanes.get(a, 0) | m
    def covered(a, m):
        return (m & ~rlanes.get(a, 0)) == 0
    missing = [x for x in mrom if not covered(*x)]
    if missing:
        rc = 1
        missing.sort()
        print(f"ROM/RAM   {len(mrom) - len(missing)} of {len(mrom)} MAME ROM and RAM reads were also "
              f"made by the RTL; first missing: {missing[0][0]:06X} {missing[0][1]:08X}")
    else:
        print(f"ROM/RAM   every one of MAME's {len(mrom)} distinct ROM and RAM reads in the window "
              f"was also made by the RTL")

    print(f"\nwindow: RTL {len(rtl)} accesses, MAME {mame_cut} accesses to the same "
          f"write ({n} writes)")
    return rc


def cmd_dups(game):
    """Writes the RTL made twice in a row (same address, lanes and data), and what came
    before each pair: a census for a CPU that re-issues a bus beat."""
    rows = load(REPO / "debug" / f"{game}-boot" / f"{game}_rtl.trace")
    writes = sum(1 for r in rows if r[1] == "w")
    dups = 0
    before = {}
    for i in range(1, len(rows)):
        _, rw, a, m, d = rows[i]
        _, rw0, a0, m0, d0 = rows[i - 1]
        if rw == "w" and rw0 == "w" and (a, m, d) == (a0, m0, d0):
            dups += 1
            prev = rows[i - 2][1] if i >= 2 else "-"
            k = "ram" if is_ram(a) else "rom" if is_rom(a) else "io"
            key = f"{k} write after a {'write' if prev == 'w' else 'read'}"
            before[key] = before.get(key, 0) + 1
    print(f"{writes} writes, {dups} of them an immediate repeat of the previous write")
    for k, n in sorted(before.items()):
        print(f"  {n:7d}  {k}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["replay", "compare", "dups"])
    ap.add_argument("game")
    a = ap.parse_args()
    return {"replay": cmd_replay, "compare": cmd_compare, "dups": cmd_dups}[a.cmd](a.game)


if __name__ == "__main__":
    sys.exit(main())
