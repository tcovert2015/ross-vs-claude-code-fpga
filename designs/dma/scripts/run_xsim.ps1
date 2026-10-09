# SPDX-License-Identifier: Apache-2.0
#============================================================================
# run_xsim.ps1 -- compile + run the self-checking testbench in AMD Vivado xsim
# (the xsim counterpart of scripts/run_sim.sh, for the AXI4 system bus).
#
#   scripts\run_xsim.bat                      # all configurations, seeds 1 2 3
#   scripts\run_xsim.bat AXI4_STALLS          # one configuration
#   $env:SIM_SEEDS="1 2 3 4"; scripts\run_xsim.bat   # custom seed sweep
#
# Configurations (name -> +define+):
#   AXI4          USE_AXI
#   AXI4_STALLS   USE_AXI STALLS
#   AXI4_RSTSYNC  USE_AXI RESET_SYNC_EN   (RESET_SYNC=1, the parameterization
#                                          built by vivado/build.tcl)
#
# Each configuration is compiled/elaborated once (xvlog + xelab) and then run
# once per seed (+SEED=<n>). Pass criterion is the same as run_sim.sh: the run
# log must contain "=== PASS". Logs: sim/build/xsim_<cfg>_seed<n>.log.
# Exits non-zero if any (config, seed) fails.
#
# Tool location: %XILINX_VIVADO%\bin, else C:\AMDDesignTools\2025.2\Vivado\bin.
#============================================================================
param([string[]]$Configs)

# native tools write progress to stderr; do not let PowerShell treat that as fatal
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$bld  = Join-Path $root 'sim\build'
New-Item -ItemType Directory -Force $bld | Out-Null

if ($env:XILINX_VIVADO) { $bin = Join-Path $env:XILINX_VIVADO 'bin' }
else                    { $bin = 'C:\AMDDesignTools\2025.2\Vivado\bin' }
foreach ($t in 'xvlog.bat', 'xelab.bat', 'xsim.bat') {
  if (-not (Test-Path (Join-Path $bin $t))) { Write-Host "run_xsim: $t not found in $bin"; exit 2 }
}

if ($env:SIM_SEEDS) { $seeds = $env:SIM_SEEDS -split '\s+' | Where-Object { $_ } }
else                { $seeds = '1', '2', '3' }

$allCfg = [ordered]@{
  'AXI4'         = @('USE_AXI')
  'AXI4_STALLS'  = @('USE_AXI', 'STALLS')
  'AXI4_RSTSYNC' = @('USE_AXI', 'RESET_SYNC_EN')
}
if (-not $Configs) { $Configs = @($allCfg.Keys) }

# same file list / order as scripts/run_sim.sh (paths relative to the work dir)
$src = @(
  'rtl/pkg/dma_pkg.sv',
  'rtl/core/dma_fifo.sv', 'rtl/core/dma_arbiter.sv', 'rtl/core/dma_csr.sv',
  'rtl/core/dma_descriptor_fetch.sv', 'rtl/core/dma_data_mover.sv', 'rtl/core/dma_engine_core.sv',
  'rtl/core/reset_sync.sv',
  'rtl/adapters/gmm_to_avalon.sv', 'rtl/adapters/gmm_to_axi4.sv', 'rtl/adapters/gmm_to_ahb.sv',
  'rtl/top/pcie_dma_top.sv',
  'sim/models/avalon_mem_model.sv', 'sim/models/axi_mem_model.sv', 'sim/models/ahb_mem_model.sv',
  'sim/tb_pcie_dma.sv'
) | ForEach-Object { "../../../$_" }

$rc = 0
foreach ($cfg in $Configs) {
  if (-not $allCfg.Contains($cfg)) {
    Write-Host "usage: run_xsim [$(@($allCfg.Keys) -join '|')] ..."; exit 1
  }
  # per-configuration work dir so xsim.dir snapshots never collide
  $work = Join-Path $bld "xsim_work_$cfg"
  if (Test-Path $work) { Remove-Item -Recurse -Force $work }
  New-Item -ItemType Directory -Force $work | Out-Null
  Push-Location $work
  try {
    $defs = @(); foreach ($d in $allCfg[$cfg]) { $defs += '-d'; $defs += $d }
    & "$bin\xvlog.bat" -sv -nolog -i ../../../rtl/pkg @defs @src > compile.log 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
      & "$bin\xelab.bat" -nolog -timescale 1ns/1ps -debug off -s tb_snap tb_pcie_dma >> compile.log 2>&1
      $ok = ($LASTEXITCODE -eq 0)
    }
    if (-not $ok) {
      Write-Host "$cfg : COMPILE FAIL"; Get-Content compile.log | Select-Object -Last 20
      $rc = 1; continue
    }
    foreach ($s in $seeds) {
      $log = "xsim_${cfg}_seed$s.log"
      # plusarg goes through an option file: cmd.exe (xsim.bat) would split
      # a command-line "SEED=<n>" at the '='
      Set-Content -Encoding ASCII run.f "-testplusarg SEED=$s"
      & "$bin\xsim.bat" tb_snap -R -log "../$log" -f run.f > run.out 2>&1
      $simrc = $LASTEXITCODE
      if (($simrc -eq 0) -and (Select-String -Path "..\$log" -Pattern '=== PASS' -Quiet)) {
        Write-Host "$cfg seed=$s : PASS"
      } else {
        Write-Host "$cfg seed=$s : FAIL"; Get-Content "..\$log" | Select-Object -Last 8
        $rc = 1
      }
    }
  } finally { Pop-Location }
}
exit $rc
