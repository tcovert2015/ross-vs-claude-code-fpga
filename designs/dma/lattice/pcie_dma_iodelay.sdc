#============================================================================
# pcie_dma_iodelay.sdc -- ALTERNATIVE constraints: literal port of
# quartus/pcie_dma.sdc using set_input_delay / set_output_delay.
#
# Not the default. Select it with the DMA_SDC environment variable:
#   set DMA_SDC=pcie_dma_iodelay.sdc   (see build.tcl)
# Reports then go to reports/iodelay/. See pcie_dma.sdc and README.md for why
# the default flow expresses the same 1 ns I/O budget as set_max_delay
# -datapath_only instead.
#============================================================================

# 125 MHz application clock (8 ns).
create_clock -name clk -period 8.000 [get_ports clk]

set_false_path -from [get_ports rst_n]

# 1 ns I/O budget on the data/control ports (not the clock or reset). Radiant
# has no remove_from_collection, so the ports are listed per bus group; only
# the groups that exist in the SYS_IF="AXI4" build are listed.
set_input_delay -clock [get_clocks clk] 1.0 [get_ports {csr_address[*] csr_read csr_write csr_writedata[*]}]
set_input_delay -clock [get_clocks clk] 1.0 [get_ports {host_waitrequest host_readdata[*] host_readdatavalid host_response[*]}]
set_input_delay -clock [get_clocks clk] 1.0 [get_ports {axi_awready axi_wready axi_bid[*] axi_bresp[*] axi_bvalid}]
set_input_delay -clock [get_clocks clk] 1.0 [get_ports {axi_arready axi_rid[*] axi_rdata[*] axi_rresp[*] axi_rlast axi_rvalid}]

set_output_delay -clock [get_clocks clk] 1.0 [get_ports {csr_readdata[*] csr_readdatavalid csr_waitrequest}]
set_output_delay -clock [get_clocks clk] 1.0 [get_ports {host_address[*] host_read host_write host_writedata[*] host_byteenable[*] host_burstcount[*]}]
set_output_delay -clock [get_clocks clk] 1.0 [get_ports {axi_awid[*] axi_awaddr[*] axi_awlen[*] axi_awsize[*] axi_awburst[*] axi_awcache[*] axi_awprot[*] axi_awvalid}]
set_output_delay -clock [get_clocks clk] 1.0 [get_ports {axi_wdata[*] axi_wstrb[*] axi_wlast axi_wvalid axi_bready}]
set_output_delay -clock [get_clocks clk] 1.0 [get_ports {axi_arid[*] axi_araddr[*] axi_arlen[*] axi_arsize[*] axi_arburst[*] axi_arcache[*] axi_arprot[*] axi_arvalid axi_rready}]
set_output_delay -clock [get_clocks clk] 1.0 [get_ports {irq sys_bus_error host_bus_error}]
