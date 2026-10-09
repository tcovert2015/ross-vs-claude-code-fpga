# Vivado port — PCIe scatter-gather DMA engine on Artix-7

Target: `xc7a100tcsg324-1`, top `pcie_dma_top` with `SYS_IF="AXI4"`, `RESET_SYNC=1`,
`clk` = 125 MHz (8.000 ns), out-of-context (no I/O buffers — the Vivado
counterpart of the Quartus virtual pins). Tool: Vivado v2025.2 (build 6299465).

**Headline: the design does not meet 125 MHz on this part/speed grade.**
Post-route WNS is **-1.019 ns** (default directives) / **-0.945 ns** (Explore
directives). It closes at a **9.25 ns** period (108.1 MHz). Hold is met, DRC has
no errors, and the xsim regression passes 6/6.

## How to run

```
powershell -ExecutionPolicy Bypass -File vivado/run_build.ps1                      # 125 MHz, default directives -> vivado/reports/
powershell -ExecutionPolicy Bypass -File vivado/run_build.ps1 8.0 explore explore  # 125 MHz, Explore directives -> vivado/reports/explore/
powershell -ExecutionPolicy Bypass -File vivado/run_build.ps1 9.25 p9_250 default  # other period -> vivado/reports/<tag>/
scripts\run_xsim.bat                                                               # xsim regression (AXI4, AXI4+STALLS; seeds 1 2 3)
```

`run_build.ps1` only launches `vivado -mode batch -source build.tcl [-tclargs <period> <tag> <flow>]`
from `vivado/build/` (git-ignored: checkpoints, scratch) and copies the Vivado
log next to the reports. Override the install location with `VIVADO_BIN`
(build) / `VIVADO_BIN_DIR` (xsim). `SIM_SEEDS="1 2 3 4"` changes the seed sweep.

`build.tcl` steps: `synth_design -lint` → `synth_design -mode out_of_context` →
`opt_design` / `place_design` / `phys_opt_design` / `route_design` → reports
(`utilization`, `utilization_hier`, `timing_summary`, `timing_worst_setup/hold`,
`drc`, `methodology`, `check_timing`, `route_status`, plus post-synth
`utilization_synth` / `timing_summary_synth`).

Committed runs (each directory holds the full report set and `vivado.log`):

| Directory                  | Period   | Directives |
|----------------------------|----------|------------|
| `vivado/reports/`          | 8.000 ns | default    |
| `vivado/reports/explore/`  | 8.000 ns | Explore (`opt` Explore, `place` ExtraTimingOpt, `phys_opt`/`route` AggressiveExplore, post-route `phys_opt`) |
| `vivado/reports/p9_000/`   | 9.000 ns | default    |
| `vivado/reports/p9_250/`   | 9.250 ns | default    |

## Constraints (`pcie_dma.xdc`) vs `quartus/pcie_dma.sdc`

| Quartus SDC | XDC | Note |
|---|---|---|
| `create_clock -period 8.000 clk` | same | |
| `derive_clock_uncertainty` | — | Vivado derives it automatically |
| `set_false_path -from rst_n` | same | cuts only the async input of `reset_sync`; the synchronized reset fan-out is timed (recovery/removal, `**async_default**` group) |
| `set_input_delay` / `set_output_delay 1.0` | same value, **`-max` only** | see below |
| virtual pins | `-mode out_of_context` + `HD.CLK_SRC` on `clk` | models clock arrival through a global buffer |
| `altera_attribute` on the synchronizer (RTL) | `ASYNC_REG` on `*u_rst_sync/sync_q_reg*` | set from the XDC, RTL untouched |

**Deviation — I/O delays are setup-only.** With min = max = 1.0 ns (the literal
SDC translation) an earlier run reported WHS = -0.343 ns with 204 failing hold
endpoints on input ports: the port-referenced launch edge has no clock
insertion delay while the capture flop sees about 1.8 ns of it. That compares
against a launch flop that does not exist in an OOC run. Boundary hold is
therefore **not checked here** and must be timed in the integrated design.
Consequences visible in the reports: `check_timing` lists 318 partial input /
580 partial output delays and `report_methodology` 505 TIMING-18 warnings.
(That earlier run's reports were overwritten and are not committed; its setup
WNS was the same -1.019 ns.)

## Timing results (post-route)

