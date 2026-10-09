# build.tcl — Vivado non-project flow for scope_axil_top on Artix-7 (out-of-context).
#
#   vivado -mode batch -source fpga/xilinx/build.tcl -tclargs <PROBE_W> <DEPTH_LOG2> [RLE_EN]
#
# Steps: RTL lint (synth_design -lint) -> synth (OOC) -> opt -> place -> phys_opt -> route,
# writing every report to fpga/xilinx/reports/w<PROBE_W>_d<DEPTH_LOG2>/ :
#   lint.rpt               RTL linter findings
#   utilization_synth.rpt  post-synthesis utilization
#   utilization.rpt        post-route utilization (flat)
#   utilization_hier.rpt   post-route utilization per hierarchy level
#   ram_utilization.rpt    how each inferred memory mapped (BRAM vs distributed RAM)
#   timing_summary.rpt     post-route timing summary @ scope.xdc (100 MHz)
#   drc.rpt                post-route DRC
#   summary.txt            key numbers scraped from the reports above (one "key = value" a line)
# Scratch (checkpoint, journal) goes to fpga/xilinx/build/ (git-ignored).
# RLE_EN defaults to 1 (STORE_W = PROBE_W+1), matching the README "Logic usage" table.

set PART xc7a100tcsg324-1
set TOP  scope_axil_top

if {[llength $argv] < 2} {
  puts "usage: vivado -mode batch -source build.tcl -tclargs <PROBE_W> <DEPTH_LOG2> \[RLE_EN\]"
  exit 2
}
set PROBE_W    [lindex $argv 0]
set DEPTH_LOG2 [lindex $argv 1]
set RLE_EN     [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]
set CFG        "w${PROBE_W}_d${DEPTH_LOG2}"

set XDIR [file dirname [file normalize [info script]]]
set ROOT [file normalize [file join $XDIR .. ..]]
set RPT  [file join $XDIR reports $CFG]
set BLD  [file join $XDIR build $CFG]
file mkdir $RPT
file mkdir $BLD
cd $BLD   ;# all Vivado scratch (.Xil, the lint report before it is copied) lands here

puts "== build.tcl: $TOP  part=$PART  PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 RLE_EN=$RLE_EN"

# Same compile order as sim/run.sh (package first). scope_avalon/scope_jtag/scope_uart and the
# FIFO primitives are read so the source set is the real one; with XPORT="CSR" only the
# modules actually instantiated are elaborated.
set SRCS {
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
  fpga/xilinx/scope_axil_top.sv
}
# ([list ...]: read_verilog/read_xdc take a file LIST, so a checkout path with spaces must be
#  wrapped or it is split into several bogus file names)
foreach f $SRCS { read_verilog -sv [list [file join $ROOT $f]] }
read_xdc -mode out_of_context [list [file join $XDIR scope.xdc]]

