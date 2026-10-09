# fpga-scope on AMD Vivado (Artix-7, AXI4-Lite)

`scope_top` with `XPORT="CSR"` behind the `scope_axil` front-end, built out-of-context for
**`xc7a100tcsg324-1`** at **100 MHz** with **Vivado 2025.2**, plus an xsim regression.

Every number below is copied from a committed report or log; the source file is named next to
each table. Nothing here was measured on hardware — this is synth + place + route + simulation.

| File | What |
|---|---|
| `scope_axil_top.sv` | AXI4-Lite top: `scope_top` (`XPORT="CSR"`) + `scope_axil`, `s_axi_*` ports, `clk` / `aresetn`, `probe`, `trig_ext_i/o`, `armed`, `triggered`. Parameters `PROBE_W`, `DEPTH_LOG2` (+ `NUM_CMP`, `SEQ_STAGES`, `RLE_EN`, `TS_W`, `ID_VALUE`) pass through. |
| `scope_axil_bd.v` | Zero-logic Verilog shim around `scope_axil_top` for IP Integrator (see below). |
| `build.tcl` | Non-project flow: lint → synth (OOC) → opt → place → phys_opt → route → reports. |
| `scope.xdc` | 100 MHz clock, 2 ns I/O budgets, OOC port-hold exception. |
| `run_all.ps1` | Runs `build.tcl` for the three README configurations in parallel. |
| `check_ipi.tcl` | Proves IP Integrator infers the `s_axi` interface. |
| `reports/pw<W>_d<N>/` | `lint`, `utilization` (+`_hier`, `_synth`), `timing_summary`, `drc`, `ram`, `route_status`, `summary.txt`, `vivado.log`. |
| `reports/_baseline/` | Same builds with the **original** `rtl/scope_csr.sv` (A/B for the RTL change below). |
| `../../sim/run_xsim.ps1` | xsim regression; logs in `sim/xsim_<tb>.log`. |

## How to run

```powershell
# all three configurations (32,8) (32,12) (32,15), ~3 min in parallel
pwsh fpga/xilinx/run_all.ps1

# one configuration, from any directory (scratch files land in the current directory)
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source fpga/xilinx/build.tcl -tclargs 32 12

# xsim regression: tb_smoke, tb_csr, tb_csr_if, tb_axil_top
pwsh sim/run_xsim.ps1

# IP Integrator interface inference check
mkdir fpga/xilinx/build/ipi; cd fpga/xilinx/build/ipi
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source ../../check_ipi.tcl
```

`RLE_EN` is left at the wrapper default of 1 so the stored word is `PROBE_W+1` = 33 bits and the
"buffer bits" column is directly comparable with the Agilex 3 table in the top-level README. The
transport is different, though: that table is `XPORT="UART"` (drain engine, two async FIFOs,
UART); this build is `XPORT="CSR"` + AXI4-Lite, which has none of those. Compare the BRAM
columns, not LUTs against ALMs.

## Utilization and timing (post-route, out-of-context)

Sources: `reports/<cfg>/utilization.rpt` (LUT, FF, RAMB), `ram.rpt` (buffer bits, mapping),
`timing_summary.rpt` (WNS/TNS/WHS).

| PROBE_W | Depth (2ᴺ) | Slice LUTs | Slice FFs | RAMB36 | RAMB18 | buffer bits | WNS @ 100 MHz | TNS | WHS |
|---|---|---|---|---|---|---|---|---|---|
| 32 | 256 (N=8)    | 1,194 / 63,400 (1.88%) | 1,182 / 126,800 (0.93%) | 0  | 2 | 8,448     | **+0.791 ns** | 0.000 ns | +0.143 ns |
| 32 | 4096 (N=12)  | 1,238 / 63,400 (1.95%) | 1,213 / 126,800 (0.96%) | 4  | 1 | 135,168   | **+0.603 ns** | 0.000 ns | +0.086 ns |
| 32 | 32768 (N=15) | 1,282 / 63,400 (2.02%) | 1,256 / 126,800 (0.99%) | 33 | 1 | 1,081,344 | **+0.906 ns** | 0.000 ns | +0.110 ns |

All three: "All user specified timing constraints are met", 0 failing endpoints, 0 nets with
routing errors (`route_status.rpt`), `check_timing` reports 0 unclocked / 0 unconstrained
endpoints / 0 ports without I/O delay. As in the Agilex table, logic barely moves with depth
(+88 LUTs from N=8 to N=15); only the BRAM grows.

