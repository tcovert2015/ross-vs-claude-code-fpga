# SPDX-License-Identifier: Apache-2.0
#============================================================================
# run_xsim.ps1 -- Vivado xsim port of scripts/run_sim.sh for the AXI4 system bus.
#
#   powershell -ExecutionPolicy Bypass -File scripts/run_xsim.ps1
#   $env:SIM_SEEDS = "1 2 3 4"; powershell -File scripts/run_xsim.ps1   # custom sweep
#
# Compiles + elaborates tb_pcie_dma once per configuration (AXI4, AXI4+STALLS),
# then runs it under every seed in $env:SIM_SEEDS (default "1 2 3") via the
# +SEED plusarg. Pass criterion is the same as run_sim.sh: the simulation output
# must contain "=== PASS". Logs: sim/build/xsim_<cfg>_seed<n>.log.
# Exits non-zero if any (config, seed) fails.
#============================================================================
$ErrorActionPreference = "Continue"
$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vbin   = if ($env:VIVADO_BIN_DIR) { $env:VIVADO_BIN_DIR } else { "C:\AMDDesignTools\2025.2\Vivado\bin" }
$seeds  = if ($env:SIM_SEEDS) { $env:SIM_SEEDS -split '\s+' } else { @("1", "2", "3") }
$build  = Join-Path $root "sim\build"

# sources relative to the per-config work dir sim/build/xsim_<cfg>/ (relative
# paths keep the xsim tools working when the checkout path contains spaces)
$rtl = @(
  "rtl/pkg/dma_pkg.sv",
  "rtl/core/dma_fifo.sv", "rtl/core/dma_arbiter.sv", "rtl/core/dma_csr.sv",
  "rtl/core/dma_descriptor_fetch.sv", "rtl/core/dma_data_mover.sv", "rtl/core/dma_engine_core.sv",
  "rtl/core/reset_sync.sv",
  "rtl/adapters/gmm_to_avalon.sv", "rtl/adapters/gmm_to_axi4.sv", "rtl/adapters/gmm_to_ahb.sv",
  "rtl/top/pcie_dma_top.sv",
  "sim/models/avalon_mem_model.sv", "sim/models/axi_mem_model.sv", "sim/models/ahb_mem_model.sv",
  "sim/tb_pcie_dma.sv"
) | ForEach-Object { "../../../$_" }

$configs = @(
  @{ Name = "AXI4          "; Cfg = "axi4";        Defs = @("USE_AXI") },
  @{ Name = "AXI4   +stalls"; Cfg = "axi4_stalls"; Defs = @("USE_AXI", "STALLS") }
)

$rc = 0
foreach ($c in $configs) {
  $work = Join-Path $build "xsim_$($c.Cfg)"
  New-Item -ItemType Directory -Force $work | Out-Null
  Push-Location $work
  try {
    $defs = $c.Defs | ForEach-Object { "-d"; $_ }
    & "$vbin\xvlog.bat" -sv -i ../../../rtl/pkg @defs -log compile.log @rtl *> $null
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
      & "$vbin\xelab.bat" tb_pcie_dma -s tb_snap -timescale 1ns/1ps -log elaborate.log *> $null
      $ok = ($LASTEXITCODE -eq 0)
    }
    if (-not $ok) {
      Write-Output "$($c.Name): COMPILE FAIL"
      Get-Content compile.log, elaborate.log -ErrorAction SilentlyContinue | Select-String "ERROR"
      $rc = 1
      continue
    }
    foreach ($s in $seeds) {
      $log = "../xsim_$($c.Cfg)_seed$s.log"
      # plusarg goes through an options file: cmd.exe splits "SEED=n" at the '='
      # when it is passed on the xsim.bat command line
      Set-Content "seed$s.f" "-testplusarg SEED=$s"
      & "$vbin\xsim.bat" tb_snap -R -f "seed$s.f" -log $log *> $null
      if (Select-String -Path $log -Pattern "=== PASS" -SimpleMatch -Quiet) {
        Write-Output "$($c.Name) seed=${s}: PASS"
      } else {
        Write-Output "$($c.Name) seed=${s}: FAIL"
        Get-Content $log -Tail 8
        $rc = 1
      }
    }
  } finally { Pop-Location }
}
exit $rc
