#!/bin/bash
# The DECO 146 against MAME's model. RUN FROM THE REPOSITORY ROOT.
set -euo pipefail
export PATH="${MSYS2_ROOT:-/e/msys64}/mingw64/bin:$PATH"
mkdir -p obj_iverilog
python scripts/gen_deco146.py --check
python sim/deco146_tb/gen_ops.py "${1:-200000}"
iverilog -g2012 -s tb_deco146 -o obj_iverilog/deco146_tb sim/deco146_tb/tb_deco146.sv rtl/protection/mlc_deco146.sv
vvp obj_iverilog/deco146_tb | grep -E "PASS|FAIL|op "
