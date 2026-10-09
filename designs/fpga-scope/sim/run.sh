#!/usr/bin/env bash
# run.sh — build + run the fpga-scope self-checking Verilator testbenches.
#
# One verilator --binary build+run per testbench. Exits non-zero on any build, elaboration,
# or simulation failure (a TB signals failure with $fatal -> non-zero exit and prints
# "TB_RESULT: FAIL"; success prints "TB_RESULT: PASS" and $finish -> exit 0).
# Same contract as ../hyperram/sim/run.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="$ROOT/rtl"
SIM="$ROOT/sim"
BUILD="$SIM/build"

# TBs load run.sh-generated golden vectors via repo-root-relative paths ($readmemh).
cd "$ROOT"

# Golden vectors (issue #4+): scope_ref.py replays the TB stimulus and writes the expected
# results as .mem files BEFORE the TBs run — no manual pre-steps.
gen_vectors() {
  echo "=================================================================="
  echo "== Generating golden vectors (sim/model/scope_ref.py)"
  echo "=================================================================="
  mkdir -p "$BUILD/vectors"
  # tb_capture_basic leg A: PROBE_W=32, DEPTH_LOG2=8, force-trig at sample DEPTH/2
  python3 "$SIM/model/scope_ref.py" capture --probe-w 32 --depth-log2 8 --pretrig 0 \
    --trig-sample 128 --count 640 --seed 0xC0FFEE01 \
    --out-prefix "$BUILD/vectors/cap_w32_d8" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  # tb_capture_basic leg B: PROBE_W=512, DEPTH_LOG2=10
  python3 "$SIM/model/scope_ref.py" capture --probe-w 512 --depth-log2 10 --pretrig 0 \
    --trig-sample 512 --count 2560 --seed 0xC0FFEE02 \
    --out-prefix "$BUILD/vectors/cap_w512_d10" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  # tb_trigger_cmp / tb_trigger_seq case suites (issue #6)
  python3 "$SIM/model/scope_ref.py" trigger-suite --suite cmp --probe-w 16 \
    --out-prefix "$BUILD/vectors/trig_cmp" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" trigger-suite --suite seq --probe-w 16 \
    --out-prefix "$BUILD/vectors/trig_seq" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  # tb_pretrig sweep (issue #7) — the pretrig/trig-sample table here MUST match the
  # PT[]/KS[] localparams in sim/tb_pretrig.sv
  local d depth i
  for d in 8 10; do
    depth=$((1 << d))
    local ps=(0 1 $((depth / 4)) $((depth / 2)) $((depth - 1)))
    local ks=(3 $((2 * depth + 341)) $((depth / 4)) $((2 * depth + 123)) $((2 * depth + 55)))
    for i in 0 1 2 3 4; do
      python3 "$SIM/model/scope_ref.py" capture --probe-w 32 --depth-log2 "$d" \
        --pretrig "${ps[$i]}" --trig-sample "${ks[$i]}" --count $((${ks[$i]} + depth + 8)) \
        --seed $((0xBEEF0000 + d * 16 + i)) \
        --out-prefix "$BUILD/vectors/pt_d${d}_p${ps[$i]}" \
        || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
    done
  done
  # tb_windows (issue #7): per-window trigger schedules incl. rel=0 (first ARMED sample)
  python3 "$SIM/model/scope_ref.py" windows --probe-w 32 --depth-log2 8 --pretrig 64 \
    --windows 1 --trig-rel 300 --count 4000 --out-prefix "$BUILD/vectors/win_w1" \
    || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" windows --probe-w 32 --depth-log2 8 --pretrig 64 \
    --windows 2 --trig-rel 5,200 --count 4000 --out-prefix "$BUILD/vectors/win_w2" \
    || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" windows --probe-w 32 --depth-log2 8 --pretrig 64 \
    --windows 3 --trig-rel 0,90,33 --count 4000 --out-prefix "$BUILD/vectors/win_w3" \
    || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" windows --probe-w 32 --depth-log2 8 --pretrig 64 \
    --windows 5 --trig-rel 40,0,77,150,3 --count 4000 --out-prefix "$BUILD/vectors/win_w5" \
    || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" windows --probe-w 32 --depth-log2 8 --pretrig 64 \
    --windows 8 --trig-rel 9,60,2,130,0,45,20,71 --count 4000 \
    --out-prefix "$BUILD/vectors/win_w8" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  # tb_drain_cdc (issue #8): stored sample K=300 (matches the K localparam in the TB);
  # first 2 stimulus entries are the pre-arm idle zeros (trigger sample_o pipe depth)
  python3 "$SIM/model/scope_ref.py" capture --probe-w 32 --depth-log2 8 --pretrig 0 \
    --trig-sample 300 --count 564 --seed 0xD4A1DA7A --idle-prefix 2 \
    --out-prefix "$BUILD/vectors/drn" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" drain-data --probe-w 32 \
    --buf-in "$BUILD/vectors/drn_buf.mem" \
    --out-prefix "$BUILD/vectors/drn" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }

  # issue #9: RLE encode vectors (samples + expected words) for tb_rle. --runs biases toward
  # runs (compressible); --runs 0 is the near-worst-case mostly-changing stream. cmd_rle also
  # runs the decode-identity + expansion-bound self-test on every invocation.
  python3 "$SIM/model/scope_ref.py" rle --probe-w 8 --cnt-w 8 --count 400 --runs 20 \
    --seed 0xC0FFEE09 --out-prefix "$BUILD/vectors/rle_c8" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" rle --probe-w 8 --cnt-w 8 --count 400 --runs 0 \
    --seed 0xBADC0DE1 --out-prefix "$BUILD/vectors/rle_t8" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  python3 "$SIM/model/scope_ref.py" rle --probe-w 32 --cnt-w 10 --count 300 --runs 6 \
    --seed 0x51261234 --out-prefix "$BUILD/vectors/rle_w32" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
}