| Run | Period | WNS | TNS | Failing setup endpoints | WHS | THS |
|---|---|---|---|---|---|---|
| default (`reports/`) | 8.000 ns | **-1.019 ns** | -18.534 ns | 55 / 5248 | 0.034 ns | 0.000 ns |
| Explore (`reports/explore/`) | 8.000 ns | -0.945 ns | -14.309 ns | 40 / 5302 | 0.105 ns | 0.000 ns |
| default (`reports/p9_000/`) | 9.000 ns | -0.334 ns | -2.195 ns | 10 / 5245 | 0.034 ns | 0.000 ns |
| default (`reports/p9_250/`) | 9.250 ns | **+0.047 ns** | 0.000 ns | 0 / 5245 | 0.032 ns | 0.000 ns |

Source: "Design Timing Summary" in each `timing_summary.rpt`. In the 125 MHz
default run the reset recovery/removal group (`**async_default**`) is met
(setup slack 1.275 ns, hold 0.604 ns) and minimum pulse width slack is 2.750 ns.
The post-synthesis estimate at 8 ns was WNS -2.053 ns (`timing_summary_synth.rpt`).

**Achievable Fmax.** Period minus slack at 125 MHz gives 8.000 + 1.019 =
9.019 ns (110.9 MHz) for the default flow and 8.945 ns (111.8 MHz) for Explore,
but that extrapolation was optimistic: an actual run at 9.000 ns still missed
by 0.334 ns. The demonstrated closing point is **9.250 ns = 108.1 MHz**
(WNS +0.047 ns). Nothing between 9.000 and 9.250 ns was run. Each result is a
single run; no placement-seed sweep was done.

**Critical path** (`timing_worst_setup.rpt`): `u_core/u_mover/w_addr_reg[0]` →
`u_core/u_mover/w_burstcount_q_reg[*]/CE` and `w_dcnt_reg[*]/CE`, 8.773 ns data
path, 12 logic levels (5 CARRY4), 46 % logic / 54 % route. This is the
write-side burst sizing in `rtl/core/dma_data_mover.sv`:
`beats_to_boundary(w_addr)` (line 106) → `min3(MAX_BURST_BEATS, w_rem, …)`
(line 140) → carry-chain comparison → write-FSM enable, all in one cycle. The
worst paths in the Explore run start at the same register. Tool directives
recovered only 0.074 ns, so closing 125 MHz on a -1 Artix-7 needs an RTL change
(for example registering the boundary-limited burst size when `w_addr` is
updated) or a faster speed grade. I did not make that change: it alters the
core datapath's cycle behaviour and would need the full simulation and formal
suite re-run, which goes beyond a port.

## Utilization (post-route, 125 MHz default run, `utilization.rpt`)

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 1373 | 63400 | 2.17 |
| — LUT as logic | 1029 | 63400 | 1.62 |
| — LUT as distributed RAM | 344 | 19000 | 1.81 |
| Slice registers (FF) | 825 | 126800 | 0.65 |
| Block RAM tiles | 0 | 135 | 0.00 |
| DSPs | 0 | 240 | 0.00 |

BRAM is 0 because `dma_fifo` reads its memory asynchronously (show-ahead), so
Vivado maps it to LUT RAM — the same reason the source says it maps to MLAB on
Altera. By hierarchy (`utilization_hier.rpt`): `u_mover` 944 LUTs / 244 FFs (of
which `u_fifo` 620 LUTs including the 344 LUTRAMs), `u_fetch` 222 / 202, `u_csr`
134 / 169, AXI4 adapter 18 / 50. The Explore run uses 1382 LUTs / 843 FFs.

## DRC / methodology (125 MHz default run)

- `drc.rpt`: 0 errors, 2 warnings — CFGBVS-1 (no configuration voltage set;
  irrelevant for an OOC block) and RTSTAT-10 (262 nets with no routable loads:
  the top-level output ports, expected in OOC). `route_status.rpt`: 0 nets with
  routing errors.
- `methodology.rpt`: TIMING-16 ×5 (the setup violation above), TIMING-18 ×505
  (setup-only I/O delays, see above).

## RTL lint (`synth_design -lint`: `reports/lint.rpt` + the lint section of `reports/vivado.log`)

Lint run total: **0 errors, 0 critical warnings, 77 warnings**. None of them
is a functional bug.

