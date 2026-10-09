# =============================================================================
# i3c_target.xdc  -  Timing constraints for the I3C Target on AMD Vivado
#
# XDC translation of syn/altera/i3c_target.sdc (same clock, same cuts, same
# Avalon-MM I/O budgets) for the out-of-context build of i3c_target_top.
#
# This targets the default build (AVL_ASYNC=0): the top ties avl_clk to sys_clk,
# so ALL logic - including the Avalon-MM interface - is clocked by `clk`, and the
# avl_clk/avl_rst_n ports drive nothing. For an AVL_ASYNC=1 build add
# `create_clock ... avl_clk`, `set_clock_groups -asynchronous` between clk and
# avl_clk, and change the Avalon I/O `-clock clk` below to `-clock avl_clk`.
#
# sys_clk must be >= 100 MHz (design_decisions D-1); closed here at 125 MHz (8.0 ns).
# (No derive_clock_uncertainty: Vivado computes clock uncertainty itself.)
# =============================================================================

create_clock -name clk -period 8.000 [get_ports clk]

# Out-of-context note: the IP contains no clock buffer, so Vivado analyses `clk`
# as a propagated clock entering at the port with an ESTIMATED (unrouted) net
# delay to each flop. That insertion delay is charged as skew against the
# port-referenced Avalon input delays below, which is what produces the
# input-port hold violations discussed in README.md; in a real system the
# launching register sits on the same clock tree. (HD.CLK_SRC was tried: the
# clock net is still estimated, and it only enlarges that artifact.)

# -----------------------------------------------------------------------------
# Asynchronous I3C bus pads (SDA/SCL go through the 2-3 FF synchronizers;
# metastability closed structurally, not by STA) and the open-drain SDA output.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {SCL SDA}]
set_false_path -to   [get_ports {SDA}]

# Asynchronous reset(s), de-assertion synchronized internally. avl_rst_n is
# unused in the default build.
set_false_path -from [get_ports {rst_n avl_rst_n}]

# -----------------------------------------------------------------------------
# Avalon-MM application interface (clk domain in the default AVL_ASYNC=0 build).
# Placeholder I/O budgets, identical to the Altera SDC; set to the real
# master/interconnect numbers for sign-off.
# -----------------------------------------------------------------------------
set AVL_IN  [get_ports {avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set AVL_OUT [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]

set_input_delay  -clock clk -max 1.0 $AVL_IN
set_input_delay  -clock clk -min 0.3 $AVL_IN
set_output_delay -clock clk -max 1.0 $AVL_OUT
set_output_delay -clock clk -min 0.3 $AVL_OUT
