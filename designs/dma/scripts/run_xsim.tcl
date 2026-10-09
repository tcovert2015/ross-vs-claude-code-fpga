#============================================================================
# run_xsim.tcl -- Vivado xsim regression of the self-checking testbench for
# the AXI4 system-bus option, with and without bus back-pressure. The xsim
# counterpart of scripts/run_sim.sh (Icarus) for the two AXI4 configurations.
#
#   vivado -mode batch -source scripts/run_xsim.tcl                  ;# seeds 1 2 3
#   vivado -mode batch -source scripts/run_xsim.tcl -tclargs 1 2 3 4 ;# custom seeds
#
# or, from a running Vivado Tcl session:   source scripts/run_xsim.tcl
# (custom seeds there:  set ::dma_seeds {1 2 3 4}; source scripts/run_xsim.tcl)
#
# Each configuration is compiled and elaborated once; the snapshot is then run
# under every seed (passed via the +SEED plusarg, as in run_sim.sh). Pass
# criterion is the one run_sim.sh uses: the run's output contains "=== PASS".
# Logs: sim/build/xsim_<cfg>_seed<n>.log (+ xsim_<cfg>_compile.log /
# _elab.log), summary in sim/build/xsim_summary.txt. The script raises a Tcl
# error (non-zero exit in batch mode) if any (config, seed) fails.
#============================================================================

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]

set seeds {1 2 3}
if {[info exists ::dma_seeds]} {
  set seeds $::dma_seeds
  unset ::dma_seeds
} elseif {[info exists ::env(SIM_SEEDS)] && [llength $::env(SIM_SEEDS)] > 0} {
  set seeds $::env(SIM_SEEDS)
} elseif {[info exists ::argv] && [llength $::argv] > 0} {
  set seeds $::argv
}

# same file list / order as scripts/run_sim.sh
set src_files {
  rtl/pkg/dma_pkg.sv
  rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv rtl/core/dma_csr.sv
  rtl/core/dma_descriptor_fetch.sv rtl/core/dma_data_mover.sv rtl/core/dma_engine_core.sv
  rtl/core/reset_sync.sv
  rtl/adapters/gmm_to_avalon.sv rtl/adapters/gmm_to_axi4.sv rtl/adapters/gmm_to_ahb.sv
  rtl/top/pcie_dma_top.sv
  sim/models/avalon_mem_model.sv sim/models/axi_mem_model.sv sim/models/ahb_mem_model.sv
  sim/tb_pcie_dma.sv
}

# name -> +define list   (run_sim.sh: "AXI4" = USE_AXI, "AXI4 +stalls" = USE_AXI STALLS)
set configs {
  axi4        {USE_AXI}
  axi4_stalls {USE_AXI STALLS}
}

# Run one xsim tool with all output captured to $log; returns 1 on success.
# Every path handed to the tools is relative to the per-config work directory,
# so a checkout path containing spaces is never passed on a command line.
proc run_tool {log args} {
  set failed [catch {exec {*}$args > $log 2>@1} msg]
  if {$failed} {
    set fh [open $log a]; puts $fh "run_xsim.tcl: [lindex $args 0] failed: $msg"; close $fh
  }
  return [expr {!$failed}]
}

proc file_has {path pattern} {
  if {![file exists $path]} { return 0 }
  set fh [open $path r]; set txt [read $fh]; close $fh
  return [expr {[string first $pattern $txt] >= 0}]
}

set build_dir [file join $root_dir sim build]
file mkdir $build_dir
set start_dir [pwd]
set results {}
set rc 0

foreach {cfg defs} $configs {
  # private work dir per configuration: sim/build/xsim_<cfg>/  (root is ../../..)
  set work [file join $build_dir xsim_$cfg]
  file delete -force $work
  file mkdir $work
  cd $work

  set cmd [list xvlog -sv -i ../../../rtl/pkg]
  foreach d $defs { lappend cmd -d $d }
  foreach f $src_files { lappend cmd ../../../$f }
  set ok [run_tool ../xsim_${cfg}_compile.log {*}$cmd]
  if {$ok} {
    # RTL files carry no `timescale; give them the testbench's 1ns/1ps
    set ok [run_tool ../xsim_${cfg}_elab.log \
              xelab -timescale 1ns/1ps tb_pcie_dma -s tb_$cfg]
  }
  if {!$ok} {
    puts "$cfg: COMPILE FAIL (see sim/build/xsim_${cfg}_compile.log / _elab.log)"
    lappend results "$cfg: COMPILE FAIL"
    set rc 1
    cd $start_dir
    continue
  }

  foreach s $seeds {
    set log ../xsim_${cfg}_seed$s.log
    file delete -force $log
    # xsim writes the transcript itself (-log); its stdout copy is discarded
    run_tool xsim_seed$s.stdout xsim tb_$cfg -R -testplusarg SEED=$s -log $log
    if {[file_has $log "=== PASS"]} {
      puts "$cfg seed=$s: PASS"
      lappend results "$cfg seed=$s: PASS"
    } else {
      puts "$cfg seed=$s: FAIL (see sim/build/xsim_${cfg}_seed$s.log)"
      lappend results "$cfg seed=$s: FAIL"
      set rc 1
    }
  }
  cd $start_dir
}
cd $start_dir

set fh [open [file join $build_dir xsim_summary.txt] w]
foreach r $results { puts $fh $r }
close $fh

if {$rc} {
  error "run_xsim.tcl: xsim regression FAILED"
}
puts "run_xsim.tcl: all [llength $results] xsim runs PASS"
