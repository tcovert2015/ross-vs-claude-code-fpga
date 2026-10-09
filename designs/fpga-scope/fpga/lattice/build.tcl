# build.tcl — Radiant batch flow for scope_axil_top (synthesis -> map -> PAR -> STA).
#
#   radiantc build.tcl <PROBE_W> <DEPTH_LOG2>          (or pnmainc; run from any directory)
#
# Part LFD2NX-40-8BG256C, Synplify Pro, clk @ 100 MHz (scope.sdc). The project is created from
# scratch under fpga/lattice/build/<cfg>/ (git-ignored); the synthesis log, map report, PAR
# report and timing report are copied to fpga/lattice/reports/<cfg>/, cfg = w<PROBE_W>_d<DEPTH_LOG2>.

if {[llength $argv] != 2} {
  puts "usage: radiantc build.tcl <PROBE_W> <DEPTH_LOG2>"
  exit 2
}
lassign $argv PROBE_W DEPTH_LOG2

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set cfg  "w${PROBE_W}_d${DEPTH_LOG2}"
set proj scope
set impl impl_1
set bdir [file join $here build $cfg]
set rdir [file join $here reports $cfg]

file delete -force $bdir
file mkdir $bdir
file mkdir $rdir
cd $bdir

prj_create -name $proj -impl $impl -dev LFD2NX-40-8BG256C -performance 8_High-Performance_1.0V \
    -synthesis synplify

# package first, then primitives, core, front-end, top (same order as sim/run.sh)
foreach f {
  rtl/scope_pkg.sv
  rtl/prim/prim_ff_sync.sv
  rtl/prim/prim_ram_1r1w.sv
  rtl/prim/prim_fifo_sync.sv
  rtl/prim/prim_fifo_async.sv
  rtl/scope_core.sv
  rtl/scope_csr.sv
  rtl/scope_trigger.sv
  rtl/scope_rle.sv
  rtl/scope_drain.sv
  rtl/xport/scope_uart.sv
  rtl/scope_top.sv
  rtl/if/scope_axil.sv
  fpga/lattice/scope_axil_top.sv
} {
  prj_add_source [file join $root $f]
}
prj_add_source [file join $here scope.sdc]

prj_set_impl_opt -impl $impl top scope_axil_top
prj_set_impl_opt -impl $impl HDL_PARAM "PROBE_W=$PROBE_W;DEPTH_LOG2=$DEPTH_LOG2"
prj_save

prj_run_synthesis
prj_run_map
# the Place & Route milestone also runs the post-route static timing analysis
# (`timing -sethld ...` -> <impl>.twr, setup at both temperature corners + hold)
prj_run_par
prj_save

# collect the reports
set base [file join $bdir $impl ${proj}_${impl}]
foreach {src dst} [list \
    $base.srr      synthesis.srr \
    $base.mrp      map.mrp \
    $base.par      par.par \
    $base.twr      timing.twr] {
  if {[file exists $src]} {
    file copy -force $src [file join $rdir $dst]
  } else {
    puts "build.tcl: MISSING REPORT $src"
  }
}
prj_close
puts "build.tcl: $cfg done -> $rdir"
