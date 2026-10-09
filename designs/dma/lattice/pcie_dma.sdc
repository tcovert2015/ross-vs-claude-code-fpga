#============================================================================
# pcie_dma.sdc -- Timing constraints for the PCIe DMA engine (Lattice Radiant)
#
# Port of quartus/pcie_dma.sdc: one 125 MHz clock, async reset false path,
# 1 ns budget on every bus port. Differences forced by the Radiant flow:
#
#   * derive_clock_uncertainty is Quartus-only; dropped (no PLL in this
#     standalone build -- add set_clock_uncertainty once the clock source is
#     known).
#   * remove_from_collection is not supported, so the data/control inputs are
#     listed explicitly. Only the inputs that are live for SYS_IF="AXI4" are
#     listed: the avm_* / AHB inputs are unconnected in this configuration
#     and would only produce "no effect on unconnected port" warnings.
#   * The 1 ns I/O budget is written as set_max_delay -datapath_only instead
#     of set_input_delay / set_output_delay. The bus ports are virtual I/O
#     (internal fabric nets once integrated, see build.tcl) whose neighbours
#     sit on the same clock network as this core. set_input/output_delay
#     -clock clk references the clock at the clk *port* (zero latency) while
#     the core's flops see the pad + primary-clock insertion delay, so every
#     port path is charged that insertion delay as skew: a pure artifact of
#     the virtual pins (see lattice/README.md, "I/O timing model").
#     Datapath-only budgets express the same requirement without it:
#         port -> register : 8.0 - 1.0 (input budget)            = 7.0 ns
#         register -> port : 8.0 - 1.0 (output budget)           = 7.0 ns
#         port -> port     : 8.0 - 1.0 - 1.0                     = 6.0 ns
#============================================================================

# 125 MHz application clock (8 ns).
create_clock -name clk -period 8.000 [get_ports clk]

# asynchronous, synchronously-deasserted reset (RESET_SYNC=1: the false path is
# the async rst_n input into the reset_sync flops).
set_false_path -from [get_ports rst_n]

# 1 ns I/O budget on the (virtual) bus ports. (Radiant accepts -datapath_only
# only together with -from, hence -from [get_clocks clk] for register -> port.)
set_max_delay -from [get_ports { \
    csr_address[*] csr_read csr_write csr_writedata[*] \
    host_waitrequest host_readdata[*] host_readdatavalid host_response[*] \
    axi_awready axi_wready axi_bid[*] axi_bresp[*] axi_bvalid \
    axi_arready axi_rid[*] axi_rdata[*] axi_rresp[*] axi_rlast axi_rvalid }] \
    -datapath_only 7.0
set_max_delay -from [get_clocks clk] -to [all_outputs] -datapath_only 7.0
set_max_delay -from [get_ports { \
    csr_address[*] csr_read csr_write csr_writedata[*] \
    host_waitrequest host_readdata[*] host_readdatavalid host_response[*] \
    axi_awready axi_wready axi_bid[*] axi_bresp[*] axi_bvalid \
    axi_arready axi_rid[*] axi_rdata[*] axi_rresp[*] axi_rlast axi_rvalid }] \
    -to [all_outputs] -datapath_only 6.0
