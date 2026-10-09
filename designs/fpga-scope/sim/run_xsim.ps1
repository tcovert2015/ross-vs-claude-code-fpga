# run_xsim.ps1 — build + run the fpga-scope self-checking testbenches in AMD Vivado xsim.
#
# The xsim counterpart of sim/run.sh (Verilator). Same contract: every TB is self-checking and
# prints "TB_RESULT: PASS" on success; a mismatch calls $fatal and prints "TB_RESULT: FAIL".
# A TB passes here only if its log contains TB_RESULT: PASS and no TB_RESULT: FAIL / Fatal: /
# ERROR: line. The script exits non-zero if any TB fails.
#
#   pwsh sim/run_xsim.ps1                       # default set: tb_smoke tb_csr tb_csr_if tb_axil_top
#   pwsh sim/run_xsim.ps1 tb_csr tb_prim_ram    # any subset, by name
#   pwsh sim/run_xsim.ps1 -VivadoBin D:\Xilinx\Vivado\2025.2\bin
#
# Per-TB log (compile + elaborate + simulate): sim/xsim_<tb>.log
#
# Notes:
#   * Runs from the repo root (designs/fpga-scope): the TBs $readmemh their golden vectors via
#     root-relative paths, exactly as under run.sh. Only relative paths are handed to the
#     tools, so a checkout path containing spaces is fine.
#   * tb_csr compares the BUF_DATA drain against the scope_ref.py golden vectors, so the two
#     `capture` vector sets it loads are generated first (same commands as run.sh gen_vectors;
#     needs any `python` >= 3.8, stdlib only). tb_smoke / tb_csr_if need no vectors.
#   * RTL files carry no `timescale (repo convention), so the 1ns/1ps default is passed to
#     xelab — the counterpart of run.sh's `--timescale 1ns/1ps`.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Tbs = @('tb_smoke', 'tb_csr', 'tb_csr_if', 'tb_axil_top'),
    [string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$xvlog = Join-Path $VivadoBin 'xvlog.bat'
$xelab = Join-Path $VivadoBin 'xelab.bat'
$xsim  = Join-Path $VivadoBin 'xsim.bat'

# Source order mirrors run.sh COMMON_SRCS: package first, prims, core RTL, front-ends.
$srcs = @(
    'rtl/scope_pkg.sv',
    'rtl/prim/prim_ff_sync.sv',
    'rtl/prim/prim_ram_1r1w.sv',
    'rtl/prim/prim_fifo_sync.sv',
    'rtl/prim/prim_fifo_async.sv',
    'rtl/scope_core.sv',
    'rtl/scope_csr.sv',
    'rtl/scope_trigger.sv',
    'rtl/scope_rle.sv',
    'rtl/scope_drain.sv',
    'rtl/xport/scope_uart.sv',
    'rtl/scope_top.sv',
    'rtl/if/scope_avalon.sv',
    'rtl/if/scope_axil.sv',
    'rtl/if/scope_jtag.sv',
    'fpga/xilinx/scope_axil_top.sv'
)

# ---- golden vectors (the subset of run.sh gen_vectors used by tb_csr / tb_capture_basic) ----
$vec = 'sim/build/vectors'
New-Item -ItemType Directory -Force $vec | Out-Null
Write-Host '== Generating golden vectors (sim/model/scope_ref.py)'
& $Python sim/model/scope_ref.py capture --probe-w 32 --depth-log2 8 --pretrig 0 `
    --trig-sample 128 --count 640 --seed 0xC0FFEE01 --out-prefix "$vec/cap_w32_d8"
if ($LASTEXITCODE -ne 0) { Write-Host 'TB_RESULT: FAIL (scope_ref.py)'; exit 1 }
& $Python sim/model/scope_ref.py capture --probe-w 512 --depth-log2 10 --pretrig 0 `
    --trig-sample 512 --count 2560 --seed 0xC0FFEE02 --out-prefix "$vec/cap_w512_d10"
if ($LASTEXITCODE -ne 0) { Write-Host 'TB_RESULT: FAIL (scope_ref.py)'; exit 1 }

$overall = 0
$summary = @()
foreach ($tb in $Tbs) {
    $log = "sim/xsim_$tb.log"
    Write-Host '=================================================================='
    Write-Host "== xsim: $tb"
    Write-Host '=================================================================='
    Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue
    "### xvlog $tb" | Set-Content $log
    & $xvlog --sv --nolog -i rtl @srcs "sim/$tb.sv" 2>&1 | Add-Content $log
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
        "### xelab $tb" | Add-Content $log
        & $xelab --nolog --timescale 1ns/1ps --debug off -s "${tb}_sim" "work.$tb" 2>&1 |
            Add-Content $log
        $ok = ($LASTEXITCODE -eq 0)
    }
    if ($ok) {
        "### xsim $tb" | Add-Content $log
        & $xsim "${tb}_sim" --nolog --runall 2>&1 | Add-Content $log
        $ok = ($LASTEXITCODE -eq 0)
    }
    $text = Get-Content $log -Raw
    $pass = $ok -and ($text -match 'TB_RESULT: PASS') -and
            ($text -notmatch 'TB_RESULT: FAIL') -and ($text -notmatch '(?m)^(Fatal:|ERROR:)')
    Get-Content $log | Select-String -Pattern 'TB_RESULT|^-- |^Fatal:|^ERROR:' |
        ForEach-Object { Write-Host $_.Line }
    if ($pass) { $summary += "PASS  $tb" }
    else { $summary += "FAIL  $tb  (see $log)"; $overall = 1 }
}

# xsim scratch (regenerated every run)
Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue
Remove-Item -Force xvlog.pb, xelab.pb, xsim.jou, webtalk*.jou, webtalk*.log, *.wdb `
    -ErrorAction SilentlyContinue

Write-Host '=================================================================='
$summary | ForEach-Object { Write-Host $_ }
if ($overall -eq 0) { Write-Host 'ALL XSIM TESTBENCHES PASSED' }
else { Write-Host 'ONE OR MORE XSIM TESTBENCHES FAILED' }
exit $overall
