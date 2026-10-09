# scope.xdc — out-of-context timing constraints for scope_axil_top (Artix-7, build.tcl).
#
# One clock: the AXI4-Lite port runs in the capture domain (scope_axil's contract), so `clk`
# is the only clock in the design and there is no CDC to constrain (XPORT="CSR" removes the
# async FIFO pair).

# 100 MHz capture / AXI clock
create_clock -name clk -period 10.000 [get_ports clk]

# OOC: tell the timer where the clock would come from in a real design so clock-network
# insertion delay and skew are estimated from a global buffer, not an ideal zero-delay port.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# ---- module-boundary budgets ------------------------------------------------------------------
# Out of context there is no board timing, but leaving the ports unconstrained would hide every
# port path from the timer — including the combinational AXI decode (s_axi_*valid/addr/wdata ->
# CSR register file) and the *valid -> *ready paths. In the integrated design the logic on the
# other side of these ports is clocked by the SAME buffered clock tree, so the I/O delays are
# referenced to a virtual clock carrying the network latency `clk` has here (HD.CLK_SRC BUFG ->
# flop insertion delay; 1.5..1.8 ns in the slow-corner reports, 1.6 ns used). Referencing them
# to the raw `clk` port instead would launch port data a full insertion delay ahead of the
# capturing flops' clock (a free ~1.7 ns on every input, the same penalty on every output).
create_clock -name clk_io -period 10.000
set_clock_latency 1.600 [get_clocks clk_io]

# Budgets (time the NEIGHBOUR may use inside the 10 ns period):
#   inputs  1.0 ns — i.e. driven from a register (clk->Q + short route). This is deliberately
#           tight: scope_axil is combinational on the request channels, so s_axi_* inputs run
#           through ~10 logic levels into the CSR register file (see README, "Timing").
#   outputs 2.0 ns
set in_ports [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock clk_io 1.000 $in_ports
set_output_delay -clock clk_io 2.000 [all_outputs]

# Hold on port paths is not checkable out of context: it depends on the real clock skew between
# the neighbour's flop and ours, and a fixed virtual-clock latency cannot track the fast corner.
# Flop-to-flop hold inside the module is fully checked.
set_false_path -hold -from $in_ports
set_false_path -hold -to [all_outputs]
