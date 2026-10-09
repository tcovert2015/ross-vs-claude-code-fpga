#!/usr/bin/env bash
# run_questa.sh — run the fpga-scope self-checking testbenches in QuestaSim (the Lattice OEM
# edition bundled with Radiant). Questa counterpart of run.sh (Verilator): same sources, same
# source order, same golden vectors, same "TB_RESULT: PASS"/"FAIL" contract.
#
#   bash sim/run_questa.sh                 # full regression (every TB run.sh runs, plus
#                                          # tb_axil_top for fpga/lattice/scope_axil_top.sv)
#   bash sim/run_questa.sh tb_smoke tb_csr tb_csr_if     # a subset
#
# Environment:
#   QUESTA_BIN  directory holding vlib/vlog/vsim (default: Radiant 2026.1 install)
#   PYTHON      python interpreter for sim/model/scope_ref.py (default: python, then python3)
#
# One vlog+vsim per testbench in its own work library (sim/build/questa/<tb>/). The full
# transcript of each (compile + run) is saved to sim/questa_<tb>.log. A TB passes iff its log
# contains "TB_RESULT: PASS", no "TB_RESULT: FAIL", and vlog/vsim report no errors. Exits
# non-zero if any TB fails. tb_cosim is not run here (DPI-C + Python co-sim, as in run.sh).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUESTA_BIN="${QUESTA_BIN:-/d/lscc/radiant/2026.1/questasim/win64}"
if [ -z "${PYTHON:-}" ]; then
  if python --version >/dev/null 2>&1; then PYTHON=python; else PYTHON=python3; fi
fi

# Everything is run from the repo root with repo-relative paths: the TBs $readmemh their
# golden vectors via "sim/build/vectors/..." and relative paths sidestep MSYS/Windows path
# translation for the Questa executables.
cd "$ROOT"
RTL=rtl
SIM=sim
BUILD=sim/build
VEC=$BUILD/vectors

ALL_TBS=(tb_smoke tb_prim_ram tb_prim_fifo_sync tb_prim_fifo_async tb_capture_basic tb_csr
         tb_trigger_cmp tb_trigger_seq tb_pretrig tb_windows tb_drain_cdc tb_uart tb_csr_if
         tb_rle tb_ext_trig tb_jtag tb_axil_top)
if [ "$#" -gt 0 ]; then TBS=("$@"); else TBS=("${ALL_TBS[@]}"); fi

# Golden vectors: identical scope_ref.py invocations to run.sh's gen_vectors (keep in sync).
ref() { "$PYTHON" "$SIM/model/scope_ref.py" "$@" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }; }
gen_vectors() {
  echo "== Generating golden vectors (sim/model/scope_ref.py)"
  mkdir -p "$VEC"
  ref capture --probe-w 32 --depth-log2 8 --pretrig 0 --trig-sample 128 --count 640 \
      --seed 0xC0FFEE01 --out-prefix "$VEC/cap_w32_d8"
  ref capture --probe-w 512 --depth-log2 10 --pretrig 0 --trig-sample 512 --count 2560 \
      --seed 0xC0FFEE02 --out-prefix "$VEC/cap_w512_d10"
  ref trigger-suite --suite cmp --probe-w 16 --out-prefix "$VEC/trig_cmp"
  ref trigger-suite --suite seq --probe-w 16 --out-prefix "$VEC/trig_seq"
  local d depth i
  for d in 8 10; do
    depth=$((1 << d))
    local ps=(0 1 $((depth / 4)) $((depth / 2)) $((depth - 1)))
    local ks=(3 $((2 * depth + 341)) $((depth / 4)) $((2 * depth + 123)) $((2 * depth + 55)))
    for i in 0 1 2 3 4; do
      ref capture --probe-w 32 --depth-log2 "$d" --pretrig "${ps[$i]}" \
          --trig-sample "${ks[$i]}" --count $((${ks[$i]} + depth + 8)) \
          --seed $((0xBEEF0000 + d * 16 + i)) --out-prefix "$VEC/pt_d${d}_p${ps[$i]}"
    done
  done
  ref windows --probe-w 32 --depth-log2 8 --pretrig 64 --windows 1 --trig-rel 300 \
      --count 4000 --out-prefix "$VEC/win_w1"
  ref windows --probe-w 32 --depth-log2 8 --pretrig 64 --windows 2 --trig-rel 5,200 \
      --count 4000 --out-prefix "$VEC/win_w2"
  ref windows --probe-w 32 --depth-log2 8 --pretrig 64 --windows 3 --trig-rel 0,90,33 \
      --count 4000 --out-prefix "$VEC/win_w3"
  ref windows --probe-w 32 --depth-log2 8 --pretrig 64 --windows 5 --trig-rel 40,0,77,150,3 \
      --count 4000 --out-prefix "$VEC/win_w5"
  ref windows --probe-w 32 --depth-log2 8 --pretrig 64 --windows 8 \
      --trig-rel 9,60,2,130,0,45,20,71 --count 4000 --out-prefix "$VEC/win_w8"
  ref capture --probe-w 32 --depth-log2 8 --pretrig 0 --trig-sample 300 --count 564 \
      --seed 0xD4A1DA7A --idle-prefix 2 --out-prefix "$VEC/drn"
  ref drain-data --probe-w 32 --buf-in "$VEC/drn_buf.mem" --out-prefix "$VEC/drn"
  ref rle --probe-w 8 --cnt-w 8 --count 400 --runs 20 --seed 0xC0FFEE09 --out-prefix "$VEC/rle_c8"
  ref rle --probe-w 8 --cnt-w 8 --count 400 --runs 0 --seed 0xBADC0DE1 --out-prefix "$VEC/rle_t8"
  ref rle --probe-w 32 --cnt-w 10 --count 300 --runs 6 --seed 0x51261234 --out-prefix "$VEC/rle_w32"
}

