# =============================================================================
# build.tcl  -  Lattice Radiant project flow for the I3C Target (Certus-NX)
#
#   <radiant>/bin/nt64/radiantc.exe syn/lattice/build.tcl      (or pnmainc.exe)
#   (syn/lattice/build.ps1 does this and tees the console to reports/build_console.log)
#
# Runs, in order: Synplify Pro synthesis -> map -> place & route -> static timing
# analysis, for top i3c_target_top on LFD2NX-40-8BG256C, then copies the
# synthesis log, map report, PAR report and timing reports to syn/lattice/reports/.
# STA is run twice on the same routed database: once with the full constraints
# (timing.twr, Avalon ports timed as chip pins) and once with every pin path cut
# (timing_core.twr, register-to-register only; see i3c_target_core.sdc). The Radiant project lives in the scratch directory
# syn/lattice/build/ (git-ignored, recreated from scratch on every run).
# =============================================================================
set HERE  [file dirname [file normalize [info script]]]
set REPO  [file normalize [file join $HERE .. ..]]
set BUILD [file join $HERE build]
set RPT   [file join $HERE reports]

set PROJ   i3c_target
set IMPL   impl_1
set TOP    i3c_target_top
set DEVICE LFD2NX-40-8BG256C
set PERF   "8_High-Performance_1.0V"

# Same RTL list (and order) as sim/run.sh, with the Lattice IO shim.
set RTL {
  rtl/i3c_pkg.sv rtl/i3c_sda_mux.sv rtl/i3c_bus_frontend.sv rtl/i3c_bit_engine.sv
  rtl/i3c_framer.sv rtl/i3c_hdr_exit_detector.sv rtl/i3c_fifo.sv rtl/i3c_protocol_fsm.sv
  rtl/i3c_daa.sv rtl/i3c_ccc.sv rtl/i3c_ibi.sv rtl/i3c_error_recovery.sv rtl/i3c_regfile.sv
  rtl/i3c_avalon_mm.sv rtl/lattice/i3c_io_lattice.sv rtl/i3c_target_top.sv
}

file delete -force $BUILD
file mkdir $BUILD
file mkdir $RPT
cd $BUILD

prj_create -name $PROJ -dir $BUILD -dev $DEVICE -performance $PERF \
           -impl $IMPL -synthesis synplify
foreach f $RTL { prj_add_source [file join $REPO $f] }
prj_add_source [file join $HERE i3c_target.sdc]
if {[file exists [file join $HERE i3c_target.pdc]]} {
  prj_add_source [file join $HERE i3c_target.pdc]
}

prj_set_impl_opt -impl $IMPL top $TOP
# Select the Lattice pad wrapper at the vendor-IO hook in i3c_target_top.sv.
prj_set_impl_opt -impl $IMPL VERILOG_DIRECTIVES "I3C_IO_MODULE=i3c_io_lattice"
prj_save

# Milestones in flow order.
puts "=== Synthesis (Synplify Pro) ==="
prj_run Synthesis -impl $IMPL -forceAll
puts "=== Map ==="
prj_run Map -impl $IMPL
puts "=== Place & Route ==="
prj_run PAR -impl $IMPL
# Post-route STA with the full constraint set. Radiant already runs this task as
# part of the PAR milestone; -forceOne re-runs it so STA is an explicit step.
puts "=== Static Timing Analysis (post-route, full constraints) ==="
prj_run PAR -impl $IMPL -task PARTrace -forceOne
prj_save
prj_close

# Second STA pass on the same routed .udb with the chip-pin paths cut.
puts "=== Static Timing Analysis (post-route, core-only view) ==="
set IDIR [file join $BUILD $IMPL]
set base ${PROJ}_${IMPL}
cd $IDIR
file copy -force [file join $HERE i3c_target_core.sdc] i3c_target_core.sdc
set TIMING [file join $::env(FOUNDRY) bin nt64 timing]
if {[catch {exec $TIMING -sethld -v 10 -u 10 -endpoints 10 -nperend 1 \
              -sp $PERF -hsp m -sdc-file i3c_target_core.sdc \
              -rpt-file ${base}_core.twr -db-file $base.udb 2>@1} out]} {
  puts $out
  error "core-only timing run failed"
}
puts $out

# -----------------------------------------------------------------------------
# Collect reports
# -----------------------------------------------------------------------------
foreach {src dst} [list \
    $base.srr           synthesis.srr \
    $base.mrp           map.mrp \
    $base.par           par.par \
    $base.twr           timing.twr \
    ${base}_core.twr    timing_core.twr \
    $base.pad           pad.pad ] {
  set s [file join $IDIR $src]
  if {![file exists $s]} { error "expected report not produced: $src" }
  file copy -force $s [file join $RPT $dst]
  puts "report: $dst <- $src"
}
puts "=== build.tcl done ==="
