#============================================================================
# build.tcl -- AMD Vivado non-project flow for the PCIe DMA engine
#
#   vivado -mode batch -source vivado/build.tcl
#   vivado -mode batch -source vivado/build.tcl -tclargs tag p9p50 period 9.5
#   (or the wrapper: vivado/build.bat [<key> <value> ...])
#
# Steps: RTL lint (synth_design -lint) -> synth (out-of-context) -> opt ->
# place -> phys_opt -> route, then utilization / timing_summary / drc reports
# in vivado/reports[/<tag>]/. Scratch output goes to vivado/build[/<tag>]/.
#
# Optional -tclargs (<key> <value> pairs):
#   tag <name>             report/scratch sub-directory (default: none)
#   period <ns>            clock period override (default 8.000 = 125 MHz)
#   sys_if <str>           AVALON | AXI4 | AHB (default AXI4)
#   lint 0|1               run the lint step (default 1)
#   synth_directive <d>    synth_design     -directive (default: Default)
#   opt_directive <d>      opt_design       -directive (default: Default)
#   place_directive <d>    place_design     -directive (default: Default)
#   physopt_directive <d>  phys_opt_design  -directive (default: Default)
#   route_directive <d>    route_design     -directive (default: Default)
#   post_route_physopt 0|1 extra phys_opt_design after routing (default 0)
#============================================================================

set script_dir [file dirname [file normalize [info script]]]
set root       [file dirname $script_dir]

set part       xc7a100tcsg324-1
set top        pcie_dma_top
set reset_sync 1

array set opt {
  tag                ""
  period             8.000
  sys_if             AXI4
  lint               1
  synth_directive    Default
  opt_directive      Default
  place_directive    Default
  physopt_directive  Default
  route_directive    Default
  post_route_physopt 0
}

# key/value pairs rather than key=value: cmd.exe (vivado.bat) splits
# arguments on '=', so "period=6.0" would not survive the Windows launcher.
if {[llength $argv] % 2} { error "build.tcl: -tclargs must be <key> <value> pairs" }
foreach {k v} $argv {
  if {![info exists opt($k)]} { error "build.tcl: unknown argument '$k'" }
  set opt($k) $v
}

set rpt_dir $script_dir/reports
set bld_dir $script_dir/build
if {$opt(tag) ne ""} {
  append rpt_dir /$opt(tag)
  append bld_dir /$opt(tag)
}
file mkdir $rpt_dir $bld_dir
# keep Vivado's own scratch files (.Xil, clockInfo.txt, ...) out of the tree
# and private to this run, so differently-tagged runs can execute in parallel
cd $bld_dir

# The committed XDC is fixed at 8.000 ns. For a period override, constrain
# from a scratch copy with only the create_clock period rewritten (XDC files
# cannot contain Tcl control flow, so the override cannot live in the file).
set xdc $script_dir/pcie_dma.xdc
if {$opt(period) != 8.000} {
  set fh [open $xdc r]; set txt [read $fh]; close $fh
  if {![regsub {create_clock -name clk -period [0-9.]+} $txt \
        "create_clock -name clk -period $opt(period)" txt]} {
    error "build.tcl: could not rewrite the clock period in $xdc"
  }
  set xdc $bld_dir/pcie_dma_period.xdc
  set fh [open $xdc w]; puts -nonewline $fh $txt; close $fh
}

# package first, same order as quartus/pcie_dma.qsf (+ reset_sync for RESET_SYNC=1)
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
# File arguments are Tcl lists: wrap each path with [list] so a checkout
# path containing spaces stays one element.
foreach f $rtl_files { read_verilog -sv [list $root/$f] }
read_xdc -mode out_of_context [list $xdc]

set generics [list "SYS_IF=\"$opt(sys_if)\"" "RESET_SYNC=$reset_sync"]
set incdir   [list $root/rtl/pkg]

# ---------------------------------------------------------------- RTL lint
if {$opt(lint)} {
  # The linter's -file must not contain spaces (Vivado 2025.2 mangles it,
  # silently skips the report and corrupts the following synth_design), so
  # write it via a path relative to the scratch directory we are in.
  set lint_rpt [expr {$opt(tag) eq "" ? "../reports" : "../../reports/$opt(tag)"}]/lint.rpt
  file delete $rpt_dir/lint.rpt
  synth_design -lint -top $top -part $part -generic $generics \
      -include_dirs $incdir -file $lint_rpt
  if {![file exists $rpt_dir/lint.rpt]} { error "build.tcl: lint report was not written" }
}

# ---------------------------------------------------------------- synthesis
synth_design -top $top -part $part -mode out_of_context -generic $generics \
    -include_dirs $incdir -directive $opt(synth_directive)
write_checkpoint -force $bld_dir/post_synth.dcp
report_utilization -file $rpt_dir/utilization_synth.rpt

# ---------------------------------------------------------------- implementation
opt_design      -directive $opt(opt_directive)
place_design    -directive $opt(place_directive)
phys_opt_design -directive $opt(physopt_directive)
route_design    -directive $opt(route_directive)
if {$opt(post_route_physopt)} {
  phys_opt_design -directive $opt(physopt_directive)
}
write_checkpoint -force $bld_dir/post_route.dcp

# ---------------------------------------------------------------- reports
report_utilization -file $rpt_dir/utilization.rpt
report_utilization -hierarchical -file $rpt_dir/utilization_hier.rpt
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
    -file $rpt_dir/timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by slack \
    -file $rpt_dir/timing_worst_setup.rpt
report_drc -file $rpt_dir/drc.rpt
report_route_status -file $rpt_dir/route_status.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "BUILD_RESULT tag=%s period=%.3f WNS=%.3f WHS=%.3f achieved_period=%.3f" \
    $opt(tag) $opt(period) $wns $whs [expr {$opt(period) - $wns}]]
