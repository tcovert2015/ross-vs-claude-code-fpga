# =============================================================================
# i3c_target.xdc  -  Timing constraints for the I3C Target on AMD Vivado
#
# Port of syn/altera/i3c_target.sdc (same clock, same cuts, same I/O budgets).
# Targets the default build (AVL_ASYNC=0): the top ties avl_clk to sys_clk, so
# ALL logic - including the Avalon-MM interface - is clocked by `clk`, and the
# avl_clk/avl_rst_n ports drive nothing. For an AVL_ASYNC=1 build add
# `create_clock ... avl_clk`, a `set_clock_groups -asynchronous` between clk and
# avl_clk, and change the Avalon I/O `-clock clk` below to `-clock avl_clk`.
#
# sys_clk must be >= 100 MHz (design_decisions D-1); closed here at 125 MHz (8.0 ns).
#
# Differences from the SDC: `derive_clock_uncertainty` is Quartus-only (Vivado
# derives clock uncertainty automatically). No pin LOCs / IOSTANDARDs: the core
# is implemented out-of-context, add them in the board-level XDC.
# =============================================================================

create_clock -name clk -period 8.000 [get_ports clk]

# Out-of-context clock source: tells the OOC implementation that `clk` arrives
# from a global buffer, so the clock tree is routed and its insertion delay /
# skew are real numbers rather than estimates (UG905). The site is arbitrary.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# -----------------------------------------------------------------------------
# Asynchronous I3C bus pads (SDA/SCL go through the 2-3 FF synchronizers;
# metastability closed structurally, not by STA) and the open-drain SDA output.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {SCL SDA}] -to [all_registers]
set_false_path -from [all_registers]       -to [get_ports {SDA}]

# Asynchronous reset, de-assertion synchronized internally. avl_rst_n is unused
# (no loads) in the default AVL_ASYNC=0 build, so it is not constrained here.
set_false_path -from [get_ports rst_n] -to [all_registers]

# -----------------------------------------------------------------------------
# Avalon-MM application interface (clk domain in the default AVL_ASYNC=0 build).
# Placeholder I/O budgets identical to the Altera SDC; set to the real
# master/interconnect numbers for sign-off.
# -----------------------------------------------------------------------------
set AVL_IN  [get_ports {avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set AVL_OUT [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]

set_input_delay  -clock clk -max 1.0 $AVL_IN
set_input_delay  -clock clk -min 0.3 $AVL_IN
set_output_delay -clock clk -max 1.0 $AVL_OUT
set_output_delay -clock clk -min 0.3 $AVL_OUT
