# =============================================================================
# build.tcl  -  Vivado non-project flow for the I3C Target (Artix-7, OOC)
#
#   vivado -mode batch -source syn/xilinx/build.tcl
#
# Stages, in order: RTL lint -> synthesis -> opt/place/route -> reports.
# The script cds to its own directory, so it can be launched from anywhere.
# Scratch output (checkpoints) goes to syn/xilinx/build/ (ignored); reports go
# to syn/xilinx/reports/ (committed evidence).
# =============================================================================

set PART xc7a100tcsg324-1
set TOP  i3c_target_top

# Work from syn/xilinx/ with RELATIVE paths: several Vivado commands (read_xdc,
# -include_dirs, -file) mis-parse absolute paths that contain spaces.
cd [file dirname [file normalize [info script]]]
set RTL ../../rtl
set RPT reports
set OUT build
file mkdir $RPT
file mkdir $OUT

# Same file list / order as sim/run.sh and the Quartus QSF, with the Xilinx IO
# shim in place of the Altera one.
set SRC {
  i3c_pkg.sv i3c_sda_mux.sv i3c_bus_frontend.sv i3c_bit_engine.sv
  i3c_framer.sv i3c_hdr_exit_detector.sv i3c_fifo.sv i3c_protocol_fsm.sv
  i3c_daa.sv i3c_ccc.sv i3c_ibi.sv i3c_error_recovery.sv i3c_regfile.sv
  i3c_avalon_mm.sv xilinx/i3c_io_xilinx.sv i3c_target_top.sv
}
foreach f $SRC { read_verilog -sv [file join $RTL $f] }
read_xdc i3c_target.xdc

# i3c_target_top picks its pad cell from this macro (default: the Altera shim).
set DEFINES [list I3C_IO_CELL=i3c_io_xilinx]

# ---------------------------------------------------------------------------
# 1. RTL lint
# ---------------------------------------------------------------------------
puts "=== \[1/4\] RTL lint ==="
synth_design -lint -top $TOP -part $PART -include_dirs $RTL \
  -verilog_define $DEFINES -file [file join $RPT lint.rpt]

# ---------------------------------------------------------------------------
# 2. Synthesis (out-of-context: IP core, no pad buffers inserted; the SDA/SCL
#    pad cells are instantiated explicitly in rtl/xilinx/i3c_io_xilinx.sv)
# ---------------------------------------------------------------------------
puts "=== \[2/4\] Synthesis ==="
synth_design -top $TOP -part $PART -mode out_of_context -include_dirs $RTL \
  -verilog_define $DEFINES
write_checkpoint -force [file join $OUT post_synth.dcp]
report_utilization -file [file join $RPT utilization_synth.rpt]

# ---------------------------------------------------------------------------
# 3. Implementation
# ---------------------------------------------------------------------------
puts "=== \[3/4\] Implementation ==="
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $OUT post_route.dcp]

# ---------------------------------------------------------------------------
# 4. Reports
# ---------------------------------------------------------------------------
puts "=== \[4/4\] Reports ==="
report_utilization               -file [file join $RPT utilization.rpt]
report_utilization -hierarchical -file [file join $RPT utilization_hier.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
  -check_timing_verbose          -file [file join $RPT timing_summary.rpt]
report_drc                       -file [file join $RPT drc.rpt]
report_methodology               -file [file join $RPT methodology.rpt]
report_route_status              -file [file join $RPT route_status.rpt]

# Worst slack per path class (same idea as reports/quartus/timing_split.txt): the
# Avalon-MM ports are an on-chip boundary with placeholder I/O budgets, so the
# register-to-register class is the result that describes the logic itself.
proc worst {type from to} {
  set p [get_timing_paths -quiet -$type -max_paths 1 -nworst 1 -from $from -to $to]
  if {[llength $p] == 0} { return "n/a" }
  return [get_property SLACK $p]
}
set regs [all_registers]
set ins  [all_inputs]
set outs [all_outputs]
set fh [open [file join $RPT timing_split.txt] w]
puts $fh "# Worst slack (ns) by path class, post-route, clk = 8.000 ns (125 MHz)"
puts $fh [format "%-28s %10s %10s" "path class" "setup" "hold"]
set classes [list]
lappend classes "register -> register"      $regs $regs
lappend classes "input port -> register"    $ins  $regs
lappend classes "register -> output port"   $regs $outs
lappend classes "input port -> output port" $ins  $outs
foreach {name from to} $classes {
  puts $fh [format "%-28s %10s %10s" $name [worst setup $from $to] [worst hold $from $to]]
}
set bad [get_timing_paths -quiet -hold -slack_lesser_than 0 -max_paths 10000 -nworst 1]
set from_port 0
foreach p $bad { if {[get_property CLASS [get_property STARTPOINT_PIN $p]] eq "port"} { incr from_port } }
puts $fh "hold-violating endpoints: [llength $bad] (of which launched from an input port: $from_port)"
close $fh

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "RESULT: WNS=$wns ns  WHS=$whs ns  (clk 8.000 ns)"
