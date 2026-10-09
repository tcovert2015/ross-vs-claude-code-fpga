#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#============================================================================
# run_questa.sh -- run the self-checking testbench (tb_pcie_dma) in the
# QuestaSim Lattice Edition bundled with Radiant, for the AXI4 system bus with
# and without bus back-pressure.
#
#   ./scripts/run_questa.sh                 # AXI4 and AXI4+STALLS (+ the same
#                                           # two with RESET_SYNC=1), seeds 1 2 3
#   SIM_SEEDS="1 2 3 4" ./scripts/run_questa.sh
#   QUESTA_BIN=/path/to/questasim/win64 ./scripts/run_questa.sh
#
# Same pass criterion as scripts/run_sim.sh: a (config, seed) passes iff its
# output contains "=== PASS". Each configuration is compiled once and run under
# every seed (+SEED plusarg). Logs: sim/build/questa_<cfg>_seed<n>.log (and
# sim/build/questa_<cfg>_compile.log). Exits non-zero if anything fails.
#
# -suppress 7061: the testbench preloads/patches the memory models' `mem`
# arrays by hierarchical reference (host_mem.mem[..] = ...) while the models
# write them from an always_ff. Questa flags that as the suppressible error
# vopt-7061 (Icarus does not check it). It is testbench-only backdoor access;
# no RTL or TB source is modified.
#============================================================================
set -u
cd "$(dirname "$0")/.."
mkdir -p sim/build

QUESTA_BIN="${QUESTA_BIN:-/d/lscc/radiant/2026.1/questasim/win64}"
SEEDS="${SIM_SEEDS:-1 2 3}"

RTL="rtl/pkg/dma_pkg.sv \
     rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv rtl/core/dma_csr.sv \
     rtl/core/dma_descriptor_fetch.sv rtl/core/dma_data_mover.sv rtl/core/dma_engine_core.sv \
     rtl/core/reset_sync.sv \
     rtl/adapters/gmm_to_avalon.sv rtl/adapters/gmm_to_axi4.sv rtl/adapters/gmm_to_ahb.sv \
     rtl/top/pcie_dma_top.sv \
     sim/models/avalon_mem_model.sv sim/models/axi_mem_model.sv sim/models/ahb_mem_model.sv \
     sim/tb_pcie_dma.sv"

rc=0

# run <cfg-tag> <define>...
run() {
  local cfg="$1"; shift
  local defs=""
  for d in "$@"; do defs="$defs +define+$d"; done
  local lib="sim/build/questa_work_$cfg"
  local clog="sim/build/questa_${cfg}_compile.log"
  rm -rf "$lib"
  "$QUESTA_BIN/vlib" "$lib" >"$clog" 2>&1
  "$QUESTA_BIN/vlog" -sv -work "$lib" +incdir+rtl/pkg $defs $RTL >>"$clog" 2>&1
  if [ $? -ne 0 ]; then echo "$cfg: COMPILE FAIL"; cat "$clog"; rc=1; return 1; fi
  local s log
  for s in $SEEDS; do
    log="sim/build/questa_${cfg}_seed${s}.log"
    "$QUESTA_BIN/vsim" -c -lib "$lib" -suppress 7061 tb_pcie_dma +SEED="$s" -do "run -all; quit -f" >"$log" 2>&1
    if grep -q "=== PASS" "$log"; then
      echo "$cfg seed=$s: PASS"
    else
      echo "$cfg seed=$s: FAIL"; tail -8 "$log"; rc=1
    fi
  done
}

run AXI4        USE_AXI
run AXI4_STALLS USE_AXI STALLS
# extra (not in the run_sim.sh AXI4 set): the same two configurations with the
# 2-FF reset synchronizer enabled (RESET_SYNC=1), i.e. the parameter set that
# lattice/build.tcl synthesizes.
run AXI4_RSTSYNC        USE_AXI RESET_SYNC_EN
run AXI4_STALLS_RSTSYNC USE_AXI STALLS RESET_SYNC_EN

exit $rc
