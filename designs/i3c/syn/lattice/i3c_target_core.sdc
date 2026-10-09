# =============================================================================
# i3c_target_core.sdc  -  "core-only" STA view (second timing run in build.tcl)
#
# NOT used for synthesis/map/PAR. It is layered on top of the constraints already
# in the routed database (i3c_target.sdc) for a second `timing` run, and cuts
# every chip-pin path so the report (reports/timing_core.twr) shows the
# register-to-register logic alone - the figure that matters when this block is
# used as an on-chip IP behind an Avalon interconnect, with no pad buffers.
# Same placed-and-routed netlist as reports/timing.twr; nothing is re-optimised.
# =============================================================================
create_clock -name {clk} -period 8.000 [get_ports clk]
set_false_path -from [get_ports {SCL SDA rst_n avs_address[*] avs_read avs_write avs_writedata[*] avs_byteenable[*]}]
set_false_path -to   [get_ports {SDA avs_readdata[*] avs_readdatavalid avs_waitrequest irq}]
