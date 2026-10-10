<#
.SYNOPSIS
  Run one benchmark cell: (arm, design) as a headless Claude Code session.

.DESCRIPTION
  arm = ross  : Claude Code + AMD Ross plugin (skills) + Vivado MCP + amd-doc-search MCP
  arm = plain : Claude Code with NO plugin and NO MCP servers (drives vivado.bat itself)

  Both arms get the identical prompt (harness/prompts/<design>.md), the same model,
  the same budget cap, and start from the same baseline commit in their own git
  worktree on branch <arm>/<design>. Output (stream-json transcript + summary) lands
  in results/<arm>/<design>/.

.EXAMPLE
  .\harness\run_arm.ps1 -Arm ross  -Design i3c
  .\harness\run_arm.ps1 -Arm plain -Design i3c -Model opus -BudgetUsd 30
#>
param(
  [Parameter(Mandatory)][ValidateSet('ross','plain','ross-nudged','lattice','plain-lattice')] [string]$Arm,
  [Parameter(Mandatory)][ValidateSet('i3c','fpga-scope','dma','dma-close','i3c-async','scope-board','docs-grounded')] [string]$Design,
  [string]$Round = '',                  # '' = round-1/2 prompts; 'round3' = harness\prompts\round3\<Design>.md
  [string]$Model = 'opus',
  [double]$BudgetUsd = 40,
  [int]$MaxTurns = 400,
  [string]$RossPluginDir = 'D:\AMD Ross Test\ross-ai-assistant',
  [string]$LatticeSkillsDir = (Join-Path $env:USERPROFILE '.claude\plugins\marketplaces\local-desktop-app-uploads\lattice-radiant-skills\lattice-radiant-skills'),
  [string]$Baseline = 'main',
  [switch]$DryRun                       # print the resolved claude arguments and exit
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$branch = "$Arm/$Design"
$wt = Join-Path $repo "..\wt\$Arm-$Design"
$out = Join-Path $repo "results\$Arm\$Design"
New-Item -ItemType Directory -Force $out | Out-Null

# Fresh worktree from baseline so both arms start from byte-identical sources.
if (-not (Test-Path $wt)) {
  git -C $repo worktree add -B $branch $wt $Baseline | Out-Null
}
# Round-3 tasks are built on one of the three base designs (docs-grounded has no RTL: worktree root).
$baseDesign = switch ($Design) {
  'dma-close'     { 'dma' }
  'i3c-async'     { 'i3c' }
  'scope-board'   { 'fpga-scope' }
  'docs-grounded' { '' }
  default         { $Design }
}
$work = if ($baseDesign) { Join-Path $wt "designs\$baseDesign" } else { $wt }

$promptFile = if ($Round) { "harness\prompts\$Round\$Design.md" }
              elseif ($Arm -like '*lattice*') { "harness\prompts\lattice\$Design.md" }
              else { "harness\prompts\$Design.md" }
$prompt = Get-Content (Join-Path $repo $promptFile) -Raw
if ($Arm -eq 'ross-nudged') {
  # Third arm: identical prompt + an explicit requirement to use the Ross tooling, so the
  # benchmark measures the tools in use rather than whether the agent discovers them.
  $prompt += "`n`n" + (Get-Content (Join-Path $repo 'harness\prompts\_nudge.md') -Raw)
}
$issueNote = "`n`nThis is GitHub issue '$branch' in repo tcovert2015/ross-vs-claude-code-fpga. You are on branch $branch in a git worktree whose root is $wt. Your working directory is $work."

$common = @(
  '-p', ($prompt + $issueNote),
  '--model', $Model,
  '--output-format', 'stream-json', '--verbose',
  '--permission-mode', 'bypassPermissions',
  '--max-turns', $MaxTurns,
  '--max-budget-usd', $BudgetUsd,
  '--no-chrome',
  '--strict-mcp-config',
  # Headless runs end when the turn ends: a "wake me later" tool silently kills the cell
  # (lattice/dma did exactly that on 2026-10-09). Applies to every arm.
  '--disallowedTools', 'ScheduleWakeup',
  '--setting-sources', 'project'    # ignore user-level plugins/hooks so the plain arm is really plain
)
if ($Arm -eq 'ross' -or $Arm -eq 'ross-nudged') {
  $sys = if ($Arm -eq 'ross') {
    'The AMD Ross agent skills and the Vivado MCP server (vivado_* tools) and amd-doc-search MCP are available in this session. Use them for Vivado work where they apply.'
  } else {
    'This session is the AMD Ross arm of a tooling benchmark. All Vivado and xsim work MUST go through the Vivado MCP server (vivado_start once, then vivado_execute for every Tcl step; vivado_log_messages / vivado_status to inspect). Do not launch vivado.bat, xvlog.bat, xelab.bat or xsim.bat from Bash or PowerShell. Use the Ross skills (/ross-ai-assistant:vivado-rtl-lint, /ross-ai-assistant:vivado-timing-methodology-checks, /ross-ai-assistant:vivado-simulate-rtl, /ross-ai-assistant:vivado-rtl-elaboration-analysis) at the matching steps, and amd-doc-search when you need Vivado documentation.'
  }
  $args_ = $common + @(
    '--mcp-config', (Join-Path $repo 'harness\mcp-ross.json'),
    '--plugin-dir', $RossPluginDir,
    '--append-system-prompt', $sys
  )
} elseif ($Arm -eq 'lattice') {
  # Lattice Prompt arm: the two Lattice skills (as a plugin) + the lattice-radiant-mcp server.
  # The automation skill itself tells the agent to load the MCP tools at session start, so
  # tool discovery is part of what this arm measures (no extra nudge).
  $args_ = $common + @(
    '--mcp-config', (Join-Path $repo 'harness\mcp-lattice.json'),
    '--plugin-dir', $LatticeSkillsDir,
    '--append-system-prompt', 'The Lattice Prompt skills (lattice-radiant-automation, lattice-radiant-webdocs) and the lattice-radiant-mcp MCP server are available in this session. Use them for Radiant work where they apply.'
  )
} else {
  # plain / plain-lattice: no plugin, no MCP; the agent drives the tools itself.
  $args_ = $common + @('--mcp-config', (Join-Path $repo 'harness\mcp-none.json'), '--disable-slash-commands')
}

Write-Host ("claude args: " + (($args_ | ForEach-Object { if ($_ -match '\s') { '"' + $_.Substring(0, [Math]::Min(80, $_.Length)) + '"' } else { $_ } }) -join ' '))
if ($DryRun) { exit 0 }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = Join-Path $out "transcript-$stamp.jsonl"
$meta = [ordered]@{ arm=$Arm; design=$Design; model=$Model; branch=$branch; worktree=$wt; started=(Get-Date).ToString('o') }
$meta | ConvertTo-Json | Set-Content (Join-Path $out "meta-$stamp.json")

Push-Location $work
try {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & claude @args_ 2> (Join-Path $out "stderr-$stamp.log") | Tee-Object -FilePath $transcript | ForEach-Object {
    # Light progress echo: show tool names and the final result line.
    try { $j = $_ | ConvertFrom-Json } catch { return }
    if ($j.type -eq 'assistant') {
      foreach ($c in $j.message.content) { if ($c.type -eq 'tool_use') { Write-Host ("[{0,7:n0}s] tool: {1}" -f $sw.Elapsed.TotalSeconds, $c.name) } }
    } elseif ($j.type -eq 'result') {
      Write-Host ("[{0,7:n0}s] RESULT turns={1} cost=`${2} subtype={3}" -f $sw.Elapsed.TotalSeconds, $j.num_turns, $j.total_cost_usd, $j.subtype)
    }
  }
  $sw.Stop()
} finally { Pop-Location }

# Summarise: cost, turns, duration, tool-call histogram, git stats.
python (Join-Path $repo 'harness\summarize.py') $transcript $wt $Design | Tee-Object -FilePath (Join-Path $out "summary-$stamp.md")
