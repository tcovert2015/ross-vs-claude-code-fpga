#============================================================================
# build.tcl -- Vivado non-project flow for the PCIe DMA engine (Artix-7)
#
#   vivado -mode batch -source vivado/build.tcl                  ;# 125 MHz
#   vivado -mode batch -source vivado/build.tcl -tclargs 5.000   ;# other period
#
# or, from an already running Vivado Tcl session started in designs/dma:
#
#   source vivado/build.tcl                      ;# 125 MHz
#   set ::dma_period 5.000; source vivado/build.tcl
#
# Builds pcie_dma_top (SYS_IF="AXI4", RESET_SYNC=1) out-of-context for
# xc7a100tcsg324-1: RTL lint, synthesis, opt/place/route, reports.
#
# Reports go to vivado/reports/ for the default 8.000 ns period and to
# vivado/reports/period_<ns>/ for any other period, so an Fmax exploration
# run never overwrites the 125 MHz sign-off reports.
#============================================================================

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]

set part   xc7a100tcsg324-1
set top    pcie_dma_top
set period 8.000
if {[info exists ::dma_period]} {
  set period $::dma_period
  unset ::dma_period
} elseif {[info exists ::argv] && [llength $::argv] > 0 && [string is double -strict [lindex $::argv 0]]} {
  set period [lindex $::argv 0]
}
set period [format %.3f $period]

if {$period eq "8.000"} {
  set rpt_dir [file join $script_dir reports]
} else {
  set rpt_dir [file join $script_dir reports period_$period]
}
file mkdir $rpt_dir

# same file list / order as quartus/pcie_dma.qsf (+ reset_sync for RESET_SYNC=1)
set rtl_files {
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
set generics [list -generic {SYS_IF="AXI4"} -generic RESET_SYNC=1]

# The committed XDC carries the 125 MHz period. For another period, write a
# copy with only the create_clock period rewritten and read that instead.
set xdc [file join $script_dir pcie_dma.xdc]
if {$period ne "8.000"} {
  set fh [open $xdc r]; set txt [read $fh]; close $fh
  if {[regsub -- {set clk_period 8\.000} $txt "set clk_period $period" txt] != 1} {
    error "build.tcl: could not rewrite the clock period in $xdc"
  }
  set xdc [file join $rpt_dir pcie_dma_period_$period.xdc]
  set fh [open $xdc w]; puts -nonewline $fh $txt; close $fh
}

# start from a clean in-memory project so the script is re-runnable in a session
catch {close_design}
catch {close_project}
foreach f $rtl_files {
  read_verilog -sv [list [file join $root_dir $f]]   ;# list: path may contain spaces
}
read_xdc [list $xdc]

#----------------------------------------------------------------------------
# 1. RTL lint
#
# The report path is passed RELATIVE to the design root on purpose. Vivado
# 2025.2 forwards the -file value unquoted to an internal rt::set_parameter
# call, so an absolute path containing a space (e.g. a checkout under
# "D:/AMD Ross Test/") makes the linter abort with
#   Detected extra character(s) "Ross"
# while synth_design still reports success and writes no report. Worse, the
# pending lint request then leaks into the next synth_design, which hands the
# linter netlist to synthesis: the dma_fifo memory is left as an unresolved
# "bboxRAM" black box and opt_design stops on DRC INBB-3. Hence the relative
# path, the report-exists check, and the black-box check after synthesis.
#----------------------------------------------------------------------------
cd $root_dir
if {$period eq "8.000"} {
  set lint_rpt vivado/reports/lint.rpt
} else {
  set lint_rpt vivado/reports/period_$period/lint.rpt
}
file delete -force $lint_rpt
synth_design -top $top -part $part {*}$generics -lint -file $lint_rpt
if {![file exists $lint_rpt] || [file size $lint_rpt] == 0} {
  error "build.tcl: synth_design -lint did not write $lint_rpt"
}

#----------------------------------------------------------------------------
# 2. Synthesis (out-of-context: no I/O buffers, like the Quartus virtual pins)
#
# PerformanceOptimized + retiming and the Explore-class implementation
# directives below are deliberate: the design does not meet 125 MHz on a -1
# Artix-7 with default settings either, and these gave the best slack.
#----------------------------------------------------------------------------
synth_design -top $top -part $part {*}$generics -mode out_of_context -directive PerformanceOptimized -retiming

# make sure the string generic really selected the AXI4 adapter + reset sync
foreach c {g_axi.u_adapt g_rst_sync.u_rst_sync} {
  if {[llength [get_cells -quiet -hierarchical -filter "NAME =~ *$c*"]] == 0} {
    error "build.tcl: expected hierarchy '$c' not found -- generics not applied?"
  }
}
set bbox [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $bbox] > 0} {
  error "build.tcl: synthesis left black-box cell(s): $bbox"
}
write_checkpoint -force [file join $rpt_dir post_synth.dcp]
report_utilization    -file [file join $rpt_dir utilization_synth.rpt]
report_timing_summary -file [file join $rpt_dir timing_summary_synth.rpt]

