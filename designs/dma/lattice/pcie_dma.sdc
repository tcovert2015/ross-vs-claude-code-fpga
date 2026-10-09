#============================================================================
# pcie_dma.sdc -- Radiant / Synplify Pro timing constraints for the PCIe DMA
# engine (port of quartus/pcie_dma.sdc).
#
# The whole engine runs on a single clock `clk` (typically the PCIe hard-IP
# application clock, 125-250 MHz). Adjust the period to the target.
#============================================================================

# 125 MHz application clock (8 ns).
create_clock -name clk -period 8.000 [get_ports clk]

# asynchronous, synchronously-deasserted reset. With RESET_SYNC=1 the false
# path is the asynchronous rst_n input into the reset_sync flops; the
# synchronized deassertion is then a normal timed path inside the clk domain.
set_false_path -from [get_ports rst_n]

# Conservative I/O budget, as in the Quartus flow: 1 ns of the 8 ns period is
# reserved for the logic on the other side of every data/control port (not the
# clock or reset), i.e. 7 ns port->register and register->port, 6 ns port->port.
#
# quartus/pcie_dma.sdc writes this as set_input_delay/set_output_delay 1.0.
# Here it is written as set_max_delay -datapath_only instead, because the bus
# ports are virtual I/O (fabric nets with no pad and no location) while clk
# enters through a real pad and the global clock tree (2.1 ns at the hold
# corner, 4.1 ns at the slow setup corner). With
# set_input_delay/set_output_delay Radiant launches/captures the port side at
# the ideal clock edge and the register side after the clock-tree latency, so
# that latency is charged against every output path and shows up as a hold
# violation on every input path. That skew does not exist once the core is
# integrated (both sides sit on the same clock tree). -datapath_only applies
# the same 1 ns budget without the skew. The literal set_input_delay /
# set_output_delay version is kept in pcie_dma_iodelay.sdc and its results are
# in reports/iodelay/ (see README.md).
#
# (Radiant rejects "-to <ports> -datapath_only" without a -from, hence
# -from [get_clocks clk] on the register->port constraint.)
#
# Only the port groups that exist in the SYS_IF="AXI4" build are listed: the
# unused Avalon/AHB SYS inputs are unconnected and their outputs are tied to 0.
set_max_delay -from [get_ports {csr_address[*] csr_read csr_write csr_writedata[*] host_waitrequest host_readdata[*] host_readdatavalid host_response[*] axi_awready axi_wready axi_bid[*] axi_bresp[*] axi_bvalid axi_arready axi_rid[*] axi_rdata[*] axi_rresp[*] axi_rlast axi_rvalid}] -datapath_only 7.0
set_max_delay -from [get_clocks clk] -to [get_ports {csr_readdata[*] csr_readdatavalid csr_waitrequest host_address[*] host_read host_write host_writedata[*] host_byteenable[*] host_burstcount[*] axi_awid[*] axi_awaddr[*] axi_awlen[*] axi_awsize[*] axi_awburst[*] axi_awcache[*] axi_awprot[*] axi_awvalid axi_wdata[*] axi_wstrb[*] axi_wlast axi_wvalid axi_bready axi_arid[*] axi_araddr[*] axi_arlen[*] axi_arsize[*] axi_arburst[*] axi_arcache[*] axi_arprot[*] axi_arvalid axi_rready irq sys_bus_error host_bus_error}] -datapath_only 7.0
set_max_delay -from [get_ports {csr_address[*] csr_read csr_write csr_writedata[*] host_waitrequest host_readdata[*] host_readdatavalid host_response[*] axi_awready axi_wready axi_bid[*] axi_bresp[*] axi_bvalid axi_arready axi_rid[*] axi_rdata[*] axi_rresp[*] axi_rlast axi_rvalid}] -to [get_ports {csr_readdata[*] csr_readdatavalid csr_waitrequest host_address[*] host_read host_write host_writedata[*] host_byteenable[*] host_burstcount[*] axi_awid[*] axi_awaddr[*] axi_awlen[*] axi_awsize[*] axi_awburst[*] axi_awcache[*] axi_awprot[*] axi_awvalid axi_wdata[*] axi_wstrb[*] axi_wlast axi_wvalid axi_bready axi_arid[*] axi_araddr[*] axi_arlen[*] axi_arsize[*] axi_arburst[*] axi_arcache[*] axi_arprot[*] axi_arvalid axi_rready irq sys_bus_error host_bus_error}] -datapath_only 6.0
