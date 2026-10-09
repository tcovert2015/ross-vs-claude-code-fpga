# =============================================================================
# i3c_target.sdc  -  Timing constraints for the I3C Target on Altera
#
# Constrains EVERY path so STA reports 0 unconstrained ports: the clock, the async
# I3C bus pads + reset (cut), and the synchronous Avalon-MM I/O (in/out delays).
#
# This targets the committed default build (AVL_ASYNC=0): the top ties avl_clk to
# sys_clk, so ALL logic — including the Avalon-MM interface — is clocked by `clk`,
# and the avl_clk/avl_rst_n pins drive nothing.  For an AVL_ASYNC=1 build (separate
# Avalon clock, Gray-pointer async FIFOs) add `create_clock ... avl_clk`, an
# `set_clock_groups -asynchronous` between clk and avl_clk, and change the Avalon
# I/O `-clock clk` below to `-clock avl_clk`.
#
# sys_clk must be >= 100 MHz (design_decisions D-1); closed here at 125 MHz (8.0 ns).
# =============================================================================

create_clock -name clk -period 8.000 [get_ports clk]
derive_clock_uncertainty

# -----------------------------------------------------------------------------
# Asynchronous I3C bus pads (SDA/SCL go through the 2-3 FF synchronizers;
# metastability closed structurally, not by STA) and the open-drain SDA output.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {SCL SDA}] -to [all_registers]
set_false_path -from [all_registers]       -to [get_ports {SDA}]

# Asynchronous reset(s), de-assertion synchronized internally. avl_rst_n is tied
# off in the default build; -nowarn keeps the script clean if it was pruned.
set_false_path -from [get_ports -nowarn {rst_n avl_rst_n}] -to [all_registers]

# -----------------------------------------------------------------------------
# Avalon-MM application interface (clk domain in the default AVL_ASYNC=0 build).
# Placeholder I/O budgets (~25% of the period each way); set to the real
# master/board numbers for sign-off.
# -----------------------------------------------------------------------------
set AVL_IN  [get_ports {avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set AVL_OUT [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]

set_input_delay  -clock clk -max 1.0 $AVL_IN
set_input_delay  -clock clk -min 0.3 $AVL_IN
set_output_delay -clock clk -max 1.0 $AVL_OUT
set_output_delay -clock clk -min 0.3 $AVL_OUT