# Same list and order as run.sh COMMON_SRCS, plus the Lattice top.
COMMON_SRCS=(
  "$RTL/scope_pkg.sv"
  "$RTL/prim/prim_ff_sync.sv"
  "$RTL/prim/prim_ram_1r1w.sv"
  "$RTL/prim/prim_fifo_sync.sv"
  "$RTL/prim/prim_fifo_async.sv"
  "$RTL/scope_core.sv"
  "$RTL/scope_csr.sv"
  "$RTL/scope_trigger.sv"
  "$RTL/scope_rle.sv"
  "$RTL/scope_drain.sv"
  "$RTL/xport/scope_uart.sv"
  "$RTL/scope_top.sv"
  "$RTL/if/scope_avalon.sv"
  "$RTL/if/scope_axil.sv"
  "$RTL/if/scope_jtag.sv"
  # -- Radiant AXI4-Lite top (fpga/lattice), exercised by tb_axil_top:
  fpga/lattice/scope_axil_top.sv
)

overall=0
declare -a summary=()

run_one() {
  local tb="$1"
  local lib="$BUILD/questa/$tb"
  local log="$SIM/questa_$tb.log"
  echo "=================================================================="
  echo "== Questa: $tb"
  echo "=================================================================="
  rm -rf "$lib"
  mkdir -p "$BUILD/questa"
  : > "$log"
  # -timescale: RTL files carry no `timescale (repo convention); run.sh passes the same 1ns/1ps.
  if ! { "$QUESTA_BIN/vlib" "$lib" &&
         "$QUESTA_BIN/vlog" -sv -work "$lib" -timescale 1ns/1ps \
             "${COMMON_SRCS[@]}" "$SIM/$tb.sv"; } >> "$log" 2>&1; then
    cat "$log"
    echo "TB_RESULT: FAIL ($tb compile error)" | tee -a "$log"
    overall=1; summary+=("$tb FAIL(compile)"); return
  fi
  "$QUESTA_BIN/vsim" -c -lib "$lib" -do "run -all; quit -f" "$tb" >> "$log" 2>&1
  local rc=$?
  grep -E "TB_RESULT|^# \*\* (Error|Fatal)|^# Errors:|^-- |PASS" "$log" | sed 's/^# //' | sort -u | head -40
  if [ "$rc" -eq 0 ] && grep -q "TB_RESULT: PASS" "$log" && ! grep -q "TB_RESULT: FAIL" "$log" \
     && ! grep -Eq "^# \*\* (Error|Fatal)|Errors: [1-9]" "$log"; then
    summary+=("$tb PASS")
  else
    echo "TB_RESULT: FAIL ($tb simulation error, vsim rc=$rc)" | tee -a "$log"
    overall=1; summary+=("$tb FAIL")
  fi
}

"$QUESTA_BIN/vsim" -version || { echo "vsim not found in QUESTA_BIN=$QUESTA_BIN"; exit 1; }
gen_vectors
for tb in "${TBS[@]}"; do run_one "$tb"; done
rm -f transcript   # vsim's cwd transcript duplicates the per-TB logs

echo "=================================================================="
printf '%s\n' "${summary[@]}"
if [ "$overall" -eq 0 ]; then
  echo "ALL QUESTA TESTBENCHES PASSED"
else
  echo "ONE OR MORE QUESTA TESTBENCHES FAILED"
fi
exit "$overall"
