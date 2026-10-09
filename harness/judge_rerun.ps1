<#
.SYNOPSIS
  Gate G1/G5 check: re-run a cell's committed flow + xsim scripts from a clean
  checkout of its branch (worktree ..\wt\judge-<arm>-<design>), logging to
  results\judge\<arm>-<design>\. Launch detached; prints "JUDGE DONE" at the end.
#>
param(
  [Parameter(Mandatory)][ValidateSet('ross','plain')] [string]$Arm,
  [Parameter(Mandatory)][ValidateSet('i3c','fpga-scope','dma')] [string]$Design,
  [string[]]$FlowCmd,    # override: commands to run (relative to designs\<design>)
  [string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin'
)
$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$branch = "$Arm/$Design"
$wt = Join-Path $repo "..\wt\judge-$Arm-$Design"
$out = Join-Path $repo "results\judge\$Arm-$Design"
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out 'judge.log'
function Log($m) { $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m; $line | Tee-Object -FilePath $log -Append | Write-Host }

if (Test-Path $wt) { git -C $repo worktree remove --force $wt | Out-Null }
git -C $repo worktree add --detach $wt $branch 2>&1 | ForEach-Object { Log $_ }
$work = Join-Path $wt "designs\$Design"
Log "judge worktree $wt @ $(git -C $wt rev-parse --short HEAD)"

[Environment]::SetEnvironmentVariable('PATH', "$VivadoBin;" + [Environment]::GetEnvironmentVariable('PATH'), 'Process')
$env:PATH = "$VivadoBin;$env:PATH"
Push-Location $work
try {
  $i = 0
  foreach ($cmd in $FlowCmd) {
    $i++
    $clog = Join-Path $out "step$i.log"
    $cmd = $cmd -replace '^(vivado|xvlog|xelab|xsim)\.bat', ("`"$VivadoBin\" + '$1.bat"')   # absolute tool path
    Log "step $i START: $cmd"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    cmd /c "$cmd" > $clog 2>&1
    Log ("step $i END exit={0} after {1:n0}s (log: step$i.log)" -f $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
  }
  Log "git status after re-run:"
  git status --short | ForEach-Object { Log "  $_" }
} finally { Pop-Location }
Log "JUDGE DONE"
