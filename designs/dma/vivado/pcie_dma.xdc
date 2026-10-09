#============================================================================
# pcie_dma.xdc -- Timing constraints for the PCIe DMA engine (AMD Vivado)
#
# Vivado port of quartus/pcie_dma.sdc. pcie_dma_top is an IP core, so it is
# implemented out-of-context (synth_design -mode out_of_context): no I/O
# buffers are inserted and the bus ports stay internal-facing, which is the
# Vivado equivalent of the Quartus VIRTUAL_PIN assignments.
#============================================================================

# 125 MHz application clock (8 ns), matching quartus/pcie_dma.sdc.
# (build.tcl -tclargs period=<ns> rewrites this line into a scratch copy of the
# file for Fmax sweeps; keep the "-period <value>" form.)
create_clock -name clk -period 8.000 [get_ports clk]

# No derive_clock_uncertainty equivalent is needed: Vivado always applies the
# clock uncertainty it derives from the clock network / jitter model.

# asynchronous, synchronously-deasserted reset. With RESET_SYNC=1 this is the
# asynchronous rst_n input into the reset_sync flops (CLR pins); the
# synchronized deassertion is then a normal timed recovery/removal path
# inside the clk domain.
set_false_path -from [get_ports rst_n]

# Conservative I/O budget: 1 ns for combinational paths to/from the bus ports,
# applied to the data/control ports only (not the clock or reset).
set_input_delay  -clock clk 1.0 [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set_output_delay -clock clk 1.0 [all_outputs]

# Reset synchronizer flops (RESET_SYNC=1): the RTL only carries an Altera
# synchronizer attribute, so mark the chain here to keep it packed together
# and reported as a synchronizer. -quiet: the cells do not exist with
# RESET_SYNC=0.
set_property -quiet ASYNC_REG TRUE [get_cells -quiet -hierarchical -filter {NAME =~ *u_rst_sync/sync_q_reg[*]}]
