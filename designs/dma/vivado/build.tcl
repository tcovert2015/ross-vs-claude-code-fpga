#============================================================================
# build.tcl -- Vivado non-project flow for the PCIe DMA engine (Artix-7)
#
#   vivado -mode batch -source vivado/build.tcl
#   vivado -mode batch -source vivado/build.tcl -tclargs <clk_period_ns> <tag> <flow>
#
# Top pcie_dma_top, SYS_IF="AXI4", RESET_SYNC=1, part xc7a100tcsg324-1,
# out-of-context (no I/O buffers; the Quartus project uses virtual pins for the
# same reason). Steps: RTL lint -> synth -> opt/place/phys_opt/route -> reports.
#
# Reports go to vivado/reports/ (the default 8.0 ns / 125 MHz run). The optional
# arguments re-run the same flow at another clock period for an Fmax probe:
# the period in pcie_dma.xdc is substituted and reports go to
# vivado/reports/<tag>/ so the 125 MHz results are never overwritten.
# <flow> selects the implementation directives: "default" (tool defaults) or
# "explore" (timing-driven Explore directives + post-route phys_opt).
#============================================================================

set script_dir [file dirname [file normalize [info script]]]

set part   xc7a100tcsg324-1
set top    pcie_dma_top
set period 8.000
set tag    ""
if {[llength $argv] >= 1} { set period [format %.3f [lindex $argv 0]] }
if {[llength $argv] >= 2} { set tag [lindex $argv 1] }
set flow   default
if {[llength $argv] >= 3} { set flow [lindex $argv 2] }
if {$flow ni {default explore}} { error "unknown flow '$flow' (default|explore)" }
if {$period != 8.000 && $tag eq ""} { set tag "p[string map {. _} $period]" }

# Work from vivado/build/ and use relative paths from here on: several Vivado
# commands split absolute paths that contain spaces.
file mkdir [file join $script_dir build]
cd [file join $script_dir build]
set root_dir ../..
set rpt_dir  [expr {$tag eq "" ? "../reports" : "../reports/$tag"}]
set out_dir  [expr {$tag eq "" ? "." : $tag}]
file mkdir $rpt_dir
file mkdir $out_dir

# top-level parameters (same order used for lint and synthesis)
set generics [list SYS_IF=\"AXI4\" RESET_SYNC=1]

# ---- sources (package first) ----
set rtl {
  rtl/pkg/dma_pkg.sv
  rtl/core/dma_fifo.sv
  rtl/core/dma_arbiter.sv
  rtl/core/dma_csr.sv
  rtl/core/dma_descriptor_fetch.sv
  rtl/core/dma_data_mover.sv
  rtl/core/dma_engine_core.sv
  rtl/core/reset_sync.sv
  rtl/adapters/gmm_to_avalon.sv
  rtl/adapters/gmm_to_axi4.sv
  rtl/adapters/gmm_to_ahb.sv
  rtl/top/pcie_dma_top.sv
}
foreach f $rtl { read_verilog -sv [file join $root_dir $f] }

# ---- constraints (period substituted for Fmax probes) ----
set xdc ../pcie_dma.xdc
if {$period != 8.000} {
  set fh [open $xdc r]; set txt [read $fh]; close $fh
  if {![regsub -- {-period 8\.000} $txt "-period $period" txt]} {
    error "could not substitute clock period in $xdc"
  }
  set xdc [file join $out_dir pcie_dma_$tag.xdc]
  set fh [open $xdc w]; puts -nonewline $fh $txt; close $fh
}
read_xdc -mode out_of_context $xdc

# ---- 1. RTL lint ----
synth_design -lint -top $top -part $part -generic $generics \
             -include_dirs [file join $root_dir rtl pkg] \
             -file [file join $rpt_dir lint.rpt]

# ---- 2. synthesis (out-of-context) ----
synth_design -top $top -part $part -mode out_of_context -generic $generics \
             -include_dirs [file join $root_dir rtl pkg]
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization    -file [file join $rpt_dir utilization_synth.rpt]
report_timing_summary -file [file join $rpt_dir timing_summary_synth.rpt]

# ---- 3. implementation ----
if {$flow eq "explore"} {
  opt_design      -directive Explore
  place_design    -directive ExtraTimingOpt
  phys_opt_design -directive AggressiveExplore
  route_design    -directive AggressiveExplore
  phys_opt_design -directive AggressiveExplore
} else {
  opt_design
  place_design
  phys_opt_design
  route_design
}
write_checkpoint -force [file join $out_dir post_route.dcp]

# ---- 4. reports ----
report_utilization               -file [file join $rpt_dir utilization.rpt]
report_utilization -hierarchical -file [file join $rpt_dir utilization_hier.rpt]
report_timing_summary -max_paths 10 -report_unconstrained \
                                 -file [file join $rpt_dir timing_summary.rpt]
report_timing -setup -max_paths 5 -nworst 1 -file [file join $rpt_dir timing_worst_setup.rpt]
report_drc                       -file [file join $rpt_dir drc.rpt]
report_methodology               -file [file join $rpt_dir methodology.rpt]
report_route_status              -file [file join $rpt_dir route_status.rpt]

report_timing -hold  -max_paths 5 -nworst 1 -file [file join $rpt_dir timing_worst_hold.rpt]
check_timing                     -file [file join $rpt_dir check_timing.rpt]

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1]]
puts "BUILD_SUMMARY flow=$flow period=$period ns  WNS=$wns ns  WHS=$whs ns"
