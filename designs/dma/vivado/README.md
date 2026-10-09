# PCIe DMA engine on AMD Vivado (Artix-7)

Vivado 2025.2 port of the Quartus flow in `quartus/`: `pcie_dma_top` with
`SYS_IF="AXI4"`, `RESET_SYNC=1`, part `xc7a100tcsg324-1`, out-of-context,
`clk` = 8.000 ns (125 MHz).

**Headline: the design does not meet 125 MHz on this part.** Post-route WNS is
**-0.456 ns** (10 failing endpoints, all on one path cone inside
`dma_data_mover`). Hold is met. It closes at a 9.000 ns clock (111.1 MHz). No
core RTL was changed to get there; see [Timing](#timing-at-125-mhz) and
[RTL changes](#rtl-changes).

| Item | Result | Source |
|------|--------|--------|
| Lint | 12 messages: 0 error, 0 critical, 12 warning | `reports/lint.rpt` |
| LUT / FF / BRAM | 1333 / 831 / 0 | `reports/utilization.rpt` |
| WNS / TNS / WHS at 8.000 ns | -0.456 / -4.546 / +0.080 ns | `reports/timing_summary.rpt` |
| Closing period | 9.000 ns (WNS +0.024 ns) | `reports/period_9.000/timing_summary.rpt` |
| DRC | 0 errors, 2 warnings | `reports/drc.rpt` |
| Route | 0 nets with routing errors | `reports/route_status.rpt` |
| xsim regression | 6 / 6 PASS | `../sim/build/xsim_summary.txt` |

## How to run

From `designs/dma/`:

```
vivado -mode batch -source vivado/build.tcl                  # 125 MHz build
vivado -mode batch -source vivado/build.tcl -tclargs 9.000   # same flow, other clock period
vivado -mode batch -source scripts/run_xsim.tcl              # xsim regression, seeds 1 2 3
vivado -mode batch -source scripts/run_xsim.tcl -tclargs 1 2 3 4
```

Both scripts can also be `source`d from a live Vivado Tcl session (set
`::dma_period` / `::dma_seeds` first to override). That is how every result
here was produced: through the Vivado MCP server (`vivado_execute`), not by
launching `vivado.bat` directly. The standalone `vivado -mode batch` form was
not executed.

`build.tcl` runs: `synth_design -lint` → `synth_design -mode out_of_context`
→ `opt_design` → `place_design` → `phys_opt_design` → `route_design` →
reports. Reports for 8.000 ns go to `vivado/reports/`; any other period goes
to `vivado/reports/period_<ns>/` so exploration runs never overwrite the
125 MHz reports. Checkpoints (`*.dcp`) are written next to the reports but are
git-ignored.

`run_xsim.tcl` compiles and elaborates each configuration once
(`xvlog`/`xelab`), then runs `xsim` per seed with `-testplusarg SEED=<n>`.
Pass criterion is the one `scripts/run_sim.sh` uses: the transcript contains
`=== PASS`. Transcripts are `sim/build/xsim_<cfg>_seed<n>.log`, with
`<cfg>` = `axi4` (`+define+USE_AXI`) or `axi4_stalls`
(`+define+USE_AXI +define+STALLS`).

## Constraints (`pcie_dma.xdc`)

| `quartus/pcie_dma.sdc` | `vivado/pcie_dma.xdc` |
|------------------------|-----------------------|
| `create_clock -period 8.000 clk` | same |
| `derive_clock_uncertainty` | none needed; Vivado derives it |
| `set_false_path -from rst_n` | same |
| `set_input_delay` / `set_output_delay` 1.0 ns | `set_max_delay -datapath_only` of period − 1.0 ns (7.000 ns) on port↔register paths, period − 2.0 ns port→port |
| `VIRTUAL_PIN` on all bus ports | `synth_design -mode out_of_context` |
| `altera_attribute` synchronizer hint in `reset_sync.sv` | `ASYNC_REG` set on `sync_q_reg[*]` from the XDC |
| — | `HD.CLK_SRC BUFGCTRL_X0Y0` on `clk` |

Two of these are deliberate departures from a literal translation, both
informed by `amd-doc-search` results:

- **OOC mode and `HD.CLK_SRC`.** AR 55224 states that `-mode out_of_context`
  turns off I/O buffer insertion, which is the equivalent of the Quartus
  virtual pins. UG905 ("I/O and Clock Buffers") says a clock port driven from
  the parent design is not routed in the OOC run and that `HD.CLK_SRC` should
  be set so clock delay and skew are estimated; AR 57083 adds that without it
  no clock delay is used at all.
- **I/O budget as `set_max_delay -datapath_only`.** The first build used a
  literal `set_input_delay`/`set_output_delay 1.0`. With the clock propagated
  from the port (about 1.8 ns of estimated insertion delay) and the port data
  launched with none, that reported 204 hold violations (WHS -0.343 ns), every
  one a port→register path, plus 898 XDCH-2 methodology warnings. Those do not
  exist once the neighbouring logic is on the same clock tree. UG905 ("Timing
  Constraints" for OOC modules) lists `set_max_delay -datapath_only` from/to
  the ports as the way to budget an OOC boundary, so the same 1 ns budget is
  expressed that way. The cost: boundary hold is not checked here (it must be
  closed in the parent design), and `check_timing` now reports 318 ports with
  "partial input delay". That earlier run's reports are not committed; the
  numbers are quoted from it for the rationale only.

Port timing is an estimate in any case: no `HD.PARTPIN_LOCS` are set, so the
router warns (Route 35-198) that port nets are not partially routed.

## Lint (`reports/lint.rpt`, parsed to `reports/lint.csv`)

`synth_design -lint` reports **12 messages, all WARNING** (no errors, no
critical warnings):

| Rule | Severity | Count | Where |
|------|----------|-------|-------|
| ASSIGN-10 (IO bits not read) | Warning | 10 | 6 in `pcie_dma_top.sv`, 4 in `gmm_to_axi4.sv` |
| ASSIGN-6 (bits not used) | Warning | 2 | `dma_descriptor_fetch.sv` |

Assessment: **none is a defect.** All 12 are unused inputs or reserved fields
that the RTL already waives for Verilator at the same lines.

- `pcie_dma_top.sv:60-62, 110-112` — `avm_waitrequest`, `avm_readdata`,
  `avm_readdatavalid`, `hrdata`, `hready`, `hresp`. Inputs of the Avalon and
  AHB port groups, unused because `SYS_IF="AXI4"` selects the AXI adapter.
- `gmm_to_axi4.sv:53-54, 70, 72` — `axi_bid`, `axi_rid` (single-ID master) and
  bit 0 of `axi_bresp`/`axi_rresp`. Only bit 1 (SLVERR/DECERR) is used, at
  lines 185-186, so error responses are still caught.
- `dma_descriptor_fetch.sv:112, 120` — descriptor word `d` above bit 96 and
  `ctrl_field` above bit 3 are reserved descriptor bytes/flags.

Outside the linter, synthesis itself raised two things worth knowing (seen in
the session log, which is not committed, so no counts are given):

- **Synth 8-7137**, "register has both Set and reset with same priority", on
  `beats_reg` (`dma_descriptor_fetch.sv:94`) and `aw_addr_q`/`aw_len_q`
  (`gmm_to_axi4.sv:117-118`). These registers are assigned inside an
  async-reset `always_ff` but not in its reset branch, so the reset becomes a
  clock-enable term. Functionally correct, a real style finding; resetting
  them (or moving them to a reset-less block) would remove the warning.
- Synth 8-11067 for every `parameter` in `dma_pkg` (treated as `localparam`),
  and Synth 8-3917/8-7129 for the constant-driven and unused Avalon/AHB ports.
  Expected for this configuration.

## Utilization (`reports/utilization.rpt`, post-route, 8.000 ns build)

| Resource | Used | Available | Util |
|----------|------|-----------|------|
| Slice LUTs | 1333 | 63400 | 2.10 % |
| – LUT as logic | 989 | | |
| – LUT as distributed RAM | 344 | | |
| Slice registers (FF) | 831 | 126800 | 0.66 % |
| Block RAM tiles | 0 | 135 | 0 % |
| DSPs | 0 | 240 | 0 % |

**BRAM is 0** because the 256 × 64 FIFO in `dma_fifo.sv` has an asynchronous
(show-ahead) read, which block RAM cannot implement; it maps to the 344
LUT-RAMs. `reports/utilization_hier.rpt` puts 893 of the 1333 LUTs in
`u_mover` (577 of them in the FIFO).

## Timing at 125 MHz

From `reports/timing_summary.rpt` (post-route, 8.000 ns):

| | Value |
|---|---|
| WNS | **-0.456 ns** (10 failing endpoints of 5266) |
| TNS | -4.546 ns |
| WHS | +0.080 ns (0 failing) |
| THS | 0.000 ns |
| WPWS | +2.750 ns |
| Reset recovery / removal (`**async_default**`) | +2.816 / +0.636 ns |
| Port → register budget (`input port clock`) | +1.575 ns |

Timing is **not met**. The worst path (`reports/timing_worst_setup.rpt`) is
register-to-register inside `dma_data_mover`:
`w_addr_reg[0]` → `w_burstcount_q_reg[0]/CE`, 8.172 ns of data path over 12
logic levels (5 CARRY4), 48 % logic / 52 % route. It is the write-side burst
sizing in `dma_data_mover.sv:138-145`: `beats_to_boundary(w_addr)` →
`min3(MAX, w_rem, boundary)` → compare with `fifo_level` → `w_can_issue` →
clock enables of `w_burstcount_q`/`w_dcnt`. All in one cycle.

This is a logic-depth limit, not a constraint artifact: skew on the path is
about zero and the boundary budgets have positive slack. The flow already uses
`-directive PerformanceOptimized -retiming` in synthesis and Explore-class
directives in opt/place/phys_opt/route; lower-effort settings gave worse slack
in earlier runs of this session.

### Achievable Fmax

The same script was run at relaxed periods:

| Period | Frequency | WNS | WHS | Result | Reports |
|--------|-----------|-----|-----|--------|---------|
| 8.000 ns | 125.0 MHz | -0.456 ns | +0.080 ns | fails | `reports/` |
| 8.500 ns | 117.6 MHz | -0.306 ns | +0.002 ns | fails | `reports/period_8.500/` |
| 9.000 ns | 111.1 MHz | +0.024 ns | +0.107 ns | **meets** | `reports/period_9.000/` |

**9.000 ns (111 MHz) is the period shown to close.** The usual
"period − WNS" estimate from the 125 MHz run is 8.456 ns (118 MHz), but the
8.500 ns run shows that estimate is optimistic here, so treat ~111 MHz as the
achievable figure on a -1 Artix-7, with the true limit somewhere between 8.5
and 9.0 ns. Results move by a few tenths of a nanosecond between runs.

Closing 125 MHz needs an RTL change in `dma_data_mover` (for example
registering `w_bmax`/`beats_to_boundary` so burst sizing takes its own cycle)
or a faster speed grade. I did not make that change: it alters core
datapath timing behaviour and needs the full six-configuration regression and
the formal proofs, which could not be run here.

### Methodology and DRC

- `reports/methodology.rpt`: 0 checks.
- `reports/drc.rpt`: 2 warnings, both expected for an OOC block — CFGBVS-1
  (no configuration-voltage properties) and RTSTAT-10 (262 port nets with no
  routable load).

## xsim regression

`sim/build/xsim_summary.txt`, Vivado Simulator 2025.2:

| Configuration | Defines | Seed 1 | Seed 2 | Seed 3 |
|---------------|---------|--------|--------|--------|
| AXI4 | `USE_AXI` | PASS | PASS | PASS |
| AXI4 + stalls | `USE_AXI STALLS` | PASS | PASS | PASS |

Each transcript ends with `=== PASS : all checks ok ===`. The seeds really
drive different stimulus: the coverage line shows 111, 106 and 105 descriptors
for seeds 1, 2 and 3.

## RTL changes

**Core RTL (`rtl/`): none.**

**Testbench: one line, `sim/tb_pcie_dma.sv`.** xsim refused to elaborate the
RNG seeding call:

```
ERROR: [XSIM 43-3122] ".../sim/tb_pcie_dma.sv" Line 481. urandom system task is not supported.
```

`void'($urandom(rng_seed));` became `rng_discard = $urandom(rng_seed);` (plus
the `rng_discard` declaration). Same call, used as a function instead of a
void-cast statement; vendor-neutral. `amd-doc-search` returned no Answer
Record for this message.

Not verified: the Icarus regression (`scripts/run_sim.sh`) with this edit. The
Icarus on this machine is 11.0 and fails on the untouched
`rtl/pkg/dma_pkg.sv:27` (`parameter int unsigned`) for every configuration, so
it cannot run this design at all.

## Tool issues hit (Vivado 2025.2)

- **`synth_design -lint -file` with a space in the path.** With an absolute
  report path under `D:/AMD Ross Test/...` the linter aborted with
  `Detected extra character(s) "Ross"` from an internal `rt::set_parameter`,
  wrote no report, and still returned success. The next `synth_design` then
  inherited the pending lint request: the FIFO memory came out as an
  unresolved `bboxRAM` black box and `opt_design` stopped on DRC INBB-3.
  `build.tcl` therefore passes the lint report path relative to the design
  root, checks that the report exists, and fails if synthesis leaves any
  black box.
- **Post-route `phys_opt_design -directive AggressiveExplore` crashed Vivado**
  (`EXCEPTION_ACCESS_VIOLATION`) on an 8.500 ns run. The step was removed from
  `build.tcl` and all committed reports were regenerated without it. The crash
  killed the first MCP session, so the final builds and the final xsim run
  come from a second session.
- `-retiming` is reported as deprecated in favour of `-global_retiming`. It
  still works and is what the committed reports were built with.
