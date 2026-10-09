# run_questa.ps1 — run the self-checking testbenches in the QuestaSim bundled with Lattice Radiant.
#
#   pwsh sim/run_questa.ps1                      # tb_smoke, tb_csr, tb_csr_if, tb_axil_top
#   pwsh sim/run_questa.ps1 -Tbs tb_csr_if       # a subset
#
# Mirrors sim/run.sh (the Verilator flow): same source order, same repo-root working directory
# (the TBs $readmemh golden vectors via repo-root-relative paths), same TB_RESULT: PASS/FAIL
# contract. One vlib/vlog/vsim per testbench; the full transcript (compile + run) is saved to
# sim/questa_<tb>.log. Exits non-zero if any testbench fails to compile, hits $fatal / a
# simulator error, or does not print "TB_RESULT: PASS".
param(
    [string]   $Radiant = "D:\lscc\radiant\2026.1",
    [string[]] $Tbs     = @("tb_smoke", "tb_csr", "tb_csr_if", "tb_axil_top"),
    [string]   $Python  = "python"
)
$ErrorActionPreference = "Stop"

$Root   = Split-Path -Parent $PSScriptRoot
$Sim    = Join-Path $Root "sim"
$Build  = Join-Path $Sim "build"
$Questa = Join-Path $Radiant "questasim\win64"
foreach ($exe in "vlib", "vlog", "vsim") {
    if (-not (Test-Path "$Questa\$exe.exe")) { throw "QuestaSim not found: $Questa\$exe.exe" }
}

# TBs load golden vectors via repo-root-relative paths.
Set-Location $Root

# Golden vectors for tb_csr (same two scope_ref.py invocations as gen_vectors in run.sh).
New-Item -ItemType Directory -Force "$Build\vectors" | Out-Null
& $Python sim/model/scope_ref.py capture --probe-w 32 --depth-log2 8 --pretrig 0 `
    --trig-sample 128 --count 640 --seed 0xC0FFEE01 --out-prefix sim/build/vectors/cap_w32_d8
if ($LASTEXITCODE -ne 0) { Write-Host "TB_RESULT: FAIL (scope_ref.py)"; exit 1 }
& $Python sim/model/scope_ref.py capture --probe-w 512 --depth-log2 10 --pretrig 0 `
    --trig-sample 512 --count 2560 --seed 0xC0FFEE02 --out-prefix sim/build/vectors/cap_w512_d10
if ($LASTEXITCODE -ne 0) { Write-Host "TB_RESULT: FAIL (scope_ref.py)"; exit 1 }

# Source order: package first, primitives, core RTL, front-ends (same as COMMON_SRCS in run.sh).
$Srcs = @(
    "rtl/scope_pkg.sv",
    "rtl/prim/prim_ff_sync.sv", "rtl/prim/prim_ram_1r1w.sv",
    "rtl/prim/prim_fifo_sync.sv", "rtl/prim/prim_fifo_async.sv",
    "rtl/scope_core.sv", "rtl/scope_csr.sv", "rtl/scope_trigger.sv", "rtl/scope_rle.sv",
    "rtl/scope_drain.sv", "rtl/xport/scope_uart.sv", "rtl/scope_top.sv",
    "rtl/if/scope_avalon.sv", "rtl/if/scope_axil.sv", "rtl/if/scope_jtag.sv",
    "fpga/lattice/scope_axil_top.sv"            # Radiant top (exercised by tb_axil_top)
)

$overall = 0
foreach ($tb in $Tbs) {
    Write-Host "=================================================================="
    Write-Host "== Questa: $tb"
    Write-Host "=================================================================="
    $lib = "sim/build/questa/$tb/work"
    $log = Join-Path $Sim "questa_$tb.log"
    if (Test-Path "sim/build/questa/$tb") { Remove-Item -Recurse -Force "sim/build/questa/$tb" }
    New-Item -ItemType Directory -Force "sim/build/questa/$tb" | Out-Null

    $ErrorActionPreference = "Continue"
    & "$Questa\vlib.exe" $lib *> $log
    # -timescale gives the RTL files (no `timescale directive) the TBs' 1ns/1ps, like run.sh.
    & "$Questa\vlog.exe" -sv -work $lib -timescale 1ns/1ps @Srcs "sim/$tb.sv" *>> $log
    $vlog_rc = $LASTEXITCODE
    if ($vlog_rc -eq 0) {
        & "$Questa\vsim.exe" -c -work $lib -lib $lib $tb -wlf "sim/build/questa/$tb/vsim.wlf" -l "sim/build/questa/$tb/transcript" `
            -do "run -all; quit -f" *>> $log
    }
    $ErrorActionPreference = "Stop"

    $text = Get-Content $log -Raw
    Get-Content $log | Select-String -Pattern "TB_RESULT|^\*\* (Error|Fatal)|Errors: \d+, Warnings: \d+" |
        ForEach-Object { Write-Host $_.Line }
    if ($vlog_rc -ne 0) {
        Write-Host "TB_RESULT: FAIL ($tb compile error, see $log)"; $overall = 1
    } elseif ($text -notmatch "TB_RESULT: PASS" -or $text -match "TB_RESULT: FAIL" -or
              $text -match "(?m)^# \*\* (Error|Fatal)") {
        Write-Host "TB_RESULT: FAIL ($tb simulation, see $log)"; $overall = 1
    }
}

Write-Host "=================================================================="
if ($overall -eq 0) { Write-Host "ALL TESTBENCHES PASSED" } else { Write-Host "ONE OR MORE TESTBENCHES FAILED" }
exit $overall
