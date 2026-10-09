# Compile + run the I3C Target behavioral testbench with Vivado xsim.
# Same file list as sim/run.sh, with the Xilinx IO shim instead of the Altera one.
#   powershell -ExecutionPolicy Bypass -File sim/run_xsim.ps1
# Full transcript (xvlog + xelab + xsim) is written to sim/xsim.log.
# Override the tool location with $env:VIVADO_BIN if Vivado lives elsewhere.
$ErrorActionPreference = 'Continue'
$bin = if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\AMDDesignTools\2025.2\Vivado\bin' }

# Run from the repo root (designs/i3c) with relative paths, like sim/run.sh; the
# testbench's $dumpfile path is relative to it.
Set-Location (Join-Path $PSScriptRoot '..')
$log = 'sim/xsim.log'
$wrk = 'sim/xsim_work'
New-Item -ItemType Directory -Force $wrk | Out-Null
Set-Content -Path $log -Value "# sim/run_xsim.ps1 - xsim regression of tb_i3c_target"

$src = @(
  'rtl/i3c_pkg.sv', 'rtl/i3c_sda_mux.sv', 'rtl/i3c_bus_frontend.sv', 'rtl/i3c_bit_engine.sv',
  'rtl/i3c_framer.sv', 'rtl/i3c_hdr_exit_detector.sv', 'rtl/i3c_fifo.sv', 'rtl/i3c_protocol_fsm.sv',
  'rtl/i3c_daa.sv', 'rtl/i3c_ccc.sv', 'rtl/i3c_ibi.sv', 'rtl/i3c_error_recovery.sv', 'rtl/i3c_regfile.sv',
  'rtl/i3c_avalon_mm.sv', 'rtl/xilinx/i3c_io_xilinx.sv', 'rtl/i3c_target_top.sv',
  'sim/tb_i3c_target.sv'
)

function Step($name, $exe, $argv) {
  Add-Content $log "`n=== $name ==="
  & (Join-Path $bin $exe) @argv 2>&1 | ForEach-Object { Add-Content $log "$_"; "$_" }
  if ($LASTEXITCODE -ne 0) { Write-Host "$name FAILED ($LASTEXITCODE)"; exit 1 }
}

# Options go through -f files: the Vivado launchers are .bat wrappers and cmd.exe
# splits a bare NAME=VALUE argument at the '='.
$opts = @('-sv', '-i rtl', '-d I3C_IO_CELL=i3c_io_xilinx') + $src
Set-Content -Path "$wrk/xvlog.f" -Value $opts
Step 'xvlog' 'xvlog.bat' @('-f', "$wrk/xvlog.f", '--log', "$wrk/xvlog.log")
# The Xilinx shim instantiates IOBUF/IBUF: needs glbl + the unisims_ver library.
Step 'xvlog glbl' 'xvlog.bat' @((Join-Path $bin '../data/verilog/src/glbl.v'), '--log', "$wrk/xvlog_glbl.log")
Step 'xelab' 'xelab.bat' @('work.tb_i3c_target', 'work.glbl', '-L', 'unisims_ver', '--timescale', '1ns/1ps',
                           '--snapshot', 'tb_i3c_target_sim', '--log', "$wrk/xelab.log")
Step 'xsim'  'xsim.bat'  @('tb_i3c_target_sim', '--runall', '--log', "$wrk/xsim_run.log",
                           '--wdb', "$wrk/tb_i3c_target.wdb")

$txt = Get-Content $log -Raw
if ($txt -match 'ALL TESTS PASSED' -and $txt -notmatch '\[FAIL\]|TIMEOUT') { Write-Host 'XSIM REGRESSION PASSED'; exit 0 }
Write-Host 'XSIM REGRESSION FAILED'; exit 1
