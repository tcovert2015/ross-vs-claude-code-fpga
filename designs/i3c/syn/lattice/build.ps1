# Run the Radiant flow (syn/lattice/build.tcl) and keep the full console output,
# which carries the Radiant-side messages that are not in the per-tool reports.
#   powershell -File syn/lattice/build.ps1      # -> syn/lattice/reports/*
param(
  [string]$Radiant = $(if ($env:RADIANT_HOME) { $env:RADIANT_HOME } else { 'D:\lscc\radiant\2026.1' })
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'reports') | Out-Null
& (Join-Path $Radiant 'bin\nt64\radiantc.exe') (Join-Path $PSScriptRoot 'build.tcl') 2>&1 |
  Tee-Object -FilePath (Join-Path $PSScriptRoot 'reports\build_console.log')
exit $LASTEXITCODE
