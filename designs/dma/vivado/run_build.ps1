# run_build.ps1 -- launch vivado/build.tcl in batch mode (log/journal -> vivado/build/)
#   powershell -File vivado/run_build.ps1                # 125 MHz (8.0 ns)
#   powershell -File vivado/run_build.ps1 9.0 p9_000     # same flow at another period
#   powershell -File vivado/run_build.ps1 8.0 explore explore   # Explore directives
# The Vivado log is copied next to the reports (vivado/reports/[<tag>/]vivado.log).
param([string]$Period = "", [string]$Tag = "", [string]$Flow = "")
$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$vivado = if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" }
$name   = if ($Tag) { "vivado_$Tag" } else { "vivado" }
New-Item -ItemType Directory -Force (Join-Path $here "build") | Out-Null
# relative -source path: vivado.bat mangles absolute paths containing spaces
Push-Location (Join-Path $here "build")
try {
  $tclargs = @(); if ($Period) { $tclargs = @("-tclargs", $Period); if ($Tag) { $tclargs += $Tag; if ($Flow) { $tclargs += $Flow } } }
  & $vivado -mode batch -nojournal -log "$name.log" -source ../build.tcl @tclargs
  $rc = $LASTEXITCODE
  $rpt = Join-Path $here "reports"; if ($Tag) { $rpt = Join-Path $rpt $Tag }
  if (Test-Path $rpt) { Copy-Item "$name.log" (Join-Path $rpt "vivado.log") -Force }
  exit $rc
} finally { Pop-Location }