| Source | ID | Count | What | Assessment |
|---|---|---|---|---|
| Linter rule | ASSIGN-10 | 10 | input port bits never read | Not real. 6 are the unselected Avalon/AHB input groups on `pcie_dma_top` (by design for `SYS_IF="AXI4"`). 4 are in `gmm_to_axi4`: `axi_bid`/`axi_rid` (single ID) and bit 0 of `axi_bresp`/`axi_rresp` — the adapter's `err` uses only bit 1 (SLVERR/DECERR), lines 185-186 |
| Linter rule | ASSIGN-6 | 2 | `d` and `ctrl_field` bits not read in `dma_descriptor_fetch` | Not real: reserved descriptor bytes / unused control bits (already waived for Verilator in the source) |
| Elaboration | Synth 8-11067 | 52 | `parameter` inside package `dma_pkg` treated as localparam | Not real: informational, matches the LRM |
| Elaboration | Synth 8-7137 | 12 | register "has both Set and reset with same priority" | Real but benign, see below |
| Elaboration | Synth 8-3936 | 1 | `d_reg` trimmed from 256 to 192 bits | Not real: same reserved descriptor bits as ASSIGN-6 |

`lint.rpt` itself contains only the 12 linter-rule violations (all severity
WARNING, 0 waived); the other 65 are elaboration messages emitted during the
lint run and are counted from the log.

**Synth 8-7137** (`beats` in `dma_descriptor_fetch.sv:94`; `aw_addr_q` /
`aw_len_q` in `gmm_to_axi4.sv:117-118`): these registers are assigned inside an
`always_ff … or negedge rst_n` block but are not in its reset branch, so the
asynchronous reset becomes part of their clock-enable. The regression passes
and the cost is a little enable logic; moving them to a separate non-reset
`always_ff` would be the clean fix. Not changed.

## xsim regression (`scripts/run_xsim.bat` → `scripts/run_xsim.ps1`)

`xvlog -sv` + `xelab` once per configuration, then `xsim -R` per seed with
`+SEED=<n>`; pass = log contains `=== PASS` (same criterion as `run_sim.sh`).

| Configuration | Defines | seed 1 | seed 2 | seed 3 | Logs |
|---|---|---|---|---|---|
| AXI4 | `USE_AXI` | PASS | PASS | PASS | `sim/build/xsim_axi4_seed<n>.log` |
| AXI4 + STALLS | `USE_AXI`, `STALLS` | PASS | PASS | PASS | `sim/build/xsim_axi4_stalls_seed<n>.log` |

Each log contains `=== PASS : all checks ok ===`. Limits of this evidence:

- These configurations instantiate the DUT with its default `RESET_SYNC=0`
  (as in `run_sim.sh`; `RESET_SYNC=1` is simulated only under
  `+define+RESET_SYNC_EN`, which this script does not run). The synthesized
  `RESET_SYNC=1` variant is therefore implemented but not simulated here.
- xsim's RNG differs from Icarus, so a given seed produces different (still
  deterministic) stimulus than the Icarus regression.

## Source changes

No file under `rtl/` was modified.

One testbench line changed, in `sim/tb_pcie_dma.sv` (RNG seeding):

```
-    void'($urandom(rng_seed));
+    rng_discard = $urandom(rng_seed);      // plus: int unsigned rng_discard;
```

xsim rejects the void-cast form (`ERROR: [XSIM 43-3122] … urandom system task
is not supported`); assigning the result is standard SystemVerilog and is the
same call. **Not re-verified under Icarus:** the only Icarus on this machine is
11.0, which fails on the unmodified `rtl/pkg/dma_pkg.sv` (`syntax error` at
line 27) for every configuration, so `scripts/run_sim.sh` could not be run
here.

`.gitignore` gained Vivado/xsim outputs and an exception so the logs under
`vivado/reports/` are tracked. The six `sim/build/xsim_*_seed*.log` files are
committed with `git add -f` (a repo-root rule ignores every `build/` directory).

## Not done

- 125 MHz timing closure (see above).
- Boundary (port) hold analysis; placement-seed sweep; periods between 9.0 and 9.25 ns.
- xsim runs of the AVALON / AHB / `RESET_SYNC_EN` configurations (not requested).
- Icarus re-run after the testbench edit (local Icarus too old).
