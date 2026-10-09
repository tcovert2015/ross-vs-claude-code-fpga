# build_all.ps1 — run build.tcl for the three README configurations (PROBE_W, DEPTH_LOG2).
# Console output of each run goes to build/<cfg>.console.log (git-ignored) and is copied to
# reports/<cfg>/console.txt next to the four tool reports.
param([string]$Radiant = "D:\lscc\radiant\2026.1")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force build | Out-Null
$rc = 0
foreach ($c in @(@(32, 8), @(32, 12), @(32, 15))) {
    $cfg = "w$($c[0])_d$($c[1])"
    & "$Radiant\bin\nt64\radiantc.exe" build.tcl $c[0] $c[1] *> "build\$cfg.console.log"
    Write-Host "$cfg exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { $rc = 1 }
    if (Test-Path "reports\$cfg") { Copy-Item "build\$cfg.console.log" "reports\$cfg\console.txt" -Force }
}
exit $rc
