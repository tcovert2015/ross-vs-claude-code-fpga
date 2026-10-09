# run_xsim.ps1 — fpga-scope self-checking testbenches under AMD Vivado xsim.
#
# The xsim counterpart of sim/run.sh (Verilator). One xvlog/xelab/xsim build+run per
# testbench; the full simulator transcript is saved to sim/xsim_<tb>.log. A testbench passes
# iff its log contains "TB_RESULT: PASS" and no "TB_RESULT: FAIL" / "Fatal:" / "ERROR:" line.
# Exit code is non-zero if any testbench fails.
#
#   pwsh sim/run_xsim.ps1                       # default set
#   pwsh sim/run_xsim.ps1 -Tb tb_csr_if         # a subset
#   pwsh sim/run_xsim.ps1 -VivadoBin D:\Xilinx\2025.2\Vivado\bin
#
# Golden vectors: tb_csr $readmemh's two scope_ref.py capture vector sets (the same ones
# run.sh generates), so they are generated here first (python, stdlib only). tb_smoke,
# tb_csr_if and tb_axil_top need none.
param(
    [string[]]$Tb = @('tb_smoke', 'tb_csr', 'tb_csr_if', 'tb_axil_top'),
    [string]$VivadoBin = $(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\AMDDesignTools\2025.2\Vivado\bin' }),
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'

$Root  = Split-Path -Parent $PSScriptRoot
$Sim   = Join-Path $Root 'sim'
$Vec   = Join-Path $Sim 'build\vectors'

# Same source order as run.sh COMMON_SRCS (package first), plus the Vivado wrapper top.
$Srcs = @(
    'rtl/scope_pkg.sv',
    'rtl/prim/prim_ff_sync.sv', 'rtl/prim/prim_ram_1r1w.sv',
    'rtl/prim/prim_fifo_sync.sv', 'rtl/prim/prim_fifo_async.sv',
    'rtl/scope_core.sv', 'rtl/scope_csr.sv', 'rtl/scope_trigger.sv', 'rtl/scope_rle.sv',
    'rtl/scope_drain.sv', 'rtl/xport/scope_uart.sv', 'rtl/scope_top.sv',
    'rtl/if/scope_avalon.sv', 'rtl/if/scope_axil.sv', 'rtl/if/scope_jtag.sv',
    'fpga/xilinx/scope_axil_top.sv'
) | ForEach-Object { Join-Path $Root $_ }

function Invoke-Tool([string]$Exe, [string[]]$ToolArgs, [string]$Log) {
    # run a Vivado .bat tool, append stdout+stderr to $Log, return its exit code
    $out = $null | & (Join-Path $VivadoBin $Exe) @ToolArgs 2>&1 | ForEach-Object { "$_" }
    $out | Add-Content -Path $Log -Encoding utf8
    return $LASTEXITCODE
}

# ---- golden vectors (tb_csr only) -----------------------------------------------------------
if ($Tb -contains 'tb_csr') {
    New-Item -ItemType Directory -Force $Vec | Out-Null
    $ref = Join-Path $Sim 'model\scope_ref.py'
    & $Python $ref capture --probe-w 32 --depth-log2 8 --pretrig 0 --trig-sample 128 `
        --count 640 --seed 0xC0FFEE01 --out-prefix (Join-Path $Vec 'cap_w32_d8')
    if ($LASTEXITCODE -ne 0) { Write-Output 'TB_RESULT: FAIL (scope_ref.py)'; exit 1 }
    & $Python $ref capture --probe-w 512 --depth-log2 10 --pretrig 0 --trig-sample 512 `
        --count 2560 --seed 0xC0FFEE02 --out-prefix (Join-Path $Vec 'cap_w512_d10')
    if ($LASTEXITCODE -ne 0) { Write-Output 'TB_RESULT: FAIL (scope_ref.py)'; exit 1 }
}

$overall = 0
$summary = @()
foreach ($t in $Tb) {
    Write-Output '=================================================================='
    Write-Output "== xsim: $t"
    Write-Output '=================================================================='
    $log  = Join-Path $Sim "xsim_$t.log"
    Set-Content -Path $log -Value "# xsim regression log for $t (sim/run_xsim.ps1)" -Encoding utf8

    # All three tools run from the repo root: the TBs $readmemh golden vectors via
    # repo-root-relative paths (same convention as run.sh). xsim.dir and the tool journals
    # land there and are removed afterwards.
    Push-Location $Root
    try {
        # --timescale on xelab: RTL files carry no `timescale by convention (run.sh passes
        # --timescale 1ns/1ps to Verilator for the same reason).
        $rc = Invoke-Tool 'xvlog.bat' (@('--sv', '--nolog', '--work', 'work') + $Srcs + (Join-Path $Sim "$t.sv")) $log
        if ($rc -eq 0) {
            $rc = Invoke-Tool 'xelab.bat' @('--nolog', '--timescale', '1ns/1ps', '--debug', 'off',
                                            '--snapshot', "${t}_snap", "work.$t") $log
        }
        if ($rc -eq 0) {
            $rc = Invoke-Tool 'xsim.bat' @("${t}_snap", '--nolog', '--runall', '--onerror', 'quit',
                                           '--onfinish', 'quit') $log
        }
    } finally {
        foreach ($junk in 'xsim.dir', 'xsim.jou', 'xvlog.pb', 'xelab.pb', 'webtalk.jou', "${t}_snap.wdb") {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $Root $junk)
        }
        Get-ChildItem $Root -Filter 'xsim*.backup.jou' -ErrorAction SilentlyContinue | Remove-Item -Force
        Pop-Location
    }

    $text = Get-Content -Raw $log
    $pass = ($rc -eq 0) -and ($text -match 'TB_RESULT: PASS') -and
            ($text -notmatch 'TB_RESULT: FAIL') -and ($text -notmatch '(?m)^(Fatal:|ERROR:)')
    Get-Content $log | Select-String -Pattern '^(-- |TB_RESULT|Fatal:|ERROR:|WARNING:)' | ForEach-Object { $_.Line }
    if ($pass) { $summary += "PASS  $t" } else { $summary += "FAIL  $t  (see $log)"; $overall = 1 }
}

Write-Output '=================================================================='
$summary | ForEach-Object { Write-Output $_ }
if ($overall -eq 0) { Write-Output 'ALL XSIM TESTBENCHES PASSED' } else { Write-Output 'ONE OR MORE XSIM TESTBENCHES FAILED' }
exit $overall