**The capture buffer maps to block RAM in every configuration — 0 LUTs used as memory**
(`LUT as Memory = 0`, `LUTMs as Distributed RAM = 0`, 100% inferred, no vendor primitives or
`ram_style` attributes in the RTL). From `ram.rpt`:

| Config | Capture buffer `u_core/u_buf` | Window-metadata RAM `u_core/u_win_meta` |
|---|---|---|
| N=8  | 256×33 → **1 × RAMB18E1** | 256×9 → 1 × RAMB18E1 |
| N=12 | 4096×33 → **4 × RAMB36E1** (3 × 4096×9 + 1 × 4096×6) | 256×13 → 1 × RAMB18E1 |
| N=15 | 32768×33 → **33 × RAMB36E1** (one 32768×1 per bit) | 256×16 → 1 × RAMB18E1 |

At N=15 that is exactly the raw cost: 33 × 32,768 = 1,081,344 bits, every RAMB36 bit used. At
N=12 the buffer occupies 135,168 of the 147,456 bits in four RAMB36. The buffer is 24.4% of the
device's RAMB36 at N=15. Vivado notes (`Synth 8-7052`) that no BRAM output register could be
merged — the RTL has the 1-cycle read latency the CSR drain path is written around, so this is
expected, and the BRAM read path is not the critical one.

Worst setup paths are internal flop-to-flop, not the AXI port: e.g. at N=8,
`u_csr/seq_cnt_q` → `u_trigger/occ_reg` (12 logic levels, 8.601 ns data path). Margin is under
1 ns in all three, so on a -1 Artix-7 the core tops out a little above 100 MHz as written.

### Constraints, and what out-of-context does and does not prove

* `clk` 100 MHz; every input and output carries a 2 ns budget for the parent design, so the
  AXI4-Lite handshake paths (which are combinational from `s_axi_awvalid`/`wvalid`/`arvalid`
  into the CSR decode) are timed rather than ignored.
* Hold is checked on all internal paths (WHS above) but **excluded on the ports**
  (`set_false_path -hold`). OOC, the clock has no buffer and no routed net, so Vivado
  estimates ~0.9–1.0 ns of clock insertion delay while port data launches at an ideal 0 ns;
  every port → flop path then shows the same artificial hold violation and the router cannot
  fix a port net. Port hold has to be closed in the parent design. Vivado warns about this
  modelling itself (`Timing 38-242`, `Route 35-197`: no `HD.CLK_SRC`).
* DRC (`drc.rpt`): 1 check, 1 warning, `CFGBVS-1` (no `CFGBVS`/`CONFIG_VOLTAGE`). That is a
  board-level property that does not belong in an OOC module; not set on purpose. Vivado also
  states that connectivity DRCs are not fully run OOC (`DRC 23-814`).

## Lint (`synth_design -lint`)

Source: `reports/<cfg>/lint.rpt` — identical for all three configurations.

| Severity | Count |
|---|---|
| Error | 0 |
| Critical warning | 0 |
| Warning | 6 |

