# run_xsim.tcl — fpga-scope testbench regression on the AMD Vivado Simulator (xsim).
#
#   vivado -mode batch -source sim/run_xsim.tcl                    ;# all TBs below
#   vivado -mode batch -source sim/run_xsim.tcl -tclargs tb_csr    ;# a subset
#
# or from a running Vivado Tcl session:  set argv {}; source sim/run_xsim.tcl
#
# Mirrors sim/run.sh (same source order, same 1ns/1ps default timescale, same
# "TB_RESULT: PASS" contract) for the TBs relevant to the Vivado AXI4-Lite port:
#   tb_smoke     harness proof
#   tb_csr       native-bus CSR matrix + BUF_DATA drain vs scope_ref.py golden vectors
#   tb_csr_if    the same matrix through the Avalon-MM and AXI4-Lite front-ends
#   tb_axil_top  fpga/xilinx/scope_axil_top.sv end to end over AXI4-Lite
# Each TB is compiled (xvlog), elaborated (xelab) and run (xsim) in sim/build/xsim/; the
# three transcripts are concatenated into sim/xsim_<tb>.log. Exits/errors non-zero if any
# TB fails.
#
# tb_csr needs the two `capture` golden-vector sets from sim/model/scope_ref.py (stdlib-only
# Python 3; set env SCOPE_PYTHON to override the interpreter - not PYTHON, which Vivado
# itself sets to a directory). They are generated here with the
# exact arguments run.sh uses.

set sim_dir [file dirname [file normalize [info script]]]
set root    [file normalize [file join $sim_dir ..]]
set work    [file join $sim_dir build xsim]

set all_tbs {tb_smoke tb_csr tb_csr_if tb_axil_top}
set tbs $all_tbs
if {[info exists argv] && [llength $argv] > 0} { set tbs $argv }

# xsim tools live next to the running vivado
set bindir [file join $::env(XILINX_VIVADO) bin]
set ext    [expr {$::tcl_platform(platform) eq "windows" ? ".bat" : ""}]

# Run a tool, append its transcript to the open log, return 1 on a clean exit.
proc run_tool {log args} {
  set rc [catch {exec {*}$args 2>@1} out]
  puts $log $out
  if {$rc} { puts $log "run_xsim: '[file tail [lindex $args 0]]' exited non-zero" }
  return [expr {!$rc}]
}

file mkdir $work
set here [pwd]
# All tool invocations use paths RELATIVE to $work, so a checkout path containing spaces
# never reaches the xvlog/xelab/xsim command lines.
cd $work
set rtl ../../../rtl

# ---- golden vectors for tb_csr (same arguments as sim/run.sh gen_vectors) -----------------
# The TB $readmemh's "sim/build/vectors/..." relative to the simulator cwd ($work).
if {"tb_csr" in $tbs} {
  file mkdir sim/build/vectors
  set py [expr {[info exists ::env(SCOPE_PYTHON)] ? $::env(SCOPE_PYTHON) : ""}]
  if {$py eq ""} {
    foreach cand {python python3} {
      if {![catch {exec $cand --version 2>@1}]} { set py $cand; break }
    }
  }
  if {$py eq ""} { cd $here; error "run_xsim: no python interpreter found (set env SCOPE_PYTHON)" }
  puts "== generating golden vectors ($py sim/model/scope_ref.py)"
  exec $py ../../model/scope_ref.py capture --probe-w 32 --depth-log2 8 --pretrig 0 \
    --trig-sample 128 --count 640 --seed 0xC0FFEE01 \
    --out-prefix sim/build/vectors/cap_w32_d8 2>@1
  exec $py ../../model/scope_ref.py capture --probe-w 512 --depth-log2 10 --pretrig 0 \
    --trig-sample 512 --count 2560 --seed 0xC0FFEE02 \
    --out-prefix sim/build/vectors/cap_w512_d10 2>@1
}

# Same order as run.sh COMMON_SRCS (package first) + the Vivado wrapper.
set srcs [list \
  $rtl/scope_pkg.sv \
  $rtl/prim/prim_ff_sync.sv $rtl/prim/prim_ram_1r1w.sv \
  $rtl/prim/prim_fifo_sync.sv $rtl/prim/prim_fifo_async.sv \
  $rtl/scope_core.sv $rtl/scope_csr.sv $rtl/scope_trigger.sv $rtl/scope_rle.sv \
  $rtl/scope_drain.sv $rtl/xport/scope_uart.sv $rtl/scope_top.sv \
  $rtl/if/scope_avalon.sv $rtl/if/scope_axil.sv $rtl/if/scope_jtag.sv \
  ../../../fpga/xilinx/scope_axil_top.sv]

set results {}
foreach tb $tbs {
  puts "== xsim: $tb"
  set logf [file join $sim_dir xsim_$tb.log]
  set log [open $logf w]
  puts $log "==== xvlog ($tb) ===="
  set ok [run_tool $log $bindir/xvlog$ext -sv -work work_$tb -nolog {*}$srcs ../../$tb.sv]
  if {$ok} {
    # -timescale: RTL files carry no `timescale (repo convention; run.sh passes the same
    # 1ns/1ps default to Verilator)
    puts $log "==== xelab ($tb) ===="
    set ok [run_tool $log $bindir/xelab$ext work_$tb.$tb -s snap_$tb -timescale 1ns/1ps -nolog]
  }
  if {$ok} {
    puts $log "==== xsim ($tb) ===="
    set ok [run_tool $log $bindir/xsim$ext snap_$tb -runall -nolog]
  }
  close $log
  set fh [open $logf r]; set txt [read $fh]; close $fh
  set pass [expr {$ok && [string match "*TB_RESULT: PASS*" $txt]
                  && ![string match "*TB_RESULT: FAIL*" $txt]
                  && ![regexp -line {^(ERROR|Fatal|Error):} $txt]}]
  if {!$pass} {
    set log [open $logf a]; puts $log "TB_RESULT: FAIL ($tb did not pass under xsim)"; close $log
  }
  lappend results $tb [expr {$pass ? "PASS" : "FAIL"}]
  puts "   $tb: [expr {$pass ? "PASS" : "FAIL"}]  (log: sim/xsim_$tb.log)"
}
cd $here

set nfail 0
puts "=================================================================="
foreach {tb r} $results { puts [format "%-14s %s" $tb $r]; if {$r ne "PASS"} { incr nfail } }
if {$nfail == 0} {
  puts "ALL XSIM TESTBENCHES PASSED"
} else {
  error "run_xsim: $nfail testbench(es) FAILED"
}
