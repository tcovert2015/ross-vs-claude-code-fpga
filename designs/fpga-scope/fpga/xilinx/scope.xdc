# scope.xdc — out-of-context timing constraints for scope_axil_top (xc7a100tcsg324-1).
#
# One clock: `clk` is both the probe/capture clock and the AXI4-Lite clock. 100 MHz.
create_clock -name clk -period 10.000 [get_ports clk]

# OOC build: the module's ports are not pins, they connect to fabric in the parent design.
# Budget 2 ns of the 10 ns period to the parent on every input and output so the port paths
# (AXI4-Lite handshake, probe -> trigger pipeline, CSR readback) are timed instead of ignored.
set in_ports [filter [all_inputs] {NAME != clk}]
set_input_delay  -clock clk -max 2.000 $in_ports
set_input_delay  -clock clk -min 0.000 $in_ports
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.000 [all_outputs]

# Hold on the port paths is NOT analyzable out of context and is closed in the parent design:
# with no clock buffer or routed clock net, Vivado gives every clk pin an estimated ~0.9-1.0 ns
# insertion delay while the port data is launched at an ideal 0 ns, so every port -> flop path
# shows the same fictitious ~-0.5 ns hold violation regardless of the logic (the router cannot
# add delay to a port net either). In context the launching flop shares the same clock tree.
# Setup on these paths and all internal (flop -> flop, flop -> BRAM) hold checks stay active.
set_false_path -hold -from $in_ports
set_false_path -hold -to   [all_outputs]