set GENERICS [list -generic PROBE_W=$PROBE_W -generic DEPTH_LOG2=$DEPTH_LOG2 \
                   -generic RLE_EN=1'b$RLE_EN]

# ---- 1. RTL lint ----------------------------------------------------------------------------
# The linter's -file must be a space-free path: with an absolute path containing spaces
# Vivado 2025.2 prints "Detected extra character(s)" from an internal rt::set_parameter, and
# the NEXT synth_design in the session then leaves every inferred RAM as an unresolved
# "bboxRAM" black box (opt_design fails with DRC INBB-3). So: lint to a relative name in the
# scratch dir (the cwd), then copy the report into place.
synth_design -top $TOP -part $PART {*}$GENERICS -lint -file lint.rpt
file copy -force lint.rpt [file join $RPT lint.rpt]

# ---- 2. synthesis (out-of-context: no I/O buffers) -------------------------------------------
# Retry: on Windows the linter's helper process can still hold .Xil/.../realtime for a moment,
# and synth_design then aborts with "[Designutils 20-411] ... could not be deleted and may be
# locked". Nothing is wrong with the design; wait and run it again.
for {set try 1} {1} {incr try} {
  if {![catch {synth_design -top $TOP -part $PART {*}$GENERICS -mode out_of_context} msg]} break
  if {$try >= 3 || ![string match "*could not be deleted*" $msg]} { error $msg }
  puts "== build.tcl: synth_design hit a locked scratch dir, retry $try"
  after 5000
}
report_utilization -file [file join $RPT utilization_synth.rpt]

# ---- 3. implementation -----------------------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design

# ---- 4. reports ------------------------------------------------------------------------------
report_utilization                -file [file join $RPT utilization.rpt]
report_utilization -hierarchical  -file [file join $RPT utilization_hier.rpt]
report_ram_utilization            -file [file join $RPT ram_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
                                  -file [file join $RPT timing_summary.rpt]
report_drc                        -file [file join $RPT drc.rpt]
write_checkpoint -force [file join $BLD post_route.dcp]

# ---- 5. summary.txt (scraped from the reports just written; nothing computed elsewhere) -------
proc slurp {f} { set fh [open $f r]; set d [read $fh]; close $fh; return $d }
proc util_row {txt name} {
  # first "| <name> | <used> |" row of a report_utilization table
  if {[regexp -line "^\\|\\s*[string map {* \\* / \\/ ( \\( ) \\)} $name]\\*?\\s*\\|\\s*(\[0-9.\]+)\\s*\\|" $txt -> v]} { return $v }
  return "n/a"
}
set u [slurp [file join $RPT utilization.rpt]]
set t [slurp [file join $RPT timing_summary.rpt]]
set l [slurp [file join $RPT lint.rpt]]
set d [slurp [file join $RPT drc.rpt]]

# Design Timing Summary: first numeric row after the WNS(ns) header
set wns n/a; set tns n/a; set tnsf n/a; set whs n/a; set ths n/a
regexp {WNS\(ns\)\s+TNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+(\d+)\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)} \
    $t -> wns tns tnsf whs ths

# memory primitives straight from the routed netlist
set bram_cells [get_cells -quiet -hierarchical -filter {PRIMITIVE_GROUP == BMEM || PRIMITIVE_GROUP == BLOCKRAM}]
set dram_cells [get_cells -quiet -hierarchical -filter {PRIMITIVE_GROUP == DMEM || PRIMITIVE_GROUP == LUTRAM}]
set buf_cells  [get_cells -quiet -hierarchical -filter {NAME =~ *u_buf* && (PRIMITIVE_GROUP == BMEM || PRIMITIVE_GROUP == BLOCKRAM)}]
set buf36 0; set buf18 0
foreach c $buf_cells {
  if {[string match RAMB36* [get_property REF_NAME $c]]} { incr buf36 } else { incr buf18 }
}
set buf_dram [get_cells -quiet -hierarchical -filter {NAME =~ *u_buf* && (PRIMITIVE_GROUP == DMEM || PRIMITIVE_GROUP == LUTRAM)}]

set STORE_W [expr {$PROBE_W + $RLE_EN}]
set fh [open [file join $RPT summary.txt] w]
puts $fh "config                 = $CFG (PROBE_W=$PROBE_W DEPTH_LOG2=$DEPTH_LOG2 RLE_EN=$RLE_EN)"
puts $fh "part                   = $PART"
puts $fh "vivado                 = [version -short]"
puts $fh "slice_luts             = [util_row $u {Slice LUTs}]"
puts $fh "lut_as_logic           = [util_row $u {LUT as Logic}]"
puts $fh "lut_as_memory          = [util_row $u {LUT as Memory}]"
puts $fh "slice_registers        = [util_row $u {Slice Registers}]"
puts $fh "ramb36                 = [util_row $u {RAMB36/FIFO}]"
puts $fh "ramb18                 = [util_row $u {RAMB18}]"
puts $fh "block_ram_tile         = [util_row $u {Block RAM Tile}]"
puts $fh "bram_cells_total       = [llength $bram_cells]"
puts $fh "dist_ram_cells_total   = [llength $dram_cells]"
puts $fh "capture_buf_ramb36     = $buf36"
puts $fh "capture_buf_ramb18     = $buf18"
puts $fh "capture_buf_dist_ram   = [llength $buf_dram]"
puts $fh "capture_buf_bits       = [expr {(1 << $DEPTH_LOG2) * $STORE_W}] (2^$DEPTH_LOG2 x $STORE_W)"
puts $fh "wns_ns                 = $wns"
puts $fh "tns_ns                 = $tns"
puts $fh "tns_failing_endpoints  = $tnsf"
puts $fh "whs_ns                 = $whs"
puts $fh "ths_ns                 = $ths"
# linter summary table rows: | RULE-n | SEVERITY | # Violations | # Waived | ...
array set lintn {{CRITICAL WARNING} 0 WARNING 0 INFO 0}
set lint_rules {}
foreach line [split $l \n] {
  if {[regexp {^\|\s*([A-Z]+-\d+)\s*\|\s*([A-Z ]+?)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|} $line -> rule sev n]} {
    if {![info exists lintn($sev)]} { set lintn($sev) 0 }
    incr lintn($sev) $n
    lappend lint_rules "$rule=$n"
  }
}
puts $fh "lint_critical_warning  = $lintn(CRITICAL WARNING)"
puts $fh "lint_warning           = $lintn(WARNING)"
puts $fh "lint_info              = $lintn(INFO)"
puts $fh "lint_rules             = [join $lint_rules { }]"
# DRC summary table rows: | RULE-n | Severity | Description | Checks |
set drcn n/a
regexp {Checks found:\s*(\d+)} $d -> drcn
set drc_rules {}
foreach line [split $d \n] {
  if {[regexp {^\|\s*([A-Z]+-\d+)\s*\|\s*([A-Za-z ]+?)\s*\|.*\|\s*(\d+)\s*\|\s*$} $line -> rule sev n]} {
    lappend drc_rules "${rule}(${sev})=$n"
  }
}
puts $fh "drc_checks_found       = $drcn"
puts $fh "drc_rules              = [join $drc_rules { }]"
close $fh
puts [slurp [file join $RPT summary.txt]]
puts "== build.tcl: $CFG done"
