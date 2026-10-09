# =============================================================================
# i3c_target.sdc  -  Timing constraints for the I3C Target on Lattice Radiant
#
# Radiant counterpart of syn/altera/i3c_target.sdc: same clock, same cuts, same
# Avalon-MM I/O budgets. Differences from the Altera file are tool syntax only:
#   * no derive_clock_uncertainty (Quartus-only command)
#   * no `get_ports -nowarn`, no Tcl variables, no all_registers: port lists are
#     written out so both Synplify Pro and the Radiant timing engine accept them
#
# Targets the default build (AVL_ASYNC=0): the top ties avl_clk to sys_clk, so
# ALL logic, including the Avalon-MM interface, is clocked by `clk`, and the
# avl_clk/avl_rst_n pins drive nothing.
#
# sys_clk must be >= 100 MHz (design_decisions D-1); closed here at 125 MHz (8.0 ns).
# =============================================================================

create_clock -name clk -period 8.000 [get_ports clk]

# -----------------------------------------------------------------------------
# Asynchronous I3C bus pads (SDA/SCL go through the 2-3 FF synchronizers;
# metastability closed structurally, not by STA) and the SDA output.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {SCL SDA}]
set_false_path -to   [get_ports {SDA}]

# Asynchronous reset, de-assertion synchronized internally.
set_false_path -from [get_ports {rst_n}]

# -----------------------------------------------------------------------------
# Avalon-MM application interface (clk domain in the default AVL_ASYNC=0 build).
# Placeholder I/O budgets, identical to the Altera SDC; set to the real
# master/board numbers for sign-off.
# -----------------------------------------------------------------------------
set_input_delay  -clock [get_clocks clk] -max 1.0 [get_ports {avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set_input_delay  -clock [get_clocks clk] -min 0.3 [get_ports {avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set_output_delay -clock [get_clocks clk] -max 1.0 [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]
set_output_delay -clock [get_clocks clk] -min 0.3 [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]
