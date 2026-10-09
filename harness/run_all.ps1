<#
.SYNOPSIS
  Queue runner: execute several (arm, design) cells with bounded parallelism,
  each as its own detached pwsh process, so they survive the launching shell.

.EXAMPLE
  pwsh -File harness\run_all.ps1 -Cells ross:i3c,plain:i3c,ross:dma,plain:dma,ross:fpga-scope,plain:fpga-scope -MaxParallel 4
#>
param(
  [string[]]$Cells = @('ross:i3c','plain:i3c','ross:dma','plain:dma','ross:fpga-scope','plain:fpga-scope'),
  [int]$MaxParallel = 4,
  [int]$PollSeconds = 30
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$results = Join-Path $repo 'results'
New-Item -ItemType Directory -Force $results | Out-Null
$log = Join-Path $results 'run_all.log'
function Log($m) { $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m; $line | Tee-Object -FilePath $log -Append | Write-Host }

$runArm = '"' + (Join-Path $repo 'harness\run_arm.ps1') + '"'   # quoted: repo path contains a space
$queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Cells)
$running = @{}
Log "queue: $($Cells -join ', ')  max-parallel=$MaxParallel"
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
  foreach ($k in @($running.Keys)) {
    $p = $running[$k]
    if ($p.HasExited) { Log "finished $k exit=$($p.ExitCode) after $([int]((Get-Date) - $p.StartTime).TotalMinutes) min"; $running.Remove($k) }
  }
  while ($queue.Count -gt 0 -and $running.Count -lt $MaxParallel) {
    $cell = $queue.Dequeue(); $arm, $design = $cell.Split(':')
    $out = Join-Path $results "$arm-$design.console.log"
    $err = Join-Path $results "$arm-$design.console.err"
    $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-NonInteractive','-File',$runArm,'-Arm',$arm,'-Design',$design) `
         -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
    $running[$cell] = $p
    Log "launched $cell pid=$($p.Id)"
  }
  Start-Sleep -Seconds $PollSeconds
}
Log "all cells done"
