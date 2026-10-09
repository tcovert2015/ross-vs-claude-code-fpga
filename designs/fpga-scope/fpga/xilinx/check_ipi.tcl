# check_ipi.tcl - prove Vivado IP Integrator infers the AXI4-Lite interface of the wrapper.
#
#   cd fpga/xilinx/build/ipi
#   vivado -mode batch -source ../../check_ipi.tcl > ../../reports/ipi_check.log
#
# Creates a throw-away project in the current directory, adds the RTL, drops scope_axil_bd
# (the Verilog shim around scope_axil_top: IPI rejects a SystemVerilog file as the top of an
# RTL module reference) into a block design and prints what IPI inferred. Exits 1 unless there
# is an AXI4-Lite slave interface `s_axi`, associated with `clk`, reset by active-low `aresetn`.
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize [file join $here .. .. rtl]]
# on-disk scratch project in the current directory (module references need automatic
# compile order, which an in-memory project does not have)
create_project -force ipi_check ./ipi_prj -part xc7a100tcsg324-1
add_files -norecurse [list \
  $rtl/scope_pkg.sv $rtl/prim/prim_ff_sync.sv $rtl/prim/prim_ram_1r1w.sv \
  $rtl/prim/prim_fifo_sync.sv $rtl/prim/prim_fifo_async.sv $rtl/scope_core.sv \
  $rtl/scope_csr.sv $rtl/scope_trigger.sv $rtl/scope_rle.sv $rtl/scope_drain.sv \
  $rtl/xport/scope_uart.sv $rtl/scope_top.sv $rtl/if/scope_axil.sv $here/scope_axil_top.sv $here/scope_axil_bd.v]
update_compile_order -fileset sources_1
create_bd_design ipi_check
set c [create_bd_cell -type module -reference scope_axil_bd scope_0]
set ok 1
foreach i [get_bd_intf_pins -of_objects $c] {
  puts "IPI_INTF [get_property NAME $i] vlnv=[get_property VLNV $i] mode=[get_property MODE $i]\
 protocol=[get_property CONFIG.PROTOCOL $i] addr_w=[get_property CONFIG.ADDR_WIDTH $i]\
 data_w=[get_property CONFIG.DATA_WIDTH $i]"
}
foreach p [get_bd_pins -of_objects $c] {
  puts "IPI_PIN  [get_property NAME $p] dir=[get_property DIR $p] type=[get_property TYPE $p]"
}
set s [get_bd_intf_pins -quiet scope_0/s_axi]
if {[llength $s] != 1} { set ok 0 } else {
  if {[get_property MODE $s] ne "Slave"} { set ok 0 }
  if {[get_property CONFIG.PROTOCOL $s] ne "AXI4LITE"} { set ok 0 }
}
puts "IPI_CLK  ASSOCIATED_BUSIF=[get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins scope_0/clk]]\
 ASSOCIATED_RESET=[get_property CONFIG.ASSOCIATED_RESET [get_bd_pins scope_0/clk]]"
puts "IPI_RST  POLARITY=[get_property CONFIG.POLARITY [get_bd_pins scope_0/aresetn]]"
if {[get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins scope_0/clk]] ne "s_axi"} { set ok 0 }
if {[get_property CONFIG.POLARITY [get_bd_pins scope_0/aresetn]] ne "ACTIVE_LOW"} { set ok 0 }
puts "IPI_PARAMS PROBE_W=[get_property CONFIG.PROBE_W $c] DEPTH_LOG2=[get_property CONFIG.DEPTH_LOG2 $c]"
# elaborate the shim itself (non-default parameters) so its port/parameter map is compiled
synth_design -rtl -top scope_axil_bd -part xc7a100tcsg324-1 -generic {PROBE_W=64 DEPTH_LOG2=10 RLE_EN=0}
puts "IPI_ELAB probe_w=[llength [get_ports probe*]] cells=[llength [get_cells -hierarchical]]"
if {[llength [get_ports probe*]] != 64} { set ok 0 }
if {$ok} { puts "IPI_CHECK: PASS" } else { puts "IPI_CHECK: FAIL"; exit 1 }