# Source order: package first (scope_pkg, issue #4), then rtl/prim primitives (issue #3),
# then core RTL (issues #4..#9), then rtl/if + rtl/xport front-ends (issues #8, #11),
# then sim/model helpers, then the TB itself (appended per run_one call).
COMMON_SRCS=(
  # -- package first:
  "$RTL/scope_pkg.sv"
  # -- primitives (issue #3):
  "$RTL/prim/prim_ff_sync.sv"
  "$RTL/prim/prim_ram_1r1w.sv"
  "$RTL/prim/prim_fifo_sync.sv"
  "$RTL/prim/prim_fifo_async.sv"
  # -- core RTL (issues #4..#9): scope_core, then scope_csr, scope_trigger, scope_rle, scope_drain, scope_top
  "$RTL/scope_core.sv"
  "$RTL/scope_csr.sv"
  "$RTL/scope_trigger.sv"
  "$RTL/scope_rle.sv"
  "$RTL/scope_drain.sv"
  "$RTL/xport/scope_uart.sv"
  "$RTL/scope_top.sv"
  # -- CSR bus front-ends (issue #11):
  "$RTL/if/scope_avalon.sv"
  "$RTL/if/scope_axil.sv"
  "$RTL/if/scope_jtag.sv"
  # -- sim models: none yet (golden refs are Python-generated .mem files, see gen_vectors)
)

# -Wall with no waivers. Add waivers only when strictly needed, each with a one-line
# justification comment (hyperram VFLAGS block is the precedent).
# --timescale gives RTL files (which carry no timescale directive, per convention) the same
# 1ns/1ps scale as the TBs so -Wall's TIMESCALEMOD stays clean without per-file directives.
VFLAGS=(--binary --timing -Wall --timescale 1ns/1ps
        -I"$RTL" -I"$RTL/if" -I"$RTL/xport" -I"$RTL/prim" -j 4)

overall=0

run_one() {
  local tb="$1" top="$2"
  shift 2
  local extra_srcs=("$@")       # optional extra RTL sources for this TB only
  echo "=================================================================="
  echo "== Building $top"
  echo "=================================================================="
  local odir="$BUILD/$top"
  rm -rf "$odir"
  mkdir -p "$odir"
  if ! verilator "${VFLAGS[@]}" --top-module "$top" --Mdir "$odir" -o "$top" \
        ${COMMON_SRCS[@]+"${COMMON_SRCS[@]}"} ${extra_srcs[@]+"${extra_srcs[@]}"} \
        "$SIM/$tb" > "$odir/build.log" 2>&1; then
    echo "-- build FAILED; log follows --"
    cat "$odir/build.log"
    echo "TB_RESULT: FAIL ($top build error)"
    overall=1
    return
  fi
  echo "-- build ok"
  echo "== Running $top"
  if ! "$odir/$top"; then
    echo "TB_RESULT: FAIL ($top simulation error / non-zero exit)"
    overall=1
    return
  fi
}

