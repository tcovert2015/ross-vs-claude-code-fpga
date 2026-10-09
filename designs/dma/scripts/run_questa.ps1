# SPDX-License-Identifier: Apache-2.0
#============================================================================
# run_questa.ps1 -- compile + run the self-checking testbench in the QuestaSim
# Lattice Edition bundled with Radiant, for the AXI4 system bus with and
# without bus back-pressure. Questa counterpart of scripts/run_sim.sh.
#
#   pwsh scripts/run_questa.ps1                 # AXI4 and AXI4+STALLS, seeds 1 2 3
#   pwsh scripts/run_questa.ps1 -Seeds 1,2,3,4  # custom seed sweep
#   $env:RADIANT_HOME = 'D:\lscc\radiant\2026.1'  # override the Radiant install
#
# Each configuration is compiled once; the TB is then run under every seed
# (+SEED plusarg). Same pass criterion as run_sim.sh: the run log must contain
# "=== PASS". Logs go to sim/build/questa_<cfg>_seed<n>.log (compile log:
# sim/build/questa_<cfg>_compile.log). Exits non-zero if any (config, seed)
# fails.
#
# -suppress 7061: the TB backdoor-loads / clears the memory models' `mem`
# arrays hierarchically (host_mem.mem[..] = ...), and the models also write
# `mem` from an always_ff. Questa flags that as a suppressible error
# (vopt-7061, IEEE 1800 always_ff single-driver rule); Icarus accepts it. The
# backdoor access is intentional testbench behaviour, so the check is
# suppressed here instead of editing the testbench or the models.
#============================================================================
param(
  [int[]]$Seeds = @(1, 2, 3)
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$radiant = if ($env:RADIANT_HOME) { $env:RADIANT_HOME } else { 'D:\lscc\radiant\2026.1' }
$qbin = Join-Path $radiant 'questasim\win64'
foreach ($t in 'vlib', 'vlog', 'vsim') {
  if (-not (Test-Path (Join-Path $qbin "$t.exe"))) {
    Write-Host "ERROR: $t.exe not found under $qbin (set RADIANT_HOME)"; exit 2
  }
}

$build = Join-Path $root 'sim\build'
New-Item -ItemType Directory -Force $build | Out-Null

# same file list / order as scripts/run_sim.sh
$rtl = @(
  'rtl/pkg/dma_pkg.sv',
  'rtl/core/dma_fifo.sv', 'rtl/core/dma_arbiter.sv', 'rtl/core/dma_csr.sv',
  'rtl/core/dma_descriptor_fetch.sv', 'rtl/core/dma_data_mover.sv', 'rtl/core/dma_engine_core.sv',
  'rtl/core/reset_sync.sv',
  'rtl/adapters/gmm_to_avalon.sv', 'rtl/adapters/gmm_to_axi4.sv', 'rtl/adapters/gmm_to_ahb.sv',
  'rtl/top/pcie_dma_top.sv',
  'sim/models/avalon_mem_model.sv', 'sim/models/axi_mem_model.sv', 'sim/models/ahb_mem_model.sv',
  'sim/tb_pcie_dma.sv'
)

$configs = @(
  @{ Name = 'AXI4         '; Tag = 'axi4';        Defs = @('USE_AXI') },
  @{ Name = 'AXI4  +stalls'; Tag = 'axi4_stalls'; Defs = @('USE_AXI', 'STALLS') }
)

$rc = 0
foreach ($cfg in $configs) {
  $lib  = "sim/build/questa_$($cfg.Tag)_work"
  $clog = "sim/build/questa_$($cfg.Tag)_compile.log"
  if (Test-Path $lib) { Remove-Item -Recurse -Force $lib }
  & "$qbin\vlib.exe" $lib | Out-Null
  $defs = @($cfg.Defs | ForEach-Object { "+define+$_" })
  & "$qbin\vlog.exe" -sv -quiet -work $lib '+incdir+rtl/pkg' @defs @rtl -l $clog | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "$($cfg.Name): COMPILE FAIL"; Get-Content $clog; $rc = 1; continue
  }
  foreach ($s in $Seeds) {
    $log = "sim/build/questa_$($cfg.Tag)_seed$s.log"
    & "$qbin\vsim.exe" -c -lib $lib -suppress 7061 tb_pcie_dma "+SEED=$s" -l $log -do 'run -all; quit -f' | Out-Null
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern '=== PASS' -Quiet)) {
      Write-Host "$($cfg.Name) seed=${s}: PASS"
    } else {
      Write-Host "$($cfg.Name) seed=${s}: FAIL"
      if (Test-Path $log) { Get-Content $log -Tail 8 }
      $rc = 1
    }
  }
}

exit $rc
