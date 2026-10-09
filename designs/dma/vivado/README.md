# PCIe DMA engine on AMD Vivado (Artix-7)

Vivado port of the Quartus flow in `quartus/`. Everything below was run with
**Vivado 2025.2** (build 6299465) on Windows; every number is taken from a
report or log committed under `vivado/reports/` or `sim/build/`.

| Item | Value |
|---|---|
| Part | `xc7a100tcsg324-1` |
| Top / parameters | `pcie_dma_top`, `SYS_IF="AXI4"`, `RESET_SYNC=1` |
| Clock | `clk`, 8.000 ns (125 MHz), as in `quartus/pcie_dma.sdc` |
| Mode | out-of-context (`synth_design -mode out_of_context`), the equivalent of the Quartus virtual pins |

**Headline: the design does not meet 125 MHz on this part/speed grade
(WNS −1.035 ns). It closes at 9.25 ns (108 MHz) with thin margin and at
9.75 ns (102.6 MHz) with 0.25 ns of margin.** Details in [Timing](#timing).

## How to run

```bat
rem lint + synth + opt/place/route + reports  ->  vivado\reports\
vivado\build.bat

rem same flow at another period / with other directives -> vivado\reports\<tag>\
vivado\build.bat tag p9p25 period 9.25 lint 0
vivado\build.bat tag spread place_directive AltSpreadLogic_high lint 0

rem xsim regression (AXI4, AXI4+STALLS, AXI4+RESET_SYNC; seeds 1 2 3)
scripts\run_xsim.bat
```

`build.bat` only locates Vivado (`%VIVADO%`, default
`C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`) and runs
`vivado -mode batch -source vivado/build.tcl -tclargs ...`; the options are
documented at the top of `build.tcl`. Scratch output (checkpoints, `.Xil`) goes
to `vivado/build/`, which is git-ignored. Differently tagged runs can run in
parallel.

Files:

| File | Purpose |
|---|---|
| `vivado/build.tcl` | non-project flow: lint, synth, opt, place, phys_opt, route, reports |
| `vivado/build.bat` | launcher |
| `vivado/pcie_dma.xdc` | constraints (port of `quartus/pcie_dma.sdc`) |
| `vivado/reports/` | reports + `vivado.log` of the 125 MHz default run |
| `vivado/reports/<tag>/` | the other runs listed under [Timing](#timing) |
| `scripts/run_xsim.ps1`, `.bat` | xsim regression |
| `sim/build/xsim_<cfg>_seed<n>.log` | xsim logs (force-added: the repository root `.gitignore` ignores `**/build/`, so re-running needs `git add -f` to update them) |

### Constraints

`pcie_dma.xdc` mirrors the SDC one-for-one: 8 ns clock, `set_false_path -from
rst_n`, 1 ns input/output delay on every bus port. Two differences:

* no `derive_clock_uncertainty` (Vivado applies clock uncertainty itself);
* `ASYNC_REG` is set on the two `reset_sync` flops. The RTL carries only an
  `altera_attribute` for them, which Vivado ignores; setting the property in
  the XDC avoids touching the RTL. Confirmed applied to
  `g_rst_sync.u_rst_sync/sync_q_reg[0]` and `[1]` in the routed checkpoint.

`timing_summary.rpt` `check_timing` reports 0 unclocked registers, 0
unconstrained endpoints, 0 ports without I/O delay.

## Simulation (xsim)

`scripts\run_xsim.bat` compiles each configuration once (`xvlog -sv`, `xelab`)
and runs it per seed (`+SEED=<n>`). Pass criterion is the one from
`scripts/run_sim.sh`: the log contains `=== PASS`.

| Configuration | Defines | seed 1 | seed 2 | seed 3 |
|---|---|---|---|---|
| `AXI4` | `USE_AXI` | PASS | PASS | PASS |
| `AXI4_STALLS` | `USE_AXI STALLS` | PASS | PASS | PASS |
| `AXI4_RSTSYNC` (extra) | `USE_AXI RESET_SYNC_EN` | PASS | PASS | PASS |

9/9 pass. `AXI4_RSTSYNC` was not asked for; it is included because it is the
`RESET_SYNC=1` parameterization that `build.tcl` actually synthesizes. The
three seeds produce different stimulus (e.g. `descs=111/106/105` in the
`coverage` line of the logs), so the seed plusarg is effective in xsim. The
stimulus is not the same as under Icarus for a given seed (different
`$urandom` generators).

## RTL / testbench changes

**No synthesizable RTL was changed.** One testbench line was changed:

`sim/tb_pcie_dma.sv:481`

```diff
-    void'($urandom(rng_seed));   // note: Icarus updates the seed arg in place
+    gi = $urandom(rng_seed);   // note: Icarus updates the seed arg in place
```

xsim rejects the original at elaboration: `ERROR: [XSIM 43-3122] ... Line 481.
urandom system task is not supported` (it does not accept `$urandom` called in
a `void'()` cast). Assigning the result to the existing scratch variable `gi`
is standard SystemVerilog and seeds the generator the same way; `gi` is
overwritten by `csr_rd` before its only later use (line 700).

Not verified: this line under Icarus. The Icarus on this machine is 11.0,
which fails on the unmodified `rtl/pkg/dma_pkg.sv:27` (`parameter int
unsigned` in a package) before reaching the testbench, so `scripts/run_sim.sh`
could not be run here.

## Lint (`synth_design -lint`)

Source: `vivado/reports/lint.rpt`.

| Severity | Count |
|---|---|
| Error | 0 |
| Critical warning | 0 |
| Warning | 12 (ASSIGN-10 x10, ASSIGN-6 x2) |

| Rule | Signal | Where | Assessment |
|---|---|---|---|
| ASSIGN-10 | `avm_readdata`, `avm_readdatavalid`, `avm_waitrequest` | `pcie_dma_top.sv:60-62` | Not real. Inputs of the Avalon SYS bus, unused because `SYS_IF="AXI4"`. |
| ASSIGN-10 | `hrdata`, `hready`, `hresp` | `pcie_dma_top.sv:110-112` | Not real. Same, AHB group. |
| ASSIGN-10 | `axi_bid`, `axi_rid` | `gmm_to_axi4.sv:53,70` | Not real. Single-ID master (`awid`/`arid` tied to 0), IDs need no checking. |
| ASSIGN-10 | `axi_bresp`, `axi_rresp` (bit 0) | `gmm_to_axi4.sv:54,72` | Intentional, worth knowing. Only bit 1 is decoded, so SLVERR/DECERR raise `err` and EXOKAY (`01`) is treated as OKAY. Correct for a master that never issues exclusive accesses. |
| ASSIGN-6 | `d` (from bit 96) | `dma_descriptor_fetch.sv:112` | Not real. Reserved descriptor bytes and the upper half of the 64-bit SYS address field (`SADDR_W`=32). |
| ASSIGN-6 | `ctrl_field` (from bit 4) | `dma_descriptor_fetch.sv:120` | Not real. Only control bits 0-3 are defined. |

None of the 12 lint findings is a defect. All were already waived for
Verilator in the source (`lint_off UNUSEDSIGNAL`).

### Synthesis warnings worth more attention than the linter's

Source: `vivado/reports/vivado.log` ("Synthesis finished with 0 errors, 0
critical warnings and 388 warnings").

| ID | Count | Assessment |
|---|---|---|
| Synth 8-7137 "has both Set and reset with same priority" | 17 | **Real (coding style, not a functional bug).** `gmm_to_axi4.sv` `aw_addr_q`/`aw_len_q` and `dma_descriptor_fetch.sv` `beats[]` are assigned inside an `always_ff` that has an asynchronous reset branch, but are not themselves reset. The reset therefore has to act as a hold condition on those flops. Moving them to a reset-less `always_ff` (as `dma_fifo.sv` already does for its memory) would remove the warning. Left unchanged. |
| Synth 8-3936 / 8-6014 | 2 / 1 | Benign. `d` trimmed 256 -> 192 bits and `beats_reg[3]` removed: the fourth descriptor beat is reserved and never read. Costs nothing, but the last beat is fetched from the host and discarded. |
| Synth 8-11067 `parameter` in package treated as `localparam` | 104 | Benign, language pedantry about `dma_pkg.sv`. |
| Synth 8-3917 port driven by constant | 100 (message limit) | Expected: idle Avalon/AHB outputs, constant AXI qualifiers, `csr_waitrequest`. |
| Synth 8-7129 port unconnected | 100 (message limit) | Expected: same unused inputs as the lint items. |

Implementation warnings are all consequences of out-of-context mode (no
`HD.CLK_SRC`, no `HD.PARTPIN_LOCS`: Route 35-197/198, Timing 38-242,
DRC 23-814).

## Utilization

Source: `vivado/reports/utilization.rpt` (post-route, 125 MHz default run).

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 1345 | 63400 | 2.12 |
| - LUT as logic | 1001 | 63400 | 1.58 |
| - LUT as distributed RAM | 344 | 19000 | 1.81 |
| Slice registers (FF) | 825 | 126800 | 0.65 |
| Block RAM tiles | 0 | 135 | 0.00 |
| DSPs | 0 | 240 | 0.00 |
| Slices | 451 | 15850 | 2.85 |

No block RAM is used: `dma_fifo` (256 x 64) reads its memory
asynchronously (show-ahead), which on 7-series can only map to LUT RAM. That
FIFO is 595 of the LUTs (344 RAM + 251 logic, mostly the read mux;
`utilization_hier.rpt`); the source comment already suggests a vendor FIFO for
deep instances. Per module (FIFO included in the mover):
`dma_data_mover` 915 LUT / 244 FF, `dma_descriptor_fetch` 223 / 202,
`dma_csr` 134 / 169, `gmm_to_axi4` 18 / 50.

LUT/FF counts move by a few between runs because `phys_opt_design` replicates
registers.

## Timing

### At 125 MHz (8.000 ns)

Source: `vivado/reports/timing_summary.rpt`.

| WNS | TNS | Failing setup endpoints | WHS | THS | WPWS |
|---|---|---|---|---|---|
| **−1.035 ns** | −13.005 ns | 19 of 5248 | +0.126 ns | 0.000 ns | +2.750 ns |

**Setup is not met.** Hold and pulse width are met. The design is fully
routed (1739/1739 nets, 0 routing errors, `route_status.rpt`).

Worst path (`timing_worst_setup.rpt`): `u_core/u_mover/w_rem_reg[31]` ->
`u_core/u_mover/w_burstcount_q_reg[*]/CE`, 8.746 ns data path, 13 logic levels
(3 CARRY4 + 10 LUT), 61 % of it routing. This is the write-burst sizing in
`dma_data_mover.sv`, computed in a single cycle: `min3(MAX_BURST_BEATS, w_rem,
beats_to_boundary(w_addr))`, compared against the FIFO level, into
`w_can_issue`, into the enables of `w_burstcount_q`/`w_dcnt`. The ten worst
setup paths in `timing_summary.rpt` all have slack between −1.035 and
−0.907 ns.

### Does tool effort close it? No.

Four more 8.000 ns runs with different directives, same RTL and XDC:

| Run (`reports/<tag>/`) | Directives | WNS | TNS |
|---|---|---|---|
| (default) | all Default | −1.035 | −13.005 |
| `explore` | opt/place/route Explore, phys_opt AggressiveExplore, post-route phys_opt | −0.857 | −9.989 |
| `end` | place ExtraNetDelay_high | −1.027 | −11.061 |
| `end_explore` | place ExtraNetDelay_high, phys_opt + route AggressiveExplore, post-route phys_opt | −1.021 | −10.383 |
| `spread` | place AltSpreadLogic_high | **−0.825** | −11.718 |

The best is still 0.83 ns short, so 125 MHz needs an RTL change on this
device and speed grade, not a different strategy.

### Achievable Fmax

By slack arithmetic the default run achieves 8.000 + 1.035 = 9.035 ns
(110.7 MHz); the best 8 ns run (`spread`) achieves 8.825 ns (113.3 MHz). Those
are estimates, so the flow was re-run at relaxed periods (default directives):

| Period | Frequency | WNS | TNS | WHS | Result | Report dir |
|---|---|---|---|---|---|---|
| 9.000 ns | 111.1 MHz | −0.031 | −0.031 | +0.089 | fails (1 endpoint) | `p9p00` |
| 9.250 ns | 108.1 MHz | **+0.060** | 0.000 | +0.089 | **closes** | `p9p25` |
| 9.500 ns | 105.3 MHz | −0.052 | −0.297 | +0.061 | fails (7 endpoints) | `p9p50` |
| 9.750 ns | 102.6 MHz | **+0.254** | 0.000 | +0.100 | **closes** | `p9p75` |

* **9.25 ns (108.1 MHz) is the shortest period demonstrated to close**, with
  60 ps of margin.
* The 9.5 ns run missing by 52 ps while 9.25 ns passes shows that result is
  not robust: once the target is nearly met Vivado stops optimizing, and
  run-to-run placement variation here is larger than the margin. (During
  development the 8 ns default result also moved by several tenths of a
  nanosecond when the `ASYNC_REG` property was added to the XDC; that earlier
  run is not committed, so no figure is quoted for it.)
* **Treat ~100 MHz (10 ns) as the safe figure**; 9.75 ns (102.6 MHz) closed
  with 0.25 ns of margin.

Caveats on all of these numbers: out-of-context with no `HD.CLK_SRC`, so the
clock is ideal apart from Vivado's default uncertainty (0.035 ns), and the
1 ns I/O delays are the placeholder budget from the SDC. Integrated behind a
real PCIe core the clock skew and bus timing will differ.

### What would close 125 MHz

Not done here, because it changes core RTL behaviour and would need the full
3-bus regression and the formal proofs re-run: register the burst-size
candidate in `dma_data_mover.sv` (compute `w_cand`/`r_cand` in one cycle,
compare against the FIFO level and issue in the next). That costs one idle
cycle per burst and splits the 13-level path roughly in half. A faster speed
grade (`-2`) is the non-RTL alternative; it was not tried.

## DRC

Source: `vivado/reports/drc.rpt`. 0 errors, 2 warnings:

* `CFGBVS-1` configuration voltage properties not set. Irrelevant for an
  out-of-context IP block; set in the real top level.
* `RTSTAT-10` 262 nets have no routable loads. These are the output ports of
  the block (`axi_awaddr`, `host_address`, `csr_readdata`, ...), which have no
  load because nothing is connected to them out-of-context.

## Not done

* 125 MHz timing closure (see above).
* Icarus re-run of the one-line testbench change (local Icarus too old).
* Only `SYS_IF="AXI4"` was built and simulated in Vivado; `build.tcl` accepts
  `sys_if AVALON|AHB` but those were not run.
* No bitstream: the block is implemented out-of-context, as specified.
