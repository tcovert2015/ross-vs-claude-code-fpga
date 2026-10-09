#============================================================================
# build.tcl -- Lattice Radiant flow for the PCIe DMA engine (Certus-NX)
#
#   device : LFD2NX-40-8BG256C          top : pcie_dma_top
#   params : SYS_IF="AXI4", RESET_SYNC=1 synthesis : Synplify Pro
#   clock  : clk, 125 MHz (lattice/pcie_dma.sdc)
#
# Runs synthesis -> map (+ map timing) -> place & route (+ PAR timing) and
# copies the synthesis log (synthesis.srr), map report (map.mrp), PAR report
# (par.par) and the post-map / post-route timing reports (timing_map.tw1,
# timing_par.twr) to lattice/reports/. Scratch output goes to lattice/build/.
#
#   cd lattice
#   D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe build.tcl
#
# pcie_dma_top is an IP core, not a pinned-out top: it has far more ports than
# the BG256 package has pins. The Quartus project handles this with VIRTUAL_PIN
# assignments (quartus/virtual_pins.tcl); the Radiant equivalent used here is
# the MAP strategy option "Set Virtual I/O on all ports", so no pin locations
# (and no .pdc) are needed.
#============================================================================
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
# Constraint file: pcie_dma.sdc by default. Set the environment variable
# DMA_SDC=pcie_dma_iodelay.sdc to build the set_input_delay/set_output_delay
# variant instead; it uses its own build and report directories.
set sdc pcie_dma.sdc
set tag ""
if {[info exists ::env(DMA_SDC)] && $::env(DMA_SDC) ne "" && $::env(DMA_SDC) ne "pcie_dma.sdc"} {
  set sdc $::env(DMA_SDC)
  set tag [regsub {^pcie_dma_} [file rootname [file tail $sdc]] ""]
}
if {$tag eq ""} {
  set bdir $here/build
  set rdir $here/reports
} else {
  set bdir $here/build_$tag
  set rdir $here/reports/$tag
}
set impl impl_1

file delete -force $bdir
file mkdir $bdir
file mkdir $rdir

prj_create -name pcie_dma -dir $bdir -impl $impl \
           -dev LFD2NX-40-8BG256C -performance "8_High-Performance_1.0V" \
           -synthesis synplify

# package first, then core, adapters, top (same order as quartus/pcie_dma.qsf)
foreach f {
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
} {
  prj_add_source $root/$f
}
prj_add_source $here/$sdc

prj_set_top_module pcie_dma_top
prj_set_impl_opt -impl $impl {include path} [list $root/rtl/pkg]
# top-level parameter overrides
prj_set_impl_opt -impl $impl HDL_PARAM {SYS_IF="AXI4";RESET_SYNC=1}

foreach kv {
  syn_frequency=125
  map_set_virtual_io_all_ports=True
  maptrce_endpoint_number=100
  maptrce_paths_per_clock=20
  partrce_endpoint_number=100
  partrce_paths_per_clock=20
} {
  prj_set_strategy_value $kv
}

prj_save

prj_run_synthesis
prj_run_map
prj_run Map -task MapTrace   ;# post-map (pre-placement) timing estimate -> .tw1
prj_run_par                  ;# place & route + post-route timing analysis -> .twr
prj_save
prj_close

# ---- collect reports ----
set p $bdir/$impl/pcie_dma_$impl
foreach {src dst} {
  .srr  synthesis.srr
  .mrp  map.mrp
  .par  par.par
  .tw1  timing_map.tw1
  .twr  timing_par.twr
} {
  set src $p$src
  if {[file exists $src]} {
    file copy -force $src $rdir/$dst
    puts "report: $rdir/$dst"
  } else {
    puts "MISSING report: $src"
  }
}
