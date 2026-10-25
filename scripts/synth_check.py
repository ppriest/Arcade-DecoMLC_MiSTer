#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile rtl/synth_check/ (the standalone SH7604 timing harness) and print its slack.

    python scripts/synth_check.py            # full flow, then the worst paths
    python scripts/synth_check.py --report   # reports only, from the last compile

A Quartus run, so it takes the hwlock rule: it refuses to start while a JTAG tool holds
or waits for the Blaster (docs/WORKFLOW.md, section 2). It compiles in place inside
rtl/synth_check/ (db/, incremental_db/, output_files/ are git-ignored), not in build/:
the harness is its own project with its own top level.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import quartus_bin  # noqa: E402
from hwlock import require_no_jtag  # noqa: E402

PROJ = REPO / "rtl" / "synth_check"
REV = "decomlc_synth_check"


def run(cmd):
    print("+", " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(PROJ), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (PROJ / "compile.log").open("a", encoding="utf-8").write(r.stdout)
    if r.returncode:
        print(r.stdout[-3000:])
        sys.exit(f"{cmd[0]} failed ({r.returncode})")


def report():
    summ = PROJ / "output_files" / f"{REV}.sta.summary"
    fit = PROJ / "output_files" / f"{REV}.fit.summary"
    for f in (fit, summ):
        if f.exists():
            print(f"--- {f.name}")
            print(f.read_text(encoding="utf-8", errors="replace"))
    rpt = PROJ / "output_files" / f"{REV}.sta.rpt"
    if rpt.exists():
        txt = rpt.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"; Slow 1100mV 85C Model Fmax Summary.*?\n(.*?)\n\n", txt, re.S)
        if m:
            print("--- Fmax Summary (slow 85C)")
            print(m.group(1))
    worst = PROJ / "worst_summary.rpt"
    if worst.exists():
        print("--- worst 30 setup paths (worst_summary.rpt)")
        print(worst.read_text(encoding="utf-8", errors="replace")[:6000])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    if not a.report:
        require_no_jtag("the synth_check compile")
        q = Path(quartus_bin())
        (PROJ / "compile.log").write_text("", encoding="utf-8")
        run([str(q / "quartus_sh"), "--flow", "compile", REV])
        run([str(q / "quartus_sta"), "-t", "worst.tcl"])
    report()


if __name__ == "__main__":
    main()
