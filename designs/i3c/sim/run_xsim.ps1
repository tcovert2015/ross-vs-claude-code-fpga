# Compile + run the I3C Target behavioral testbench with Vivado xsim.
#
#   powershell -ExecutionPolicy Bypass -File sim\run_xsim.ps1
#
# Same file list as sim/run.sh (Icarus), with rtl/xilinx/i3c_io_xilinx.sv in place
# of the Altera shim (selected via -d I3C_IO_MODULE=i3c_io_xilinx). The shim
# instantiates IOBUF, so the UNISIM library and glbl are linked in.
# Log: sim/xsim.log (compile + elaborate + run). Scratch: sim/xsim_work/.
# Exit code 0 only if the testbench prints "ALL TESTS PASSED".
$ErrorActionPreference = 'Stop'

$VivadoBin = if ($env:XILINX_VIVADO) { Join-Path $env:XILINX_VIVADO 'bin' }
             else { 'C:\AMDDesignTools\2025.2\Vivado\bin' }
$Glbl = Join-Path (Split-Path $VivadoBin -Parent) 'data\verilog\src\glbl.v'

$Repo = Split-Path $PSScriptRoot -Parent
$Work = Join-Path $PSScriptRoot 'xsim_work'
$Log  = Join-Path $PSScriptRoot 'xsim.log'

# Run from a scratch dir so xsim.dir / *.pb / *.wdb stay out of the tree. The
# testbench dumps to "sim/tb_i3c_target.vcd" relative to cwd, hence the sim/ subdir.
New-Item -ItemType Directory -Force (Join-Path $Work 'sim') | Out-Null
Set-Location $Work
$Rtl = '..\..\rtl'

$Files = @(
  'i3c_pkg.sv', 'i3c_sda_mux.sv', 'i3c_bus_frontend.sv', 'i3c_bit_engine.sv',
  'i3c_framer.sv', 'i3c_hdr_exit_detector.sv', 'i3c_fifo.sv', 'i3c_protocol_fsm.sv',
  'i3c_daa.sv', 'i3c_ccc.sv', 'i3c_ibi.sv', 'i3c_error_recovery.sv', 'i3c_regfile.sv',
  'i3c_avalon_mm.sv', 'xilinx\i3c_io_xilinx.sv', 'i3c_target_top.sv'
) | ForEach-Object { Join-Path $Rtl $_ }
$Files += '..\tb_i3c_target.sv'

# Echo to the console and append to the log (ASCII; PS 5.1 Tee-Object is UTF-16).
filter Log { Add-Content -Path $Log -Value "$_" -Encoding ascii; "$_" }

function Step([string]$Name, [string]$Tool, [string[]]$ToolArgs) {
  "=== $Name ===" | Log
  & (Join-Path $VivadoBin "$Tool.bat") @ToolArgs 2>&1 | Log
  if ($LASTEXITCODE -ne 0) { "$Name FAILED ($LASTEXITCODE)" | Log; exit 1 }
}

Set-Content -Path $Log -Encoding ascii -Value "# xsim regression: tb_i3c_target (I3C_IO_MODULE=i3c_io_xilinx)"

# Options go through an -f file: a bare NAME=VALUE argument is split at '=' by
# the xvlog.bat wrapper (cmd.exe treats '=' as an argument delimiter).
$Opts = @('-sv', "-i $Rtl", '-d I3C_IO_MODULE=i3c_io_xilinx') + $Files
Set-Content -Path 'xvlog.f' -Encoding ascii -Value ($Opts | ForEach-Object { $_.Replace('\', '/') })

Step 'xvlog (RTL + TB)' 'xvlog' @('-nolog', '-f', 'xvlog.f')
Step 'xvlog (glbl)'     'xvlog' @('-nolog', $Glbl)
Step 'xelab'            'xelab' @('-nolog', '-L', 'unisims_ver', '-timescale', '1ns/1ps',
                                  'work.tb_i3c_target', 'work.glbl', '-s', 'tb_i3c_target_sim')
Step 'xsim'             'xsim'  @('tb_i3c_target_sim', '-nolog', '-runall')

if (Select-String -Path $Log -Pattern '^ALL TESTS PASSED' -Quiet) { exit 0 }
'REGRESSION FAILED (no "ALL TESTS PASSED" in log)' | Log
exit 1
