#!/bin/bash
# Deco156Simple's Amber regression (sim/amber_tb/upstream, unchanged) on rtl/cpu/amber.
# Icarus Verilog from MSYS2. RUN FROM THE REPOSITORY ROOT.
set -euo pipefail
export PATH="${MSYS2_ROOT:-/e/msys64}/mingw64/bin:$PATH"
H=rtl/cpu
OUT=obj_iverilog/amber_upstream
mkdir -p obj_iverilog
F=()
for m in a23_core a23_decode a23_execute a23_register_bank a23_fetch a23_alu a23_barrel_shift \
         a23_multiply a23_cache a23_wishbone a23_coprocessor sram_line_en sram_byte_en; do
	F+=("$H/amber/$m.v")
done
iverilog -g2012 -I "$H" -s test -o "$OUT" sim/amber_tb/upstream/test.v "${F[@]}"
cd sim/amber_tb/upstream
for d in 1 2 5 8 13; do vvp "../../../$OUT" +delay="$d" | grep -E "PASS|FAIL|fatal|Timeout"; done
for d in 1 5 13; do vvp "../../../$OUT" +delay="$d" +rom=swap.hex +words=25 +writes=4 | grep -E "PASS|FAIL|fatal|Timeout"; done
