# scope.sdc — timing constraints for scope_axil_top on Certus-NX (LFD2NX-40-8BG256C).
# Single clock domain: clk is both the capture clock and the AXI4-Lite clock.
create_clock -name clk -period 10.000 [get_ports clk]
