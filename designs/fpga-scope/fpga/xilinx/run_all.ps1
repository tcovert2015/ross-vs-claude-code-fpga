# run_all.ps1 — run build.tcl for the README's three configurations and keep the logs.
#
#   pwsh fpga/xilinx/run_all.ps1                 # (32,8) (32,12) (32,15), one after another
#   pwsh fpga/xilinx/run_all.ps1 -Parallel       # all three at once (3 Vivado processes)
#   pwsh fpga/xilinx/run_all.ps1 -Configs '64,10','32,12'
#
# Each config runs `vivado -mode batch -source build.tcl -tclargs <PROBE_W> <DEPTH_LOG2>` from
# its own scratch dir fpga/xilinx/build/w<P>_d<D>/ (git-ignored), then the Vivado log is copied
# next to the reports as fpga/xilinx/reports/w<P>_d<D>/vivado.log. Exit code is non-zero if any
# config fails or does not write its summary.txt.
param(
    [string[]]$Configs = @('32,8', '32,12', '32,15'),
    [string]$VivadoBin = $(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\AMDDesignTools\2025.2\Vivado\bin' }),
    [switch]$Parallel
)
$ErrorActionPreference = 'Stop'
$XDir   = $PSScriptRoot
$Vivado = Join-Path $VivadoBin 'vivado.bat'

$jobs = foreach ($c in $Configs) {
    $pw, $dl = $c -split ','
    $cfg = "w${pw}_d${dl}"
    $bld = Join-Path $XDir "build\$cfg"
    $rpt = Join-Path $XDir "reports\$cfg"
    if (Test-Path $bld) { Remove-Item -Recurse -Force $bld }
    if (Test-Path $rpt) { Remove-Item -Recurse -Force $rpt }
    New-Item -ItemType Directory -Force $bld | Out-Null
    Set-Content -Path (Join-Path $bld 'stdin.txt') -Value 'exit'   # never sit at a Tcl prompt
    Write-Host "== launching $cfg"
    $p = Start-Process -FilePath $Vivado -WorkingDirectory $bld -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $bld 'stdout.txt') -RedirectStandardInput (Join-Path $bld 'stdin.txt') `
        -ArgumentList @('-mode', 'batch', '-nojournal', '-log', 'vivado.log',
                        '-source', '..\..\build.tcl', '-tclargs', $pw, $dl)
    $null = $p.Handle   # keep the handle so ExitCode is available after exit
    # sequential: wait. parallel: stagger the launches (simultaneous Vivado start-ups race on
    # creating the per-user settings dir and one of them logs a spurious "Failed to create directory")
    if (-not $Parallel) { $p.WaitForExit() } else { Start-Sleep -Seconds 8 }
    [pscustomobject]@{ Cfg = $cfg; Proc = $p; Bld = $bld; Rpt = $rpt }
}

$overall = 0
foreach ($j in $jobs) {
    $j.Proc.WaitForExit()
    $ok = ($j.Proc.ExitCode -eq 0) -and (Test-Path (Join-Path $j.Rpt 'summary.txt'))
    if (Test-Path (Join-Path $j.Bld 'vivado.log')) {
        New-Item -ItemType Directory -Force $j.Rpt | Out-Null
        Copy-Item -Force (Join-Path $j.Bld 'vivado.log') (Join-Path $j.Rpt 'vivado.log')
    }
    Write-Output '=================================================================='
    if ($ok) {
        Write-Output "PASS  $($j.Cfg)"
        Get-Content (Join-Path $j.Rpt 'summary.txt')
    } else {
        Write-Output "FAIL  $($j.Cfg)  (exit $($j.Proc.ExitCode); see $(Join-Path $j.Bld 'vivado.log'))"
        $overall = 1
    }
}
exit $overall