#----------------------------------------------------------------------------
# 3. Implementation
#----------------------------------------------------------------------------
opt_design        -directive Explore
place_design      -directive ExtraTimingOpt
phys_opt_design   -directive AggressiveExplore
route_design      -directive Explore
# No post-route phys_opt_design: with Vivado 2025.2 it crashed the tool
# (EXCEPTION_ACCESS_VIOLATION in "Phase 2 Critical Path Optimization") on the
# 8.500 ns run of this design.
write_checkpoint -force [file join $rpt_dir post_route.dcp]

#----------------------------------------------------------------------------
# 4. Reports
#----------------------------------------------------------------------------
report_utilization               -file [file join $rpt_dir utilization.rpt]
report_utilization -hierarchical -file [file join $rpt_dir utilization_hier.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $rpt_dir timing_summary.rpt]
report_timing -max_paths 5 -nworst 1 -delay_type max -file [file join $rpt_dir timing_worst_setup.rpt]
report_drc                       -file [file join $rpt_dir drc.rpt]
report_methodology               -file [file join $rpt_dir methodology.rpt]
report_route_status              -file [file join $rpt_dir route_status.rpt]

# one-screen summary, computed from the routed design
set sp  [get_timing_paths -max_paths 1 -nworst 1 -setup]
set hp  [get_timing_paths -max_paths 1 -nworst 1 -hold]
set wns [get_property SLACK $sp]
set whs [get_property SLACK $hp]
set tns 0.0
set ths 0.0
foreach p [get_timing_paths -max_paths 100000 -slack_lesser_than 0 -setup] {
  set tns [expr {$tns + [get_property SLACK $p]}]
}
foreach p [get_timing_paths -max_paths 100000 -slack_lesser_than 0 -hold] {
  set ths [expr {$ths + [get_property SLACK $p]}]
}
set min_period [expr {$period - $wns}]
set fh [open [file join $rpt_dir summary.txt] w]
puts $fh "part            : $part"
puts $fh "top             : $top (SYS_IF=AXI4, RESET_SYNC=1, out-of-context)"
puts $fh "vivado          : [version -short]"
puts $fh "clk period (ns) : $period ([format %.2f [expr {1000.0 / $period}]] MHz)"
puts $fh "WNS (ns)        : [format %.3f $wns]"
puts $fh "TNS (ns)        : [format %.3f $tns]   (sum over failing endpoints' worst paths)"
puts $fh "WHS (ns)        : [format %.3f $whs]"
puts $fh "THS (ns)        : [format %.3f $ths]"
puts $fh "period - WNS    : [format %.3f $min_period] ns -> [format %.2f [expr {1000.0 / $min_period}]] MHz (estimate from this run's slack)"
puts $fh "worst setup path: [get_property STARTPOINT_PIN $sp] -> [get_property ENDPOINT_PIN $sp] ([get_property LOGIC_LEVELS $sp] logic levels)"
close $fh

set fh [open [file join $rpt_dir summary.txt] r]; puts [read $fh]; close $fh
puts "build.tcl: done, reports in $rpt_dir"
