#!/usr/bin/env bash
# Compile + run the I3C Target behavioral testbench with Icarus Verilog.
set -u
cd "$(dirname "$0")/.."
OUT=sim/tb_i3c.vvp
LOG=sim/iverilog.log
iverilog -g2012 -gno-assertions -I rtl -s tb_i3c_target -o "$OUT" \
  rtl/i3c_pkg.sv rtl/i3c_sda_mux.sv rtl/i3c_bus_frontend.sv rtl/i3c_bit_engine.sv \
  rtl/i3c_framer.sv rtl/i3c_hdr_exit_detector.sv rtl/i3c_fifo.sv rtl/i3c_protocol_fsm.sv \
  rtl/i3c_daa.sv rtl/i3c_ccc.sv rtl/i3c_ibi.sv rtl/i3c_error_recovery.sv rtl/i3c_regfile.sv \
  rtl/i3c_avalon_mm.sv rtl/altera/i3c_io_altera.sv rtl/i3c_target_top.sv \
  sim/tb_i3c_target.sv >"$LOG" 2>&1
rc=$?
# iverilog returns non-zero on real errors; "sorry:" notes (harmless) keep it at 0.
if [ "$rc" -ne 0 ]; then echo "COMPILE FAILED ($rc)"; grep -iE 'error' "$LOG" | head; exit 1; fi
vvp "$OUT"
