#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the SH7604's upstream tests, unchanged, against this repository's copy.
#
#     scripts/sh7604_tests.sh              # all six
#     scripts/sh7604_tests.sh sh7604_trace # one
#
# The tests are jotego's, under rtl/cpu/sh7604/tests/ (PROVENANCE.md there). Four carry a
# sim.sh: it assembles a program with sh-elf-as (tools/sh-elf), builds the bench with Verilator
# and runs it, taking the RTL from $JTFRAME/hdl/..., the include tasks from $JTFRAME/ver/inc and
# jtframe's C++ SDRAM model from $JTFRAME/verilator. Two (the DMAC unit tests) have only a
# gather.f for jotego's simunit.sh, which runs Icarus.
#
# What this script supplies, so the test files stay byte-for-byte upstream:
#   * a jtframe-shaped tree under obj_verilator/jtframe: hdl/cpu, hdl/ram, hdl/sdram, ver/inc
#     and verilator are directory junctions onto rtl/cpu and tests/jtframe, and each test is
#     copied into ver/cpu/<name> before it runs, so $JTFRAME paths and the tests' relative
#     includes (../../../hdl/cpu/sh7604/...) both resolve from where the copy sits;
#   * jtsh7604_cps3_region.v and SH_core_trace.sv copied beside each test: the wrapper and the
#     core instantiate them, the upstream file lists predate them, and Verilator looks for a
#     missing module in the working directory;
#   * a `verilator` wrapper first on PATH that adds -Wno-fatal (the wrapper's cps3_region pins
#     the tests leave open, the timescale of the copied files, a width warning in the cache
#     test: Verilator stops on them, in jotego's tree as here), -O2 for the C++ build (MSYS2's
#     GCC 16 cannot link Verilator's default -Os runtime, as scripts/run_verilator.sh notes)
#     and VL_TIME_CONTEXT (the runtime then takes time from its context instead of calling
#     sc_time_stamp(), which the async-memory test defines inside an anonymous namespace);
#   * for the DMAC tests, simunit.sh's Icarus command with its options before the file names
#     (MinGW's option parser stops at the first file) and `vvp` for the run.
# Logs: obj_verilator/jtframe/ver/cpu/<name>/sim.log. MSYS2 MinGW64 supplies verilator,
# iverilog, g++, make and perl, as scripts/run_verilator.sh.
set -euo pipefail

if ! command -v verilator >/dev/null 2>&1; then
	MSYS=""
	for _c in "${MSYS2_ROOT:-}" /c/msys64 /d/msys64 /e/msys64 C:/msys64; do
		[ -n "$_c" ] && [ -x "$_c/usr/bin/bash.exe" ] && MSYS="$_c" && break
	done
	[ -n "$MSYS" ] || { echo "MSYS2 not found (verilator, g++, make, perl). Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && shift && exec scripts/sh7604_tests.sh "$@"' _ "$(pwd -W 2>/dev/null || pwd)" "$@"
fi

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
ROOT="$(pwd)"
TESTS_DIR="$ROOT/rtl/cpu/sh7604/tests"
[ -x "$ROOT/tools/sh-elf/bin/sh-elf-as.exe" ] || [ -x "$ROOT/tools/sh-elf/bin/sh-elf-as" ] || { echo "sh-elf-as not found: build tools/sh-elf first (its README)"; exit 1; }

SHIM="$ROOT/obj_verilator/jtframe"
mkdir -p "$SHIM/hdl" "$SHIM/ver/cpu" "$SHIM/bin"
junction() {   # $1 link, $2 target: a directory junction needs no privilege on Windows
	[ -e "$1" ] || MSYS2_ARG_CONV_EXCL='*' /c/Windows/System32/cmd.exe /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null
}
junction "$SHIM/hdl/cpu"   "$ROOT/rtl/cpu"
junction "$SHIM/hdl/ram"   "$TESTS_DIR/jtframe/ram"
junction "$SHIM/hdl/sdram" "$TESTS_DIR/jtframe/sdram"
junction "$SHIM/verilator" "$TESTS_DIR/jtframe/verilator"
junction "$SHIM/ver/inc"   "$TESTS_DIR/inc"
export JTFRAME="$SHIM"
export JTROOT="$SHIM"

REAL_VERILATOR="$(command -v verilator)"
cat > "$SHIM/bin/verilator" <<EOF
#!/usr/bin/env bash
exec "$REAL_VERILATOR" -Wno-fatal -Wno-PINMISSING -Wno-TIMESCALEMOD \\
	-MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_GLOBAL=-O2 -CFLAGS -DVL_TIME_CONTEXT "\$@"
EOF
chmod +x "$SHIM/bin/verilator"
export PATH="$SHIM/bin:$ROOT/tools/sh-elf/bin:$PATH"

TESTS=("$@")
[ ${#TESTS[@]} -gt 0 ] || TESTS=(sh7604_trace sh7604_async_mem sh7604_cache sh7604_bsc_dbus_marker sh7604_dmac_abort sh7604_dmac_readback)

run_simunit() {   # simunit.sh's run_simulation, options first, vvp for the run
	local macro="-D JTFRAME_MCLK=48000000"
	rm -f sim.vvp
	# shellcheck disable=SC2046
	iverilog -g2012 -I"$JTFRAME/ver/inc" -f gather.f -s test -o sim.vvp -D SIMULATION $macro \
		$(find . -name "*.v") $(find . -name "*.sv") && vvp sim.vvp -lxt | tee sim.log
	grep -q PASS sim.log
}

fail=0
for t in "${TESTS[@]}"; do
	echo "=== $t"
	d="$SHIM/ver/cpu/$t"
	rm -rf "$d"
	cp -r "$TESTS_DIR/$t" "$d"
	if [ -f "$d/sim.sh" ]; then
		# the two modules the upstream file lists omit, where Verilator looks for them
		cp "$ROOT/rtl/cpu/jtsh7604_cps3_region.v" "$ROOT/rtl/cpu/sh7604/SH_core_trace.sv" "$d/"
		if (cd "$d" && bash ./sim.sh > sim.log 2>&1); then
			tail -n 3 "$d/sim.log"; echo "PASS $t"
		else
			tail -n 15 "$d/sim.log"; echo "FAIL $t"; fail=1
		fi
	else
		if (cd "$d" && run_simunit > simunit.log 2>&1); then
			tail -n 3 "$d/simunit.log"; echo "PASS $t"
		else
			tail -n 15 "$d/simunit.log"; echo "FAIL $t"; fail=1
		fi
	fi
done
exit $fail
