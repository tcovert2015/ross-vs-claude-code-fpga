# =============================================================================
# i3c_target.xdc  -  Timing constraints for the I3C Target on AMD 7-series
#                    (out-of-context build of i3c_target_top, xc7a100tcsg324-1)
#
# Mirrors syn/altera/i3c_target.sdc: the clock, the async I3C bus pads (cut), and
# the synchronous Avalon-MM I/O (in/out delays).  Default build is AVL_ASYNC=0:
# all logic is clocked by `clk`; avl_clk / avl_rst_n drive nothing.
#
# sys_clk must be >= 100 MHz (design_decisions D-1); closed here at 125 MHz (8.0 ns).
# =============================================================================

create_clock -name clk -period 8.000 [get_ports clk]

# Out-of-context: `clk` arrives from a global buffer in the parent design. Tell
# the timer what drives it so clock delay/skew/CPR are estimated for a BUFG
# (UG905, "I/O and Clock Buffers" / HD.CLK_SRC).
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# -----------------------------------------------------------------------------
# Asynchronous I3C bus pads (SDA/SCL go through the 2-FF synchronizers in
# i3c_bus_frontend; metastability closed structurally, not by STA) and the
# open-drain SDA output.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {SCL SDA}]
set_false_path -to   [get_ports {SDA}]

# -----------------------------------------------------------------------------
# Avalon-MM application interface (clk domain in the default AVL_ASYNC=0 build).
# Same placeholder budgets as the Altera SDC; set to the real master for sign-off.
#
# DEVIATION from the Altera SDC: rst_n is NOT false-pathed. Every flop in the RTL
# uses rst_n as a SYNCHRONOUS reset (`always_ff @(posedge clk) if (!rst_n)`), so
# it is an ordinary clk-domain data input and is timed like the Avalon inputs.
# -----------------------------------------------------------------------------
set AVL_IN  [get_ports {rst_n avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set AVL_OUT [get_ports {avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]

set_input_delay  -clock clk -max 1.0 $AVL_IN
set_input_delay  -clock clk -min 0.3 $AVL_IN
set_output_delay -clock clk -max 1.0 $AVL_OUT
set_output_delay -clock clk -min 0.3 $AVL_OUT

# -----------------------------------------------------------------------------
# I3C pads (IOBUF/IBUF live in rtl/xilinx/i3c_io_xilinx.sv). No pin LOCs here:
# this is an IP-level OOC build; the board XDC assigns PACKAGE_PIN and the bank
# voltage. LVCMOS18 is a placeholder matching a 1.8 V I3C bus.
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {SDA SCL}]
