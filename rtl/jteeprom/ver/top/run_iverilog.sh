#!/bin/bash
# Upstream go.sh (jotego/jtcores modules/jteeprom/ver/top) run with MSYS2's iverilog:
# the same sources, parameters and command file; only `sim` becomes `vvp sim.vvp`.
cd "$(dirname "$0")"
TEST=${1:-dinosave.bin}
CMDCNT=$(wc -l "$TEST" | cut -f1 -d" ")
# options first: MinGW iverilog stops parsing options at the first file name
iverilog -o sim.vvp -DSIMULATION -DJT9346_SIMULATION -Ptest.CMDCNT="$CMDCNT" -Ptest.CMDFILE="\"$TEST\"" test.v ../../jt9346.v && vvp sim.vvp -lxt
