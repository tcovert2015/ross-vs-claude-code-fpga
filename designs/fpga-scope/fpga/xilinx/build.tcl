# build.tcl — Vivado non-project, out-of-context flow for scope_axil_top on Artix-7.
#
#   vivado -mode batch -source fpga/xilinx/build.tcl -tclargs <PROBE_W> <DEPTH_LOG2> [RLE_EN]
#
# or, from an already running Vivado Tcl session (any cwd):
#
#   set argv {32 12}; source fpga/xilinx/build.tcl
#
# Steps: RTL lint (synth_design -lint) -> synth_design (OOC) -> opt/place/route -> reports.
# Everything lands in fpga/xilinx/reports/w<PROBE_W>_d<DEPTH_LOG2>/ :
#   lint.rpt  utilization_synth.rpt  utilization.rpt  utilization_hier.rpt  ram_utilization.rpt
#   timing_summary.rpt  methodology.rpt  drc.rpt  summary.txt  scope_axil_top_routed.dcp
# RLE_EN defaults to 1 (buffer word = PROBE_W+1 bits), matching the README's Agilex 3 table.

set PART xc7a100tcsg324-1
set TOP  scope_axil_top

if {![info exists argv] || [llength $argv] < 2} {
  error "usage: build.tcl <PROBE_W> <DEPTH_LOG2> \[RLE_EN\]"
}
set PROBE_W    [lindex $argv 0]
set DEPTH_LOG2 [lindex $argv 1]
set RLE_EN     [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]

set xil_dir [file dirname [file normalize [info script]]]
set root    [file normalize [file join $xil_dir .. ..]]
set rtl     [file join $root rtl]
set cfg     "w${PROBE_W}_d${DEPTH_LOG2}"
set rpt     [file join $xil_dir reports $cfg]
file mkdir $rpt

puts "== build.tcl: $TOP  PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 RLE_EN=$RLE_EN  part=$PART -> $rpt"

# Same source order as sim/run.sh (package first), minus the Avalon/JTAG front-ends that this
# top does not use, plus the Vivado wrapper.
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
  $xil_dir/scope_axil_top.sv]

close_project -quiet
create_project -in_memory -part $PART
read_verilog -sv $srcs
read_xdc -mode out_of_context [list [file join $xil_dir scope.xdc]]  ;# list: path may contain spaces

set generics [list PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 RLE_EN=1'b$RLE_EN]

# ---- 1. RTL lint ------------------------------------------------------------------------
# NOTE: Vivado 2025.2 mis-parses a `-lint -file` path that contains a space (internal
# "rt::set_parameter ... Detected extra character(s)" abort that still reports success, writes
# no report, and leaves the NEXT synth_design in linter mode with black-boxed RAMs). So run
# the lint from inside the report directory with a bare, space-free file name.
set here [pwd]
cd $rpt
file delete -force lint.rpt
synth_design -top $TOP -part $PART -generic $generics -lint -file lint.rpt
cd $here
if {![file exists [file join $rpt lint.rpt]]} { error "lint report was not written" }
close_design -quiet

# ---- 2. synthesis (out-of-context: no I/O buffers) ----------------------------------------
synth_design -top $TOP -part $PART -generic $generics -mode out_of_context
report_utilization -file [file join $rpt utilization_synth.rpt]

# ---- 3. implementation ------------------------------------------------------------------
opt_design
place_design
route_design

# ---- 4. reports -------------------------------------------------------------------------
report_utilization                -file [file join $rpt utilization.rpt]
report_utilization -hierarchical  -file [file join $rpt utilization_hier.rpt]
report_ram_utilization            -file [file join $rpt ram_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $rpt timing_summary.rpt]
report_methodology                -file [file join $rpt methodology.rpt]
report_drc                        -file [file join $rpt drc.rpt]
write_checkpoint -force [file join $rpt ${TOP}_routed.dcp]

# ---- 5. one-line-per-metric summary (the numbers quoted in fpga/xilinx/README.md) ---------
proc ucount {filter} { return [llength [get_cells -quiet -hierarchical -filter $filter]] }
set lut    [ucount {PRIMITIVE_GROUP == LUT || PRIMITIVE_SUBGROUP == LUTRAM || PRIMITIVE_SUBGROUP == SRL}]
set lutram [ucount {PRIMITIVE_SUBGROUP == LUTRAM}]
set ff     [ucount {PRIMITIVE_GROUP == REGISTER || PRIMITIVE_GROUP == FLOP_LATCH}]
set ramb36 [ucount {REF_NAME =~ RAMB36*}]
set ramb18 [ucount {REF_NAME =~ RAMB18*}]
set buf_cells [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && NAME =~ *u_core/u_buf/*}]
set buf_refs  [lsort -unique [get_property REF_NAME $buf_cells]]
set buf_ramb  [llength [filter $buf_cells {REF_NAME =~ RAMB*}]]
set store_w [expr {$PROBE_W + $RLE_EN}]
set fh [open [file join $rpt summary.txt] w]
puts $fh "config            PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 RLE_EN=$RLE_EN part=$PART"
puts $fh "lut_cells         $lut"
puts $fh "lutram_cells      $lutram"
puts $fh "ff_cells          $ff"
puts $fh "ramb36_cells      $ramb36"
puts $fh "ramb18_cells      $ramb18"
puts $fh "buffer_bits       [expr {(1 << $DEPTH_LOG2) * $store_w}]"
puts $fh "u_buf_primitives  $buf_refs"
puts $fh "u_buf_ramb_cells  $buf_ramb"
puts $fh "wns_ns            [get_property SLACK [get_timing_paths -setup]]"
puts $fh "whs_ns            [get_property SLACK [get_timing_paths -hold]]"
close $fh
set fh [open [file join $rpt summary.txt] r]; puts [read $fh]; close $fh
puts "== build.tcl: done ($cfg)"
