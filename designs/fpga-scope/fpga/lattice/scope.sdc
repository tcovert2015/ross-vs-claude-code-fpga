# scope_axil_top timing constraints (Radiant, Certus-NX LFD2NX-40-8BG256C)
# Single clock domain: clk @ 100 MHz. XPORT="CSR" has no CDC, so no exceptions are needed.
create_clock -name clk -period 10.000 [get_ports clk]