gen_vectors

run_one tb_smoke.sv           tb_smoke            # issue #2: harness/CI plumbing proof
run_one tb_prim_ram.sv        tb_prim_ram         # issue #3: RAM read-during-write "old data" policy
run_one tb_prim_fifo_sync.sv  tb_prim_fifo_sync   # issue #3: sync FIFO fill/drain/boundary + scoreboard soak
run_one tb_prim_fifo_async.sv tb_prim_fifo_async  # issue #3: async FIFO 3:1 / 1:3 / ~1:1 CDC soak, >=100k/leg
run_one tb_capture_basic.sv   tb_capture_basic    # issue #4: scope_core capture bit-exact vs scope_ref.py
run_one tb_csr.sv             tb_csr              # issue #5: CSR matrix, cfg_err lockout, BUF_DATA drain
run_one tb_trigger_cmp.sv     tb_trigger_cmp      # issue #6: comparator truth table, cycle-exact vs model
run_one tb_trigger_seq.sv     tb_trigger_seq      # issue #6: sequencer configs, latency + alignment asserts
run_one tb_pretrig.sv         tb_pretrig          # issue #7: PRETRIG sweep + host-math reconstruction
run_one tb_windows.sv         tb_windows          # issue #7: window slicing, metadata, disarm, cfg_err bound
run_one tb_drain_cdc.sv       tb_drain_cdc        # issue #8: scope_top over byte stream, xclk!=clk, NAK/resync
run_one tb_uart.sv            tb_uart             # issue #8: bit-level UART, LSB-first + BE-CRC asserts first
run_one tb_csr_if.sv          tb_csr_if           # issue #11: CSR matrix + BUF_DATA pop via Avalon-MM & AXI-Lite
run_one tb_rle.sv             tb_rle              # issue #9: RLE encoder word stream vs model, bypass, expansion bound
run_one tb_ext_trig.sv        tb_ext_trig         # issue #13: dual-instance cross-trigger (A cmp -> B trig_ext) + independence
run_one tb_jtag.sv           tb_jtag             # issue #15: framed protocol over scope_jtag byte bridge, byte-exact == STREAM

# scope_top elaboration matrix (issue #8/#9): PROBE_W {8, 512} x XPORT {UART, STREAM} x
# RLE_EN {0, 1} beyond the fully-tested TB configs — lint-only builds, same -Wall flags.
# RLE_EN=1 elaborates the scope_rle stage + STORE_W=PROBE_W+1 store path (issue #9).
for pw in 8 512; do
  for xp in UART STREAM; do
    for rle in 0 1; do
      echo "== Lint matrix: scope_top PROBE_W=$pw XPORT=$xp RLE_EN=$rle"
      if ! verilator --lint-only --timing -Wall --timescale 1ns/1ps \
            -I"$RTL" -I"$RTL/if" -I"$RTL/xport" -I"$RTL/prim" \
            --top-module scope_top -GPROBE_W="$pw" -GXPORT="\"$xp\"" -GRLE_EN="1'b$rle" \
            ${COMMON_SRCS[@]+"${COMMON_SRCS[@]}"} > "$BUILD/lint_${pw}_${xp}_r${rle}.log" 2>&1; then
        cat "$BUILD/lint_${pw}_${xp}_r${rle}.log"
        echo "TB_RESULT: FAIL (lint matrix PROBE_W=$pw XPORT=$xp RLE_EN=$rle)"
        overall=1
      fi
    done
  done
done

echo "=================================================================="
if [ "$overall" -eq 0 ]; then
  echo "ALL TESTBENCHES PASSED"
else
  echo "ONE OR MORE TESTBENCHES FAILED"
fi
exit "$overall"
