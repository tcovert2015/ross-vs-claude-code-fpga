#============================================================================
# build.tcl -- Lattice Radiant flow for the PCIe DMA engine (Certus-NX)
#
#   radiantc lattice/build.tcl          (from designs/dma, or any directory)
#
# Part LFD2NX-40-8BG256C, top pcie_dma_top (SYS_IF="AXI4", RESET_SYNC=1),
# Synplify Pro, clk = 125 MHz (lattice/pcie_dma.sdc).
#
# pcie_dma_top is an IP core with far more ports than the BG256 has user I/O.
# Like quartus/virtual_pins.tcl, the ports are left unpinned: map treats every
# port as a virtual I/O (map -vio) and strips the I/O buffers Synplify inserts.
# (Disabling I/O insertion in Synplify instead makes map fail: "Design is
# without any IO buffer".)
#
# Runs synthesis, map, PAR and static timing analysis in lattice/build/ and
# copies the reports to lattice/reports/.
#============================================================================
set here  [file dirname [file normalize [info script]]]
set root  [file dirname $here]
set bdir  $here/build
set rdir  $here/reports
set proj  pcie_dma
set impl  impl1

file delete -force $bdir
file mkdir $bdir
file mkdir $rdir
set reports {srr synthesis.srr mrp map.mrp par par.par twr timing.twr}
foreach {ext dst} $reports { file delete -force $rdir/$dst }
cd $bdir

prj_create -name $proj -impl $impl -dev LFD2NX-40-8BG256C \
    -performance "8_High-Performance_1.0V" -synthesis synplify

# package first, then core / adapters / top (same order as quartus/pcie_dma.qsf)
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
prj_add_source $here/pcie_dma.sdc
prj_add_source $here/pcie_dma.pdc

prj_set_impl_opt -impl $impl top pcie_dma_top
prj_set_impl_opt -impl $impl {include path} $root/rtl/pkg
prj_set_impl_opt -impl $impl HDL_PARAM {SYS_IF="AXI4";RESET_SYNC=1}

# 125 MHz target; no pads (virtual I/O on every port)
prj_set_strategy_value -strategy Strategy1 syn_frequency=125
prj_set_strategy_value -strategy Strategy1 map_set_virtual_io_all_ports=True
prj_save

prj_run_synthesis
prj_run_map
prj_run_par
prj_save
prj_close

# collect reports
set base $bdir/$impl/${proj}_$impl
set missing 0
foreach {ext dst} $reports {
    if {[file exists $base.$ext]} {
        file copy -force $base.$ext $rdir/$dst
        puts "report: lattice/reports/$dst"
    } else {
        puts "MISSING report: $base.$ext"
        set missing 1
    }
}
exit $missing
