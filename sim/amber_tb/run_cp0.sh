#!/bin/bash
# The coprocessor-0 test (sim/amber_tb/tb_cp0.sv). RUN FROM THE REPOSITORY ROOT.
set -euo pipefail
export PATH="${MSYS2_ROOT:-/e/msys64}/mingw64/bin:$PATH"
H=rtl/cpu
mkdir -p obj_iverilog
python sim/amber_tb/gen_cp0.py obj_iverilog
F=()
for m in a23_core a23_decode a23_execute a23_register_bank a23_fetch a23_alu a23_barrel_shift \
         a23_multiply a23_cache a23_wishbone a23_coprocessor sram_line_en sram_byte_en; do
	F+=("$H/amber/$m.v")
done
iverilog -g2012 -I "$H" -s tb_cp0 -o obj_iverilog/amber_cp0 sim/amber_tb/tb_cp0.sv "${F[@]}"
for d in 1 2 7; do vvp obj_iverilog/amber_cp0 +delay="$d" | grep -E "PASS|FAIL|result"; done
