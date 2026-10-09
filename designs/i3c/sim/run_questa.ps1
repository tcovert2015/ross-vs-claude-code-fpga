# Compile + run the I3C Target behavioral testbench with the QuestaSim bundled
# with Lattice Radiant. Same file list as sim/run.sh, with the Lattice IO shim
# (rtl/lattice/i3c_io_lattice.sv, selected via +define+I3C_IO_MODULE) instead of
# the Altera one. The shim is plain SystemVerilog, so no lfd2nx library is needed.
#   powershell -File sim/run_questa.ps1          # log -> sim/questa.log
# Exit code: 0 = compiled and ALL TESTS PASSED, 1 otherwise.
param(
  [string]$Radiant = $(if ($env:RADIANT_HOME) { $env:RADIANT_HOME } else { 'D:\lscc\radiant\2026.1' })
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')     # tb writes sim/tb_i3c_target.vcd relative to here
$Q    = Join-Path $Radiant 'questasim\win64'
$Work = 'sim/questa_work'
$Log  = 'sim/questa.log'

$Files = @(
  'rtl/i3c_pkg.sv', 'rtl/i3c_sda_mux.sv', 'rtl/i3c_bus_frontend.sv', 'rtl/i3c_bit_engine.sv',
  'rtl/i3c_framer.sv', 'rtl/i3c_hdr_exit_detector.sv', 'rtl/i3c_fifo.sv', 'rtl/i3c_protocol_fsm.sv',
  'rtl/i3c_daa.sv', 'rtl/i3c_ccc.sv', 'rtl/i3c_ibi.sv', 'rtl/i3c_error_recovery.sv', 'rtl/i3c_regfile.sv',
  'rtl/i3c_avalon_mm.sv', 'rtl/lattice/i3c_io_lattice.sv', 'rtl/i3c_target_top.sv',
  'sim/tb_i3c_target.sv'
)

if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
Set-Content -Path $Log -Value '# sim/run_questa.ps1 - QuestaSim (Lattice Radiant) regression log'
& "$Q\vlib.exe" $Work 2>&1 | Tee-Object -FilePath $Log -Append
# -mfcu: one compilation unit, as iverilog does, so the `include "i3c_pkg.sv" guard
# holds across files (otherwise vlog re-compiles the package 13 times, vlog-2275).
& "$Q\vlog.exe" -sv -mfcu -work $Work +incdir+rtl +define+I3C_IO_MODULE=i3c_io_lattice @Files 2>&1 |
  Tee-Object -FilePath $Log -Append
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED ($LASTEXITCODE)"; exit 1 }

& "$Q\vsim.exe" -c -lib $Work -nolog tb_i3c_target -do 'run -all; quit -f' 2>&1 |
  Tee-Object -FilePath $Log -Append
if ($LASTEXITCODE -ne 0) { Write-Host "SIM FAILED ($LASTEXITCODE)"; exit 1 }

$txt = Get-Content $Log -Raw
if ($txt -match 'ALL TESTS PASSED' -and $txt -notmatch '\[FAIL\]|TIMEOUT|\*\* Error|\*\* Fatal') { exit 0 }
Write-Host 'REGRESSION FAILED'; exit 1
