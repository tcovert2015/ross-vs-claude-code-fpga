# scope.xdc — out-of-context timing constraints for scope_axil_top (Artix-7, 100 MHz).
#
# The module is implemented out-of-context (no I/O buffers, ports are not package pins), so
# there are no pin/IOSTANDARD constraints here — only the clock and a boundary timing budget.

# 100 MHz capture/AXI clock
create_clock -name clk -period 10.000 [get_ports clk]

# OOC clock modelling: tell the timer the clock port is driven by a global buffer in the
# parent design, so clock insertion delay / skew are estimated on the BUFG network instead of
# on an unbuffered fabric route from the port.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# Boundary budget: every port is synchronous to clk. Give the (unknown) parent design 3.0 ns of
# the 10 ns period on each side, i.e. 7.0 ns remain for logic inside this module on
# port->register and register->port paths, and 4.0 ns on the combinational AXI ready paths
# (s_axi_*valid -> s_axi_*ready).
#
# The input delay is deliberately the same for -min and -max (Vivado notes this as XDCH-2).
# Out of context the clock port is an ideal 0 ns launch point while the capture flops see the
# estimated BUFG insertion delay (~1.7 ns), so a small -min value only produces artificial
# port->register hold violations (measured: WHS -0.254 ns with -min 1.0) that say nothing
# about the module. Boundary hold is re-timed, with real clock skew, when the block is
# implemented in context.
set in_ports [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock clk 3.000 $in_ports
set_output_delay -clock clk -max 3.000 [get_ports -filter {DIRECTION == OUT}]
set_output_delay -clock clk -min 0.000 [get_ports -filter {DIRECTION == OUT}]
