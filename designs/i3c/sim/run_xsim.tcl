# =============================================================================
# run_xsim.tcl  -  Compile + run the I3C Target behavioral testbench with
#                  Vivado xsim (xvlog / xelab / xsim).  xsim twin of sim/run.sh.
#
#   vivado -mode batch -source sim/run_xsim.tcl        (from any directory)
#   or, in an open Vivado Tcl session:  source sim/run_xsim.tcl
#
# Same file list as sim/run.sh, with rtl/xilinx/i3c_io_xilinx.sv in place of
# rtl/altera/i3c_io_altera.sv (selected by I3C_IO_CELL). The Xilinx wrapper
# instantiates IOBUF/IBUF, hence -L unisims_ver and glbl.
# Log: sim/xsim.log (compile/elab logs: sim/xvlog.log, sim/xelab.log).
# Fails (Tcl error) unless the testbench reports 29 passed, 0 failed.
#
# Cross-check: set the environment variable I3C_SIM_IO=altera to run the
# UNCHANGED sim/run.sh file list (default I3C_IO_CELL = i3c_io_altera) in xsim;
# that run logs to sim/xsim_altera_io.log.
# =============================================================================
set sim_dir  [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $sim_dir ..]]
set expected_checks 29

set io xilinx
if {[info exists ::env(I3C_SIM_IO)]} { set io $::env(I3C_SIM_IO) }
if {$io ni {xilinx altera}} { error "I3C_SIM_IO must be xilinx or altera" }

set rtl_files {
  rtl/i3c_pkg.sv rtl/i3c_sda_mux.sv rtl/i3c_bus_frontend.sv rtl/i3c_bit_engine.sv
  rtl/i3c_framer.sv rtl/i3c_hdr_exit_detector.sv rtl/i3c_fifo.sv rtl/i3c_protocol_fsm.sv
  rtl/i3c_daa.sv rtl/i3c_ccc.sv rtl/i3c_ibi.sv rtl/i3c_error_recovery.sv rtl/i3c_regfile.sv
  rtl/i3c_avalon_mm.sv
}

if {![info exists ::env(XILINX_VIVADO)]} { error "XILINX_VIVADO is not set (run from Vivado or source settings64)" }
set vbin [file join $::env(XILINX_VIVADO) bin]
set ext  [expr {$::tcl_platform(platform) eq "windows" ? ".bat" : ""}]

if {$io eq "xilinx"} {
  lappend rtl_files rtl/xilinx/i3c_io_xilinx.sv rtl/i3c_target_top.sv sim/tb_i3c_target.sv \
    [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
  set vlog_opts  "-sv -i rtl -d I3C_IO_CELL=i3c_io_xilinx"
  set elab_tops  {tb_i3c_target glbl -L unisims_ver}
  set snapshot   tb_i3c_xsim
  set log        sim/xsim.log
} else {
  lappend rtl_files rtl/altera/i3c_io_altera.sv rtl/i3c_target_top.sv sim/tb_i3c_target.sv
  set vlog_opts  "-sv -i rtl"
  set elab_tops  {tb_i3c_target}
  set snapshot   tb_i3c_xsim_altera_io
  set log        sim/xsim_altera_io.log
}

# Run one tool, echo its output, and stop on a non-zero exit status.
proc run_tool {args} {
  puts "+ $args"
  set rc [catch {exec {*}$args 2>@1} out opts]
  puts $out
  if {$rc && [lindex [dict get $opts -errorcode] 0] ne "NONE"} {
    error "[file tail [lindex $args 0]] failed"
  }
}

# Run from the design root with relative paths: the testbench writes
# sim/tb_i3c_target.vcd relative to the cwd, and it keeps paths free of spaces.
set old_pwd [pwd]
cd $repo_dir
file delete -force $log
set rc [catch {
  # Options go through an -f file: on Windows xvlog is a .bat and cmd.exe would
  # split the NAME=VALUE define at the '='.
  set fh [open sim/xvlog.f w]
  puts $fh $vlog_opts
  foreach f $rtl_files { puts $fh $f }
  close $fh
  run_tool [file join $vbin xvlog$ext] -f sim/xvlog.f -log sim/xvlog.log
  run_tool [file join $vbin xelab$ext] {*}$elab_tops \
    -timescale 1ns/1ps -s $snapshot -log sim/xelab.log
  run_tool [file join $vbin xsim$ext] $snapshot -R -log $log
} msg]
cd $old_pwd
if {$rc} { error $msg }

set fh [open [file join $repo_dir $log] r]; set txt [read $fh]; close $fh
if {![regexp {RESULT: (\d+) passed, (\d+) failed} $txt -> npass nfail]} {
  error "XSIM FAIL: no RESULT line in $log"
}
if {$nfail != 0 || $npass != $expected_checks || ![string match "*ALL TESTS PASSED*" $txt]} {
  error "XSIM FAIL: $npass passed, $nfail failed (expected $expected_checks / 0)"
}
puts "XSIM PASS ($io IO cell): $npass passed, $nfail failed -> $log"
