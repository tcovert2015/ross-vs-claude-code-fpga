# =============================================================================
# build.tcl  -  Lattice Radiant project flow for the I3C Target (Certus-NX)
#
#   radiantc syn/lattice/build.tcl        (or pnmainc; run from anywhere)
#
# Creates a scratch project under syn/lattice/build/, then runs, in order:
#   synthesis (Synplify Pro) -> map -> place & route -> static timing analysis
# and leaves the synthesis log (.srr), map report (.mrp), PAR report (.par) and
# timing reports (.twr, .r2r.twr) in syn/lattice/reports/.
#
# Part: LFD2NX-40-8BG256C, top: i3c_target_top, clk = 125 MHz (i3c_target.sdc).
# No pin locations are assigned (IP-core build; PAR auto-places the pads);
# i3c_target.pdc only turns off the default pad pull-down on SDA/SCL.
# =============================================================================
set here    [file normalize [file dirname [info script]]]
set root    [file normalize [file join $here .. ..]]
set bld     [file join $here build]
set rpt     [file join $here reports]
set proj    i3c_target
set impl    impl_1
set part    LFD2NX-40-8BG256C
set perf    "8_High-Performance_1.0V"

# Same RTL list as sim/run.sh, with the Lattice IO shim instead of the Altera one.
set rtl {
  rtl/i3c_pkg.sv rtl/i3c_sda_mux.sv rtl/i3c_bus_frontend.sv rtl/i3c_bit_engine.sv
  rtl/i3c_framer.sv rtl/i3c_hdr_exit_detector.sv rtl/i3c_fifo.sv rtl/i3c_protocol_fsm.sv
  rtl/i3c_daa.sv rtl/i3c_ccc.sv rtl/i3c_ibi.sv rtl/i3c_error_recovery.sv rtl/i3c_regfile.sv
  rtl/i3c_avalon_mm.sv rtl/lattice/i3c_io_lattice.sv rtl/i3c_target_top.sv
}

file delete -force $bld
file mkdir $bld $rpt

prj_create -name $proj -dir $bld -impl $impl -dev $part -performance $perf -synthesis synplify
foreach f $rtl { prj_add_source [file join $root $f] }
prj_add_source [file join $here i3c_target.sdc] [file join $here i3c_target.pdc]
prj_set_impl_opt -impl $impl top i3c_target_top
prj_set_impl_opt -impl $impl {include path} [file join $root rtl]
prj_set_impl_opt -impl $impl VERILOG_DIRECTIVES {I3C_IO_SHIM=i3c_io_lattice}
prj_save

set base [file join $bld $impl ${proj}_${impl}]

puts "==== build.tcl: synthesis (Synplify Pro) ===="
prj_run_synthesis
puts "==== build.tcl: map ===="
prj_run_map
puts "==== build.tcl: place & route ===="
prj_run_par

# -----------------------------------------------------------------------------
# Static timing analysis, pass 1: prj_run_par ends with Radiant's "Place & Route
# Timing Analysis" task, the sign-off STA run (setup at both slow corners, hold
# at the min corner) over every path as constrained by i3c_target.sdc -> .twr
# -----------------------------------------------------------------------------
if {![file exists $base.twr]} { error "STA did not produce $base.twr" }

prj_save
prj_close

# -----------------------------------------------------------------------------
# Static timing analysis, pass 2: the same timing engine on the same routed
# database (nothing is re-placed or re-routed), same speed grades / corners,
# with the top-level port paths cut by i3c_target_r2r.sdc, i.e. the
# register-to-register paths only -> .r2r.twr
# -----------------------------------------------------------------------------
puts "==== build.tcl: static timing analysis (register-to-register only) ===="
set bindir [expr {$tcl_platform(platform) eq "windows" ? "nt64" : "lin64"}]
set timing [file join $env(FOUNDRY) bin $bindir timing]
set r2r    [file join $rpt ${proj}_${impl}.r2r.twr]
file delete -force $r2r
catch {exec $timing -sethld -v 10 -u 10 -endpoints 10 -nperend 1 \
         -sp $perf -hsp m -sdc-file [file join $here i3c_target_r2r.sdc] \
         -rpt-file $r2r -db-file $base.udb 2>@1} out
puts $out
if {![file exists $r2r]} { error "register-to-register STA did not produce $r2r" }

# Collect the evidence: .srr = Synplify log, .mrp = map report, .par = PAR
# report, .twr = post-route timing report, .pad = the pins PAR chose.
foreach ext {srr mrp par twr pad} {
  set f $base.$ext
  if {![file exists $f]} { error "missing report $f" }
  file copy -force $f [file join $rpt [file tail $f]]
  puts "report: [file tail $f]"
}
puts "report: [file tail $r2r]"
puts "==== build.tcl: done ===="
