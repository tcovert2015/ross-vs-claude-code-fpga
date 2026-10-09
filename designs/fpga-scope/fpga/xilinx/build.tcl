# build.tcl — Vivado non-project, out-of-context build of scope_axil_top for Artix-7.
#
#   vivado -mode batch -source fpga/xilinx/build.tcl -tclargs <PROBE_W> <DEPTH_LOG2>
#
# Stages: RTL lint (synth_design -lint) -> synth (OOC) -> opt -> place -> phys_opt -> route.
# Reports land in fpga/xilinx/reports/pw<PROBE_W>_d<DEPTH_LOG2>/ :
#   lint.rpt, utilization.rpt (+ utilization_hier.rpt, utilization_synth.rpt),
#   timing_summary.rpt, drc.rpt, ram.rpt (how the capture buffer was mapped),
#   route_status.rpt, summary.txt. run_all.ps1 runs the three README configurations.
# Paths are derived from this script's location, so it can be launched from any directory.

set PART xc7a100tcsg324-1
set TOP  scope_axil_top

if {[llength $argv] != 2} {
  puts "usage: vivado -mode batch -source build.tcl -tclargs <PROBE_W> <DEPTH_LOG2>"
  exit 2
}
lassign $argv PROBE_W DEPTH_LOG2

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set rtl  [file join $root rtl]
set cfg  "pw${PROBE_W}_d${DEPTH_LOG2}"
set rpt  [file join $here reports $cfg]
file mkdir $rpt

# Source order mirrors sim/run.sh COMMON_SRCS: package first, then prims, then core RTL.
set srcs [list \
  $rtl/scope_pkg.sv \
  $rtl/prim/prim_ff_sync.sv \
  $rtl/prim/prim_ram_1r1w.sv \
  $rtl/prim/prim_fifo_sync.sv \
  $rtl/prim/prim_fifo_async.sv \
  $rtl/scope_core.sv \
  $rtl/scope_csr.sv \
  $rtl/scope_trigger.sv \
  $rtl/scope_rle.sv \
  $rtl/scope_drain.sv \
  $rtl/xport/scope_uart.sv \
  $rtl/scope_top.sv \
  $rtl/if/scope_axil.sv \
  $here/scope_axil_top.sv \
]

set_part $PART
read_verilog -sv $srcs
# (list-wrapped: read_xdc treats its argument as a Tcl list, so a path with spaces must be one element)
read_xdc -mode out_of_context [list [file join $here scope.xdc]]

set generics [list PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2]

# ---- 1. RTL lint ------------------------------------------------------------------------
# NOTE (Vivado 2025.2): `synth_design -lint -file <path>` silently produces NO report when the
# path contains a space, and leaves the linter armed so the NEXT synth_design black-boxes every
# inferred RAM. Run it from inside the report directory with a bare relative file name.
set cwd [pwd]
cd $rpt
synth_design -lint -top $TOP -part $PART -generic $generics -file lint.rpt
cd $cwd
if {![file exists [file join $rpt lint.rpt]]} { error "lint report was not written" }
file delete -force [file join $rpt retry_open_fs.log]   ;# stray Vivado scratch from the cd

# ---- 2. synthesis (out-of-context: no I/O buffers, ports stay as module pins) ------------
synth_design -top $TOP -part $PART -mode out_of_context -generic $generics
report_utilization -file [file join $rpt utilization_synth.rpt]

# ---- 3. implementation -------------------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design

# ---- 4. reports --------------------------------------------------------------------------
report_utilization                -file [file join $rpt utilization.rpt]
report_utilization -hierarchical  -file [file join $rpt utilization_hier.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $rpt timing_summary.rpt]
report_drc                        -file [file join $rpt drc.rpt]
report_ram_utilization            -file [file join $rpt ram.rpt]
report_route_status               -file [file join $rpt route_status.rpt]

# ---- 5. one-line machine-readable summary (same numbers as the reports above) ------------
proc cnt {filter} { return [llength [get_cells -hierarchical -quiet -filter $filter]] }
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fh [open [file join $rpt summary.txt] w]
puts $fh "cfg=$cfg part=$PART top=$TOP"
puts $fh "ramb36=[cnt {REF_NAME =~ RAMB36*}] ramb18=[cnt {REF_NAME =~ RAMB18*}]\
 lutram=[cnt {PRIMITIVE_SUBGROUP == LUTRAM || PRIMITIVE_SUBGROUP == dram}]"
puts $fh "wns_ns=$wns whs_ns=$whs"
close $fh

puts "BUILD_DONE $cfg wns=$wns whs=$whs"