| Rule | Count | Where | Assessment |
|---|---|---|---|
| `ASSIGN-6` signal assigned but not read | 5 | `scope_axil._unused`, `scope_axil_top.unused_top`, `scope_top.g_csr_mode.unused_csr_mode`, `scope_top.unused_status`, `scope_trigger.unused_combine_reserved` | Intentional. These are the repo's `wire unused = &{1'b0, ...}` sinks that keep Verilator `-Wall` clean; flagging the sink is the linter seeing the idiom. No action. |
| `ASSIGN-1` arithmetic result truncated | 1 | `scope_csr.sv:165`, `seq_idx = 2'(csr_addr - 8'(CSR_SEQ_CNT_BASE))` | Benign. Explicit 2-bit cast of an index that is only used when `is_seq_addr` holds (address in 65..68). No action. |

Nothing in the lint report needs an RTL change. Two things the linter did **not** catch were
found by running the tools: the use-before-declaration in `scope_top.sv` (a synthesis warning,
`Synth 8-6901`, and a hard xvlog error) and the deep CSR decode path (timing). Both are fixed
below.

For the full flow (lint + synth + implementation, `reports/<cfg>/vivado.log`): 0 errors,
0 critical warnings, and 122 (N=8) / 135 (N=12, N=15) warnings. By count they are almost all
OOC bookkeeping: 87 × `Route 35-198` (port has no `HD.PARTPIN_LOCS`), 17–30 × `Synth 8-7129`
(unconnected port bits: `wstrb`, `awprot`/`arprot`, address bits [1:0], the UART/stream ports
tied off in CSR mode, reserved `trig_combine` bits), 4 × `Synth 8-3917` (`bresp`/`rresp`
constant OKAY), 6 lint messages echoed, and the OOC notes cited above.

## xsim regression

`pwsh sim/run_xsim.ps1` — all four print `TB_RESULT: PASS` (logs: `sim/xsim_<tb>.log`).

| Testbench | Covers | Result |
|---|---|---|
| `tb_smoke` | harness plumbing | PASS |
| `tb_csr` | native CSR matrix, cfg_err lockout, golden-vector BUF_DATA drain (PROBE_W 32 and 512) | PASS |
| `tb_csr_if` | CSR matrix + BUF_DATA pop through Avalon-MM and AXI4-Lite | PASS |
| `tb_axil_top` (new) | `scope_axil_top` end to end over `s_axi_*`: ID/HWCFG parameter pass-through, `armed`/`triggered` pins, force-trigger capture + full drain, comparator-trigger capture; RLE_EN 1 and 0 | PASS |

`tb_csr` **does** need the Python golden vectors (it `$readmemh`s the two `capture` sets), so
`run_xsim.ps1` generates them with `sim/model/scope_ref.py` first, using the same commands as
`sim/run.sh`. It needs a `python` on PATH (stdlib only).

The existing testbenches never exercised the new wrapper, so `tb_axil_top` was added; it is
also wired into `sim/run.sh`.

### Portability fixes needed for xsim

| File | Change | Why |
|---|---|---|
| `rtl/scope_top.sv` | Moved the `dec_tick` / `qual_hit` / `sample_en` / `trig_fire` wire declarations above the `always_ff` that reads `sample_en`. | Use before declaration. IEEE 1800 requires declaration first; Verilator and Quartus accept it, xvlog rejects it (`VRFC 10-3380`). No functional change. |
| `sim/tb_csr.sv` | Moved `win_rd_addr` / `win_rd_data` declarations above the DUT instances. | Same rule; xvlog: "already implicitly declared" (`VRFC 10-2938`). |
| `sim/tb_csr_if.sv` | Moved `rd, id_val, hwcfg_val` above the `_unused` sink that references `rd`. | Same rule (`VRFC 10-3380`). |
| `sim/tb_csr.sv` | The two STATUS poll loops `do csr_rd(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_x));` now use a `begin`/`end` body and compare against the bare enum. | Not a Verilator-only construct — legal SystemVerilog that xsim 2025.2 mis-simulates. See below. |

The last one is an xsim defect, isolated in a standalone reproducer
(`sim/xsim_repro_loop_cast.sv`, output in `sim/xsim_repro_loop_cast.log`):

* In a `while` / `do … while` condition, a size-cast enum constant such as
  `v[2:0] != 3'(S4)` evaluates false when it is true: the `while` runs 0 iterations and the
  `do … while` 1, where 3 are expected. The same expression in an `if` is evaluated correctly,
  and so is the loop when it compares against the bare enum.
* A bare task-call loop body with a cast argument, `do rd(8'(0), v); while (…);`, leaves the
  task's output `v` at X; wrapped in `begin`/`end` it is written correctly.

Under xsim the original loops therefore exited after a single read and `tb_csr` failed with
`STATUS.triggered`. The same loop-condition idiom is still in six testbenches outside this
regression (`tb_capture_basic`, `tb_drain_cdc`, `tb_ext_trig`, `tb_jtag`, `tb_pretrig`,
`tb_trigger_seq` — nine loops); they were left untouched and will need the same edit before
they can run in xsim.

## RTL change for timing: `rtl/scope_csr.sv`

With the original RTL the N=8 build **failed 100 MHz**: WNS −0.211 ns, TNS −2.234 ns, 30
failing endpoints (`reports/_baseline/pw32_d8/timing_summary.rpt`, same constraints as the
final build). The path ran from `s_axi_awvalid` through the CSR write decode into the
comparator config flops (`cmp_q`) with 8 CARRY4 stages in it.

