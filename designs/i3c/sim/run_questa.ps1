# Compile + run the I3C Target behavioral testbench with the QuestaSim Lattice
# Edition bundled with Radiant. Same file list as sim/run.sh, with the Lattice
# IO shim (rtl/lattice/i3c_io_lattice.sv) instead of the Altera one.
#
#   pwsh sim/run_questa.ps1            # log -> sim/questa.log
#
# Override the install with $env:RADIANT_HOME. Exit code 0 only if the testbench
# reports ALL TESTS PASSED.
$ErrorActionPreference = 'Stop'
$radiant = if ($env:RADIANT_HOME) { $env:RADIANT_HOME } else { 'D:\lscc\radiant\2026.1' }
$qrun    = Join-Path $radiant 'questasim\win64\qrun.exe'
if (-not (Test-Path $qrun)) { Write-Error "qrun not found at $qrun"; exit 2 }

Set-Location (Join-Path $PSScriptRoot '..')
$log = 'sim/questa.log'

$src = @(
  'rtl/i3c_pkg.sv', 'rtl/i3c_sda_mux.sv', 'rtl/i3c_bus_frontend.sv', 'rtl/i3c_bit_engine.sv',
  'rtl/i3c_framer.sv', 'rtl/i3c_hdr_exit_detector.sv', 'rtl/i3c_fifo.sv', 'rtl/i3c_protocol_fsm.sv',
  'rtl/i3c_daa.sv', 'rtl/i3c_ccc.sv', 'rtl/i3c_ibi.sv', 'rtl/i3c_error_recovery.sv', 'rtl/i3c_regfile.sv',
  'rtl/i3c_avalon_mm.sv', 'rtl/lattice/i3c_io_lattice.sv', 'rtl/i3c_target_top.sv',
  'sim/tb_i3c_target.sv'
)

# -mfcu = one compilation unit, like iverilog, so the per-file `include "i3c_pkg.sv"
# guards work and the package is compiled once.
# The design is plain SystemVerilog (inferred tri-state), so no Lattice primitive
# library is needed. qrun runs vsim in console mode; the testbench calls $finish.
& $qrun -clean -sv -mfcu -outdir sim/questa_work -l $log `
    '+incdir+rtl' '+define+I3C_IO_SHIM=i3c_io_lattice' `
    @src -top tb_i3c_target
$rc = $LASTEXITCODE

$text = Get-Content $log -Raw
if ($rc -ne 0)                              { Write-Host "QUESTA FAILED (exit $rc)"; exit 1 }
if ($text -notmatch 'ALL TESTS PASSED')     { Write-Host 'TESTBENCH FAILED';         exit 1 }
Write-Host 'QUESTA REGRESSION PASSED'
exit 0
