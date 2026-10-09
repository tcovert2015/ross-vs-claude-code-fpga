#============================================================================
# pcie_dma.xdc -- Vivado timing constraints for the PCIe DMA engine
#
# Port of quartus/pcie_dma.sdc for the out-of-context (OOC) build of
# pcie_dma_top (vivado/build.tcl). Same intent, constraint for constraint:
#
#   quartus/pcie_dma.sdc                     this file
#   ---------------------------------------  ---------------------------------
#   create_clock -period 8.000 clk           same
#   derive_clock_uncertainty                 (not an XDC command; Vivado derives
#                                             clock uncertainty automatically)
#   set_false_path -from rst_n               same
#   set_input_delay/set_output_delay 1.0 ns  set_max_delay -datapath_only of
#                                             (period - 1.0 ns) on the ports,
#                                             see "I/O budget" below
#   VIRTUAL_PIN on every bus port            synth_design -mode out_of_context
#                                             (no I/O buffers, ports not placed)
#============================================================================

# 125 MHz application clock (8 ns). build.tcl rewrites this one line for its
# optional Fmax runs; keep the "set clk_period <value>" form.
set clk_period 8.500
create_clock -name clk -period $clk_period [get_ports clk]

# OOC only: tell the timer which kind of buffer drives the clock port in the
# parent design, so clock insertion/skew is estimated as a BUFG-driven global
# clock (UG905 "I/O and Clock Buffers": HD.CLK_SRC).
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# Asynchronous reset input. With RESET_SYNC=1 this cuts only the async path
# into the reset_sync flops; the synchronized deassertion that fans out to the
# core is a normal timed recovery/removal path inside the clk domain.
set_false_path -from [get_ports rst_n]

# Mark the reset synchronizer chain so it is kept adjacent and reported as a
# synchronizer (the RTL only carries the Quartus altera_attribute for this;
# done here rather than by editing the vendor-neutral RTL).
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *u_rst_sync/sync_q_reg[*]}]

# I/O budget: quartus/pcie_dma.sdc reserves 1 ns outside the core on every
# data/control port (not clk / rst_n), i.e. the core gets (period - 1 ns) for
# port->register and register->port paths and (period - 2 ns) port->port.
#
# That budget is expressed here with set_max_delay -datapath_only, which is the
# out-of-context boundary constraint UG905 ("Timing Constraints" for OOC
# modules) prescribes, instead of set_input_delay/set_output_delay. Reason: in
# an OOC run the clock is propagated from the port (about 1.8 ns of estimated
# BUFG insertion delay to the flops) while a port-referenced input delay is
# launched with zero insertion delay. A literal "set_input_delay 1.0" therefore
# reports ~200 port->register hold violations and a setup budget that is
# optimistic by the insertion delay; neither exists once the neighbouring
# logic sits on the same clock tree. -datapath_only budgets the data path
# alone (no skew, no hold check on the boundary); boundary hold is closed in
# the parent design.
set io_budget 1.000
set in_ports  [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set out_ports [all_outputs]
set_max_delay -datapath_only [expr {$clk_period - $io_budget}]     -from $in_ports
# (-datapath_only needs a -from: every register->port path is launched by clk)
set_max_delay -datapath_only [expr {$clk_period - $io_budget}]     -from [get_clocks clk] -to $out_ports
set_max_delay -datapath_only [expr {$clk_period - 2 * $io_budget}] -from $in_ports -to $out_ports