Cause: the comparator lane write evaluated `lane_wmask(lane_idx)` and
`32 * 32'(lane_idx) < PROBE_W` on the *runtime* lane index (`csr_addr[3:0]`). The function
does 32-bit integer arithmetic (`rem = PROBE_W - 32*j`, a compare, `(1 << rem) - 1`), and
Vivado built that subtract/shift/compare chain on the address in front of every `cmp_q` bit.

Fix (vendor-neutral, no primitives, no attributes): the same function is now called once per
lane with a **constant** argument to form a 16-entry mask table that `lane_idx` indexes, and
the range test is written as `lane_idx < LANES`, which is the same predicate
(`32·j < PROBE_W` ⇔ `j < ⌈PROBE_W/32⌉`). Register map, masks and read-back are unchanged.

| Config | WNS before | WNS after | LUTs before | LUTs after |
|---|---|---|---|---|
| N=8  | −0.211 ns | +0.791 ns | 1,247 | 1,194 |
| N=12 | +0.231 ns | +0.603 ns | 1,300 | 1,238 |
| N=15 | +0.637 ns | +0.906 ns | 1,344 | 1,282 |

("before" = `reports/_baseline/<cfg>/`, "after" = `reports/<cfg>/`; flop counts are identical.)

Verification of the two RTL edits: the xsim regression above, plus the repo's own Verilator
regression `sim/run.sh` — all 16 original testbenches and the `scope_top` lint matrix with
`-Wall`, plus `tb_axil_top` — which reports 17 × `TB_RESULT: PASS` and
`ALL TESTBENCHES PASSED` (`sim/verilator_run.log`). That run used Verilator 5.020 under WSL on
an LF-normalised copy of this tree, because the Windows checkout has CRLF line endings that
`bash` cannot execute.

## IP Integrator

`s_axi_*` naming plus `X_INTERFACE_INFO`/`X_INTERFACE_PARAMETER` attributes on `clk` and
`aresetn` are enough for inference, with one catch found by trying it: IP Integrator will not
accept a SystemVerilog file as the top of an RTL module reference (`filemgmt 56-195`). So block
designs reference the Verilog shim:

```tcl
create_bd_cell -type module -reference scope_axil_bd scope_0
```

`reports/ipi_check.log` (from `check_ipi.tcl`): one interface `s_axi`,
`xilinx.com:interface:aximm_rtl:1.0`, Slave, `AXI4LITE`, 10-bit address, 32-bit data; `clk`
typed as clock with `ASSOCIATED_BUSIF=s_axi`, `ASSOCIATED_RESET=aresetn`; `aresetn` typed as
reset, `ACTIVE_LOW`; `IPI_CHECK: PASS`.

Integration notes:

* `clk` is both the probe clock and the AXI clock (the `scope_axil` contract). If the AXI
  master is in another domain, put an AXI clock converter in front.
* `aresetn` is inverted and registered once to make the core's synchronous active-high reset.
* The address window is 1 KiB (`[9:2]` = CSR word index, map in `docs/INTERFACES.md`).
  `WSTRB` and `PROT` are accepted and ignored; responses are always OKAY.

## Tool quirks worth knowing

* **`synth_design -lint -file <path>` with a space in the path** (this checkout lives under
  `D:\AMD Ross Test\…`) writes no report and reports success, and the *next* `synth_design`
  in the same session then black-boxes every inferred RAM (`bboxRAM`, `DRC INBB-3` at
  `opt_design`). `build.tcl` `cd`s into the report directory and passes a bare file name, and
  errors out if `lint.rpt` is missing.
* **`[Designutils 20-411] … .Xil … could not be deleted and may be locked`** killed a build
  between the lint and synthesis steps in two of the later parallel runs. It is a transient
  lock on Vivado's own scratch directory; the rerun produced identical results.
  `run_all.ps1` retries that one error once and prints `RETRY`.

## Not done

* No bitstream and no hardware run: out-of-context implementation only, no board pinout.
* The four SymbiYosys formal proofs were **not** re-run after the `scope_csr.sv` /
  `scope_top.sv` edits (`sby` is not installed here).
* Only four testbenches run in xsim; the other 13 were not ported (see the loop idiom above).
* Only the three `PROBE_W=32` configurations were built. `fpga/util_sweep/` still describes
  its Vivado sweep as not run; `build.tcl` takes any `PROBE_W` / `DEPTH_LOG2`, but wider
  probes were not tried and may not meet 100 MHz.
