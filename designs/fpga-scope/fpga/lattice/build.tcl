# build.tcl — Lattice Radiant flow for scope_axil_top on Certus-NX (LFD2NX-40-8BG256C).
#
# Synplify Pro synthesis -> map -> PAR -> static timing, one configuration per invocation.
# Run from anywhere with the Radiant Tcl console (see README.md):
#
#   radiantc.exe fpga/lattice/build.tcl <PROBE_W> <DEPTH_LOG2>
#
# The project is built in fpga/lattice/build/<cfg>/ (scratch, git-ignored) and the synthesis
# log, map report, PAR report and timing reports are copied to fpga/lattice/reports/<cfg>/,
# where <cfg> = w<PROBE_W>_d<DEPTH_LOG2>.

if {[llength $argv] < 2} {
  puts "usage: radiantc build.tcl <PROBE_W> <DEPTH_LOG2>"
  exit 2
}
set PROBE_W    [lindex $argv 0]
set DEPTH_LOG2 [lindex $argv 1]

set DEVICE "LFD2NX-40-8BG256C"
set TOP    "scope_axil_top"
set IMPL   "impl_1"
set CFG    "w${PROBE_W}_d${DEPTH_LOG2}"

set HERE  [file dirname [file normalize [info script]]]
set RTL   [file normalize [file join $HERE .. .. rtl]]
set BUILD [file join $HERE build $CFG]
set RPT   [file join $HERE reports $CFG]

puts "== fpga-scope Radiant build: $TOP PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 on $DEVICE"

file delete -force $BUILD
file mkdir $BUILD
cd $BUILD

prj_create -name "scope_$CFG" -impl $IMPL -dev $DEVICE -performance "8_High-Performance_1.0V" \
    -synthesis "synplify"

# Source order: package first, then primitives, core, CSR front-end, top (as sim/run.sh).
foreach f {
  scope_pkg.sv
  prim/prim_ff_sync.sv
  prim/prim_ram_1r1w.sv
  prim/prim_fifo_sync.sv
  prim/prim_fifo_async.sv
  scope_core.sv
  scope_csr.sv
  scope_trigger.sv
  scope_rle.sv
  scope_drain.sv
  xport/scope_uart.sv
  scope_top.sv
  if/scope_axil.sv
} {
  prj_add_source [file join $RTL $f]
}
prj_add_source [file join $HERE scope_axil_top.sv]
prj_add_source [file join $HERE scope.sdc]

prj_set_impl_opt -impl $IMPL "top" $TOP
prj_set_impl_opt -impl $IMPL "HDL_PARAM" "PROBE_W=$PROBE_W;DEPTH_LOG2=$DEPTH_LOG2"
prj_set_strategy_value -strategy Strategy1 syn_frequency=100
prj_save

prj_run Synthesis -impl $IMPL
prj_run Map       -impl $IMPL
prj_run PAR       -impl $IMPL
prj_save
prj_close

# ---- collect reports -----------------------------------------------------------------------
file mkdir $RPT
set idir [file join $BUILD $IMPL]
set base "scope_${CFG}_${IMPL}"
# synthesis log (.srr), map report (.mrp), PAR report (.par), post-PAR timing (.twr), plus
# the Synplify resource-usage report and the pad report for reference.
set missing 0
foreach {src dst required} [list \
    "$base.srr"                  synthesis.srr      1 \
    "$base.mrp"                  map.mrp            1 \
    "$base.par"                  par.par            1 \
    "$base.twr"                  timing_par.twr     1 \
    "$base.pad"                  pad.pad            0 \
    "synlog/report/${base}_fpga_mapper_resourceusage.rpt" synthesis_resources.rpt 0 ] {
  set p [file join $idir $src]
  if {[file exists $p]} {
    file copy -force $p [file join $RPT $dst]
  } elseif {$required} {
    puts "ERROR: expected report missing: $p"
    set missing 1
  }
}
if {$missing} { exit 1 }
puts "== reports in $RPT"
exit 0
