# run_all.ps1 — run build.tcl for every (PROBE_W, DEPTH_LOG2) configuration, in parallel.
#
#   pwsh fpga/xilinx/run_all.ps1                         # (32,8) (32,12) (32,15)
#   pwsh fpga/xilinx/run_all.ps1 -Configs '64,10','128,12'
#
# Each configuration runs in its own scratch directory fpga/xilinx/build/pw<W>_d<N>/ (ignored
# by git); build.tcl writes the reports to fpga/xilinx/reports/pw<W>_d<N>/ and this script
# copies the full Vivado log next to them (reports/<cfg>/vivado.log) so every number is
# traceable. Exits non-zero if any configuration fails.
param(
    [string[]]$Configs = @('32,8', '32,12', '32,15'),
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Start-Build([string]$pw, [string]$dl) {
    $cfg = "pw${pw}_d${dl}"
    $bdir = Join-Path $here "build\$cfg"
    Remove-Item -Recurse -Force $bdir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $here "reports\$cfg") -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $bdir | Out-Null
    # relative -source path: the scratch dir is always two levels below build.tcl
    $cmd = "`"$Vivado`" -mode batch -nojournal -log vivado.log -source ..\..\build.tcl -tclargs $pw $dl > run.out 2>&1"
    Write-Host "== launching $cfg"
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WorkingDirectory $bdir `
        -NoNewWindow -PassThru
    return [pscustomobject]@{ Cfg = $cfg; Pw = $pw; Dl = $dl; Proc = $p; Dir = $bdir }
}

# true when the build ran to the end; copies the Vivado log next to the reports
function Complete-Build($j) {
    $j.Proc.WaitForExit()
    $rpt = Join-Path $here "reports\$($j.Cfg)"
    $log = Join-Path $j.Dir 'vivado.log'
    if (-not ((Test-Path $log) -and (Select-String -Path $log -Pattern "^BUILD_DONE $($j.Cfg) " -Quiet))) {
        return $false
    }
    Copy-Item $log (Join-Path $rpt 'vivado.log') -Force
    Write-Host "PASS  $($j.Cfg)  $((Get-Content (Join-Path $rpt 'summary.txt'))[1..2] -join '  ')"
    return $true
}

$jobs = @()
foreach ($c in $Configs) {
    $pw, $dl = $c -split ','
    $jobs += Start-Build $pw $dl
}

$fail = 0
foreach ($j in $jobs) {
    if (Complete-Build $j) { continue }
    # Vivado on Windows occasionally dies with "[Designutils 20-411] The directory ...\.Xil\...
    # could not be deleted and may be locked" (a transient lock on its own scratch dir, seen
    # when several instances start together). Retry ONLY that failure, once, on its own.
    $log = Join-Path $j.Dir 'vivado.log'
    $locked = (Test-Path $log) -and (Select-String -Path $log -Pattern 'Designutils 20-411' -Quiet)
    if ($locked) {
        Write-Host "RETRY $($j.Cfg)  (transient .Xil directory lock, Designutils 20-411)"
        if (Complete-Build (Start-Build $j.Pw $j.Dl)) { continue }
    }
    Write-Host "FAIL  $($j.Cfg)  (see $log)"
    $fail = 1
}
exit $fail
