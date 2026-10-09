# =============================================================================
# build.tcl  -  Vivado non-project flow for the I3C Target (out-of-context)
#
#   vivado -mode batch -source syn/xilinx/build.tcl          (from any directory)
#   or, in an open Vivado Tcl session:  source syn/xilinx/build.tcl
#
# Stages, in order: RTL lint -> synthesis -> opt -> place -> route -> reports.
# Reports land in syn/xilinx/reports/, checkpoints/scratch in syn/xilinx/build/.
# =============================================================================
set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir .. ..]]
set rpt_dir    [file join $script_dir reports]
set out_dir    [file join $script_dir build]
file mkdir $rpt_dir $out_dir

set part xc7a100tcsg324-1
set top  i3c_target_top

# Same file list / order as sim/run.sh and the Altera QSF, with the Xilinx IO
# wrapper in place of rtl/altera/i3c_io_altera.sv.
set rtl_files {
  rtl/i3c_pkg.sv rtl/i3c_sda_mux.sv rtl/i3c_bus_frontend.sv rtl/i3c_bit_engine.sv
  rtl/i3c_framer.sv rtl/i3c_hdr_exit_detector.sv rtl/i3c_fifo.sv rtl/i3c_protocol_fsm.sv
  rtl/i3c_daa.sv rtl/i3c_ccc.sv rtl/i3c_ibi.sv rtl/i3c_error_recovery.sv rtl/i3c_regfile.sv
  rtl/i3c_avalon_mm.sv rtl/xilinx/i3c_io_xilinx.sv rtl/i3c_target_top.sv
}
# i3c_target_top instantiates `I3C_IO_CELL (default i3c_io_altera).
set defines {I3C_IO_CELL=i3c_io_xilinx}

# Start from a clean in-memory project so the script can be re-sourced.
close_project -quiet
create_project -in_memory -part $part
# read_verilog/read_xdc take a LIST of files: wrap each path in [list] so a
# checkout path containing spaces is not split.
foreach f $rtl_files { read_verilog -sv [list [file join $repo_dir $f]] }
set_property include_dirs [list [file join $repo_dir rtl]] [current_fileset]
read_xdc -mode out_of_context [list [file join $script_dir i3c_target.xdc]]

# ---- 1. RTL lint ------------------------------------------------------------
# NOTE: `synth_design -lint -file` silently skips the lint run when the report
# path contains a space (Vivado 2025.2: "Detected extra character(s)" from an
# internal rt::set_parameter), so run from the design root with a relative path.
file delete -force [file join $rpt_dir lint.rpt]
set old_pwd [pwd]
cd $repo_dir
synth_design -top $top -part $part -verilog_define $defines -lint \
  -file syn/xilinx/reports/lint.rpt
cd $old_pwd
if {![file exists [file join $rpt_dir lint.rpt]]} { error "lint report was not written" }
close_design -quiet

# ---- 2. Synthesis (out-of-context: no I/O buffer insertion on the IP ports) --
synth_design -top $top -part $part -verilog_define $defines -mode out_of_context
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $rpt_dir utilization_synth.rpt]

# ---- 3. Implementation ------------------------------------------------------
opt_design
place_design
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]

# ---- 4. Reports -------------------------------------------------------------
report_utilization                       -file [file join $rpt_dir utilization.rpt]
report_utilization -hierarchical         -file [file join $rpt_dir utilization_hier.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
                                         -file [file join $rpt_dir timing_summary.rpt]
report_drc                               -file [file join $rpt_dir drc.rpt]
report_methodology                       -file [file join $rpt_dir methodology.rpt]
report_route_status                      -file [file join $rpt_dir route_status.rpt]

# Worst slack per path class (same idea as reports/quartus/timing_split.txt):
# the Avalon ports are an on-chip boundary, so port paths and internal
# register-to-register paths are reported separately.
proc worst_slack {type args} {
  set p [get_timing_paths -quiet $type -max_paths 1 {*}$args]
  if {[llength $p] == 0} { return "n/a" }
  return [get_property SLACK $p]
}
set regs [all_registers]
set fh [open [file join $rpt_dir timing_split.rpt] w]
puts $fh "Worst slack by path class, clk = 8.000 ns (ns; negative = violated)"
puts $fh [format "%-34s %10s %10s" "path class" "setup" "hold"]
foreach {name pargs} [list \
    "all paths"                {} \
    "register -> register"     [list -from $regs -to $regs] \
    "input port -> register"   [list -from [all_inputs] -to $regs] \
    "register -> output port"  [list -from $regs -to [all_outputs]] \
    "input port -> output port" [list -from [all_inputs] -to [all_outputs]]] {
  puts $fh [format "%-34s %10s %10s" $name \
    [worst_slack -setup {*}$pargs] [worst_slack -hold {*}$pargs]]
}
puts $fh ""
puts $fh "Failing hold endpoints by class (slack < 0):"
puts $fh [format "  input port -> register : %d" \
  [llength [get_timing_paths -quiet -hold -max_paths 10000 -slack_lesser_than 0 -from [all_inputs] -to $regs]]]
puts $fh [format "  register -> register   : %d" \
  [llength [get_timing_paths -quiet -hold -max_paths 10000 -slack_lesser_than 0 -from $regs -to $regs]]]
puts $fh ""
puts $fh "Worst hold path (detail):"
puts $fh [report_timing -hold -max_paths 1 -return_string]
close $fh

puts "I3C_BUILD_DONE  WNS=[worst_slack -setup]  WHS=[worst_slack -hold]"
