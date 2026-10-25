#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare one scanline's rows between render_model.py --trace-line and sim/sprite_tb +DBG=2 +TRACE.

    python scripts/compare_line_trace.py debug/avengrgs-attract2400 8 rtl_trace.txt

The RTL trace is the bench's output (the HIT/SETUP/ROW/ISSUE lines). The model's rows are
filtered to those the engine pushes: a width, and some of the row inside the screen. Rows are
grouped per hit (the RTL's JOB lines) and compared in order: tile, tile2, colour offset,
sx, width. Prints the first hit that differs, row by row.
"""
import re
import subprocess
import sys

ROW = re.compile(r'bx (\d+) tile ([0-9a-f]+) tile2 ([0-9a-f]+) coloff (\d+) sx (-?\d+) width (\d+)')


def model_hits(lines):
    hits = []
    for ln in lines:
        if ln.startswith('HIT'):
            hits.append((ln, []))
        elif ln.startswith('   ROW') and hits:
            m = ROW.search(ln)
            bx, t, t2, co, sx, w = int(m[1]), int(m[2], 16), int(m[3], 16), int(m[4]), int(m[5]), int(m[6])
            if w and sx <= 319 and sx + w > 0:
                hits[-1][1].append((bx, t, t2, co, sx, w))
    return [h for h in hits if h[1]]


def rtl_groups(lines):
    groups = []
    for ln in lines:
        if ln.startswith('   JOB'):
            groups.append([])
        elif ln.startswith('   ROW') and groups:
            m = ROW.search(ln)
            groups[-1].append((int(m[1]), int(m[2], 16), int(m[3], 16), int(m[4]), int(m[5]), int(m[6])))
    return [g for g in groups if g]


def main():
    cap, line, trace = sys.argv[1], sys.argv[2], sys.argv[3]
    mod = subprocess.run([sys.executable, 'scripts/render_model.py', cap, '--trace-line', line],
                         capture_output=True, text=True).stdout.splitlines()
    rtl = open(trace, encoding='utf-8', errors='replace').read().splitlines()
    mh, rg = model_hits(mod), rtl_groups(rtl)
    print(f'model: {len(mh)} hits with rows on screen; RTL: {len(rg)} row groups')
    for i, (h, rows) in enumerate(mh):
        g = rg[i] if i < len(rg) else []
        if rows != g:
            print('first difference at hit', i, h[:90])
            for k in range(max(len(rows), len(g))):
                a = rows[k] if k < len(rows) else None
                b = g[k] if k < len(g) else None
                print('   model', a, ' rtl', b, '' if a == b else '<--')
            return 1
    print('every row equal')
    return 0


if __name__ == '__main__':
    sys.exit(main())
