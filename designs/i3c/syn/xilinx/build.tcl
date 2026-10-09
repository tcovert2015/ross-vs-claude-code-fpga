# =============================================================================
# build.tcl  -  Vivado non-project flow for the I3C Target (Artix-7, OOC)
#
#   vivado -mode batch -source syn/xilinx/build.tcl
#
# Runs, in order: RTL lint -> synthesis (out-of-context) -> opt -> place ->
# route, and writes utilization / timing_summary / drc reports to
# syn/xilinx/reports/ (checkpoints in syn/xilinx/build/). The script cds to its
# own directory, so it can be launched from any working directory.
# =============================================================================
set script_dir [file dirname [file normalize [info script]]]

# Work from syn/xilinx/ and use RELATIVE paths everywhere: Vivado 2025.2's
# `synth_design -lint -file <path>` mis-parses a path containing spaces (the
# report is not written and lint mode leaks into the next synth_design).
cd $script_dir
set rtl_dir ../../rtl
set rpt_dir reports
set out_dir build

set part   xc7a100tcsg324-1
set top    i3c_target_top
# Selects the Xilinx IO shim in i3c_target_top (default is i3c_io_altera).
set defines [list I3C_IO_MODULE=i3c_io_xilinx]

file mkdir $rpt_dir
file mkdir $out_dir

# Same file list / order as sim/run.sh and syn/altera/i3c_target.qsf, with the
# Xilinx shim in place of the Altera one.
set rtl_files {
  i3c_pkg.sv i3c_sda_mux.sv i3c_bus_frontend.sv i3c_bit_engine.sv
  i3c_framer.sv i3c_hdr_exit_detector.sv i3c_fifo.sv i3c_protocol_fsm.sv
  i3c_daa.sv i3c_ccc.sv i3c_ibi.sv i3c_error_recovery.sv i3c_regfile.sv
  i3c_avalon_mm.sv xilinx/i3c_io_xilinx.sv i3c_target_top.sv
}
foreach f $rtl_files {
  read_verilog -sv $rtl_dir/$f
}
read_xdc -mode out_of_context i3c_target.xdc

# ---- 1. RTL lint -------------------------------------------------------------
puts "=== \[1/4\] RTL lint ==="
synth_design -lint -top $top -part $part -include_dirs $rtl_dir \
  -verilog_define $defines -file $rpt_dir/lint.rpt
if {![file exists $rpt_dir/lint.rpt]} { error "lint report was not written" }
close_design -quiet

# ---- 2. Synthesis (out-of-context: IP core, no pad ring on the Avalon side) --
puts "=== \[2/4\] Synthesis ==="
synth_design -top $top -part $part -mode out_of_context \
  -include_dirs $rtl_dir -verilog_define $defines
write_checkpoint -force $out_dir/post_synth.dcp
report_utilization -file $rpt_dir/utilization_synth.rpt

# ---- 3. Implementation -------------------------------------------------------
puts "=== \[3/4\] Implementation ==="
opt_design
place_design
route_design
write_checkpoint -force $out_dir/post_route.dcp

# ---- 4. Reports --------------------------------------------------------------
puts "=== \[4/4\] Reports ==="
report_utilization     -file $rpt_dir/utilization.rpt
report_utilization     -hierarchical -file $rpt_dir/utilization_hier.rpt
report_timing_summary  -delay_type min_max -max_paths 10 -report_unconstrained \
                       -file $rpt_dir/timing_summary.rpt
report_drc             -file $rpt_dir/drc.rpt
report_route_status    -file $rpt_dir/route_status.rpt

# Setup/hold split by path class (same idea as reports/quartus/timing_split.txt):
# the Avalon ports are an on-chip IP boundary with placeholder I/O budgets, so
# the port classes are reported separately from the internal reg-to-reg logic.
proc slack_of {type from to} {
  set p [get_timing_paths -quiet -delay_type $type -max_paths 1 -from $from -to $to]
  if {[llength $p] == 0} { return "n/a" }
  return [get_property SLACK [lindex $p 0]]
}
set regs_ck [all_registers -clock_pins]
set regs_d  [all_registers -data_pins]
set ins     [all_inputs]
set outs    [all_outputs]
set fh [open $rpt_dir/timing_split.rpt w]
puts $fh "Post-route worst slack by path class, clk = 8.000 ns (ns; n/a = no constrained path)"
puts $fh [format "%-22s %10s %10s" "path class" "setup" "hold"]
foreach {name from to} [list reg-to-reg $regs_ck $regs_d  input-to-reg $ins $regs_d                              reg-to-output $regs_ck $outs  input-to-output $ins $outs] {
  puts $fh [format "%-22s %10s %10s" $name [slack_of max $from $to] [slack_of min $from $to]]
}
puts $fh [format "%-22s %10s %10s" "ALL (WNS / WHS)"   [get_property SLACK [get_timing_paths -delay_type max]]   [get_property SLACK [get_timing_paths -delay_type min]]]
close $fh

set fh [open $rpt_dir/timing_split.rpt r]; puts [read $fh]; close $fh
puts "BUILD DONE"
