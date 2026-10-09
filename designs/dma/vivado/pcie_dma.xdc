#============================================================================
# pcie_dma.xdc -- Vivado timing constraints for the PCIe DMA engine
#
# Port of quartus/pcie_dma.sdc for a standalone out-of-context (OOC)
# implementation of pcie_dma_top on Artix-7. The whole engine runs on a single
# clock `clk`; the bus ports are internal-facing (no I/O buffers are inserted
# in OOC mode -- the Vivado equivalent of the Quartus VIRTUAL_PIN assignments).
#============================================================================

# 125 MHz application clock (8 ns), same as quartus/pcie_dma.sdc.
create_clock -name clk -period 8.000 [get_ports clk]

# OOC: tell the timer the clock arrives on a global buffer so clock insertion
# delay / skew are modelled as they will be once the core is integrated (UG905).
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# (Quartus `derive_clock_uncertainty` has no XDC equivalent: Vivado derives
# clock uncertainty automatically.)

# asynchronous, synchronously-deasserted reset.
# With RESET_SYNC=1 this cuts only the asynchronous rst_n input into the
# reset_sync flops; the synchronized deassertion fanning out to the core is a
# normal timed recovery/removal path inside the clk domain.
set_false_path -from [get_ports rst_n]

# Mark the reset synchronizer chain (rtl/core/reset_sync.sv carries only an
# Altera attribute; this is the Vivado equivalent, kept out of the RTL).
set_property ASYNC_REG TRUE [get_cells -hier -filter {NAME =~ *u_rst_sync/sync_q_reg*}]

# Conservative I/O budget: 1 ns for paths to/from the (virtual) pins, applied to
# the data/control ports only (not the clock or reset), as in the Quartus SDC.
#
# Only the -max (setup) side is constrained. In this OOC run `clk` reaches the
# flops through a modelled global buffer (~1.5-1.8 ns insertion delay) while a
# port-referenced I/O delay launches/captures at the un-delayed port, so a
# min (hold) check at the module boundary compares against a launch flop that
# does not exist; in the integrated design the neighbouring flops sit on the
# same clock tree and boundary hold is timed there. Internal reg-to-reg hold is
# fully timed.
set_input_delay  -clock clk -max 1.0 [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set_output_delay -clock clk -max 1.0 [all_outputs]
