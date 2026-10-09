# fpga-scope on AMD Vivado (Artix-7)

`scope_top` behind an AXI4-Lite slave, built out-of-context for `xc7a100tcsg324-1` at 100 MHz
with Vivado 2025.2, and the CSR / AXI4-Lite testbenches run under xsim.

| File | What |
|---|---|
| `scope_axil_top.sv` | Synthesis top: `scope_top` (`XPORT="CSR"`) + `rtl/if/scope_axil.sv`, `s_axi_*` port group |
| `scope.xdc` | 100 MHz clock + out-of-context port budgets |
| `build.tcl` | lint → synth → opt → place → phys_opt → route → reports, one configuration |
| `run_all.ps1` | runs `build.tcl` for the three README configurations, copies the Vivado logs |
| `reports/w<PROBE_W>_d<DEPTH_LOG2>/` | committed reports + `vivado.log` + `summary.txt` for each configuration |
| `../../sim/run_xsim.ps1` | xsim regression (`tb_smoke`, `tb_csr`, `tb_csr_if`, `tb_axil_top`) |
| `../../sim/xsim_<tb>.log` | committed xsim transcripts |

Every number below is copied from a file under `reports/` or from `sim/xsim_*.log`;
`reports/<cfg>/summary.txt` is the scraped one-page version of each configuration.

## The top level

`scope_axil_top` is structural: `scope_axil` drives `scope_top`'s `ext_csr_*` port.

- Parameters `PROBE_W`, `DEPTH_LOG2` (plus `NUM_CMP`, `SEQ_STAGES`, `RLE_EN`, `TS_W`, `ID_VALUE`)
  pass straight through. `RLE_EN` defaults to 1 here so the stored word is `PROBE_W+1` bits, the
  same configuration as the main README's "Logic usage" table.
- Ports: `clk`, `aresetn`, the AXI4-Lite slave `s_axi_{aw,w,b,ar,r}*` (32-bit data, 10-bit byte
  address = 256 CSR words; `awprot`/`arprot`/`wstrb` accepted and ignored), `probe[PROBE_W-1:0]`,
  `trig_ext_i`, `trig_ext_o`, `armed`, `triggered`.
- `X_INTERFACE_INFO` / `X_INTERFACE_PARAMETER` attributes associate `clk` and `aresetn` with the
  `s_axi` bus for IP Integrator. (IP Integrator inference itself was **not** exercised — no block
  design was built.)
- `aresetn` is active-low per AXI; the scope's reset is synchronous active-high, so the top
  registers `~aresetn` once. That flop is the only logic in the wrapper.
- One clock: the AXI port is in the capture domain (`scope_axil`'s documented contract). Put an
  AXI clock converter in front if the bus master is elsewhere.

## How to run

PowerShell 7 (`pwsh`), Vivado 2025.2 at `C:\AMDDesignTools\2025.2\Vivado\bin` (override with
`-VivadoBin <dir>` or `$env:VIVADO_BIN`). From `designs/fpga-scope/`:

```powershell
pwsh sim/run_xsim.ps1                    # xsim regression -> sim/xsim_<tb>.log   (needs python)
pwsh fpga/xilinx/run_all.ps1 -Parallel   # (32,8) (32,12) (32,15) -> fpga/xilinx/reports/
```

One configuration by hand (any `PROBE_W DEPTH_LOG2 [RLE_EN]`):

```powershell
vivado -mode batch -source fpga/xilinx/build.tcl -tclargs 32 12
```

The three-configuration parallel run takes about 4 minutes here; running it twice gave identical
numbers.

## Results (Artix-7 `xc7a100tcsg324-1`, speed -1, 100 MHz, post-route)

`PROBE_W=32`, `RLE_EN=1`, `XPORT="CSR"`, AXI4-Lite front-end included. Source:
`reports/<cfg>/utilization.rpt`, `ram_utilization.rpt`, `timing_summary.rpt`.

### Logic usage

| PROBE_W | Depth (2ᴺ) | Slice LUTs | Slice FFs | RAMB36 | RAMB18 | buffer bits |
|---|---|---|---|---|---|---|
| 32 | 256 (N=8)    | 1,248 / 63,400 (1.97%) | 1,182 / 126,800 (0.93%) | 0 / 135 | 2 / 270 | 8,448 |
| 32 | 4096 (N=12)  | 1,286 / 63,400 (2.03%) | 1,213 / 126,800 (0.96%) | 4 / 135 | 1 / 270 | 135,168 |
| 32 | 32768 (N=15) | 1,345 / 63,400 (2.12%) | 1,256 / 126,800 (0.99%) | 33 / 135 | 1 / 270 | 1,081,344 |

As on Agilex 3, the logic does not scale with depth (about +100 LUTs and +75 FFs from N=8 to
N=15, i.e. wider address counters); only the block RAM does. These numbers are not directly
comparable with the Agilex table: that one is `XPORT="UART"` (drain engine, UART, async FIFOs),
this one is `XPORT="CSR"` plus the AXI4-Lite adapter.

### What the capture buffer mapped to

**Block RAM in all three configurations; no distributed RAM anywhere in the design** ("LUT as
Memory" = 0 in every `utilization.rpt`, "LUTMs as Distributed RAM" = 0 in every
`ram_utilization.rpt`). No `ram_style` attribute or any other RTL change was needed —
`rtl/prim/prim_ram_1r1w.sv` infers a simple-dual-port block RAM as written.

| Config | `u_scope/u_core/u_buf/mem` (capture buffer) | Primitives | `u_win_meta/mem` (per-window metadata) |
|---|---|---|---|
| N=8  | 256 × 33 = 8,448 bits        | 1 × RAMB18E1                 | 256 × 9  → 1 × RAMB18E1 |
| N=12 | 4096 × 33 = 135,168 bits     | 4 × RAMB36E1                 | 256 × 13 → 1 × RAMB18E1 |
| N=15 | 32768 × 33 = 1,081,344 bits  | 33 × RAMB36E1 (32768 × 1 each) | 256 × 16 → 1 × RAMB18E1 |

So the RAMB18 column above is the buffer plus the window-metadata RAM at N=8, and the metadata RAM
alone at N=12/15. At N=15 the 33 RAMB36 hold 1,216,512 bits for a 1,081,344-bit buffer (1.125×);
at N=12, 4 RAMB36 hold 147,456 bits (1.09×).

Vivado notes for every buffer RAM (`Synth 8-7052` in `vivado.log`) that no output register could
be merged into the block RAM; the read data goes straight to the CSR read mux. It is not on the
critical path at 100 MHz.

### Timing at 100 MHz

All constraints met in all three configurations ("All user specified timing constraints are met"
in each `timing_summary.rpt`).

| Config | WNS (ns) | TNS (ns) | Failing endpoints | WHS (ns) | Flop-to-flop WNS (ns) | Input-port → flop WNS (ns) |
|---|---|---|---|---|---|---|
| N=8  | 0.190 | 0.000 | 0 | 0.125 | 0.689 | 0.190 |
| N=12 | 0.288 | 0.000 | 0 | 0.120 | 0.774 | 0.288 |
| N=15 | 0.358 | 0.000 | 0 | 0.070 | 0.545 | 0.358 |

WNS/TNS/WHS are the design-wide figures from the "Design Timing Summary". The last two columns
split out the `clk → clk` group (paths entirely inside the module) and the `clk_io → clk` group
(AXI/probe input ports to internal flops).

Read these with the constraints in mind (`scope.xdc`):

- The design is out of context, so port timing is a **budget I chose**, not a measurement: inputs
  may arrive up to 1.0 ns after the clock edge, outputs must be valid 2.0 ns before it. The budgets
  are referenced to a virtual clock with 1.6 ns latency so they line up with the buffered clock
  insertion delay that `HD.CLK_SRC` models (1.5–1.7 ns in these reports).
- Hold on port paths is false-pathed (not checkable out of context); flop-to-flop hold is checked.
- **The input budget is tight on purpose, and it is the limiting path.** `scope_axil` is
  combinational on the request channels, so `s_axi_wvalid`/`awvalid`/`awaddr` go through the
  adapter, the CSR address decode and the comparator lane write-mask arithmetic into the
  `u_csr/cmp_q` registers: 9–13 logic levels, 8.4–8.7 ns port-to-flop in these runs. An earlier
  run of N=12 with a 2.0 ns input budget **failed** that group by 0.45 ns (that run's reports were
  overwritten and are not committed). In practice: drive the AXI4-Lite request channels from
  registers placed near the scope (e.g. a register slice / the interconnect's output stage), or
  expect to add one if the master's outputs are late in the cycle.
- The same decode logic, launched from the `scope_axil` state register, is also the worst
  flop-to-flop path (0.55–0.77 ns slack), so there is not a large margin above 100 MHz on a -1
  Artix-7 for this top level. I did not sweep for Fmax.

### DRC

One check in each configuration (`drc.rpt`): `CFGBVS-1` (Warning) — missing `CFGBVS` /
`CONFIG_VOLTAGE` design properties. Those are board-level bitstream settings that belong to the
integrating design, not to an out-of-context module; left unset deliberately. Vivado also notes
(`DRC 23-814`) that connectivity DRCs are limited because the design is out of context.

## RTL lint (`synth_design -lint`)

Identical in all three configurations (`reports/<cfg>/lint.rpt`):

| Severity | Count |
|---|---|
| CRITICAL WARNING | 0 |
| WARNING | 6 |
| INFO | 0 |

| Rule | # | Where | Assessment |
|---|---|---|---|
| ASSIGN-6 "bits not read" | 5 | `scope_axil.sv:99` `_unused`; `scope_axil_top.sv:137` `unused_top`; `scope_top.sv:282` `unused_status`; `scope_top.sv:297` `g_csr_mode.unused_csr_mode`; `scope_trigger.sv:131` `unused_combine_reserved` | Benign. Each is the deliberate `wire unused_x = &{1'b0, ...}` sink the code base uses to keep Verilator `-Wall` clean; the linter is reporting exactly that the sink is never read. |
| ASSIGN-1 "arithmetic result not used with full precision" | 1 | `scope_csr.sv:152` `seq_idx = 2'(csr_addr - 8'(CSR_SEQ_CNT_BASE))` | Benign. Explicit 2-bit truncation of an address offset that is only used when `is_seq_addr` has already range-checked `csr_addr` to the four SEQ_CNT words. |

Assessment: clean. No latches, multi-driven nets, width-mismatched assignments, incomplete case
statements or clocking findings were reported; the six warnings are all intentional coding idioms
and I did not change RTL or add waivers for them.

The synthesis step itself reports 0 errors and 0 critical warnings (`vivado.log`). Its warnings are
`Synth 8-3917` ×4 (`s_axi_bresp`/`s_axi_rresp` tied to OKAY, by design), `Synth 8-7129` ×17 (N=8) /
×30 (N=12, N=15) (ports with no load: the ignored `awprot`/`arprot`/`wstrb`/address LSBs and
reserved `trig_combine` bits), and during routing `Route 35-198` ×87 (no `HD.PARTPIN_LOCS` on the
ports — expected for an unfloorplanned out-of-context module, and another reason to treat the port
timing as a budget).

## xsim regression

`sim/run_xsim.ps1` compiles the RTL + one testbench with `xvlog --sv`, elaborates with
`xelab --timescale 1ns/1ps`, runs `xsim --runall`, and saves the transcript.

| Testbench | Result | Log |
|---|---|---|
| `tb_smoke` | `TB_RESULT: PASS` | `sim/xsim_tb_smoke.log` |
| `tb_csr` (native CSR matrix, PROBE_W 32 and 512) | `TB_RESULT: PASS` | `sim/xsim_tb_csr.log` |
| `tb_csr_if` (CSR matrix through Avalon-MM and AXI4-Lite) | `TB_RESULT: PASS` | `sim/xsim_tb_csr_if.log` |
| `tb_axil_top` (new: capture through `scope_axil_top`) | `TB_RESULT: PASS` | `sim/xsim_tb_axil_top.log` |

`tb_axil_top` is new. `tb_csr_if` tests the `scope_axil` adapter against `scope_csr`+`scope_core`
only, so nothing exercised the wrapper; this one drives the real synthesis top over `s_axi_*`:
ID/HWCFG read, arm, `armed` pin, force trigger and `trig_ext_i` trigger, `triggered` pin, then
drains all 256 stored words (two 32-bit lanes each) and checks the ring is one contiguous run of
the counter stimulus.

Two things differ from the task description:

- **`tb_csr` does need Python golden vectors** (`$readmemh` of `sim/build/vectors/cap_w32_d8_*` and
  `cap_w512_d10_*`). `run_xsim.ps1` generates those two sets with `sim/model/scope_ref.py` using
  the same arguments as `sim/run.sh`. `tb_smoke`, `tb_csr_if` and `tb_axil_top` need none.
- The other twelve testbenches in `sim/run.sh` were not ported or run under xsim.

Verilator is not installed on this machine, so **`bash sim/run.sh` was not re-run** after the
source changes below. They are declaration reorders and one equivalent rewrite of two loop
conditions, but that is an argument, not a test result.

## Source changes

All vendor-neutral; no attributes, primitives or tool-specific pragmas were added to `rtl/`.

| File | Change | Why |
|---|---|---|
| `rtl/scope_top.sv` | Moved the four `wire dec_tick / qual_hit / sample_en / trig_fire` declarations above the `always_ff` that reads `sample_en`. No logic change. | `sample_en` was used before its declaration. IEEE 1800 requires declaration before use; Verilator accepts the forward reference, Vivado does not (`xvlog` `VRFC 10-3380`), so `scope_top` could not be compiled at all. This is the only RTL change. |
| `sim/tb_csr.sv` | Moved `win_rd_addr` / `win_rd_data` declarations above the instances that connect them. | Same rule: xsim treats the earlier port connection as an implicit declaration and then rejects the real one (`VRFC 10-2938`). |
| `sim/tb_csr_if.sv` | Moved `logic [31:0] rd, id_val, hwcfg_val;` above the `_unused` sink that references `rd`. | Same rule (`VRFC 10-3380`). |
| `sim/tb_csr.sv` | The two STATUS poll loops `do csr_rd(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_x));` now use a pre-cast `localparam ADDR_STATUS` and compare against the enum member directly. | xsim 2025.2 mis-evaluates a constant size cast inside a `do … while`: the cast in the condition made the loop exit after one pass, and once that was removed the cast in the argument read as X from the second pass on. Reproduced in a standalone 20-line test (not committed). Same meaning in any simulator. The identical casts outside `do … while` loops are fine and were left alone. |

## Tool behaviour worth knowing

Found while getting the flow to run from a checkout path that contains spaces
(`D:\AMD Ross Test\...`); both are handled in `build.tcl` with a comment at the spot.

- `read_verilog` / `read_xdc` take file *lists*, so paths are wrapped in `[list …]`.
- `synth_design -lint -file <absolute path with spaces>` prints `Detected extra character(s)` and
  the *next* `synth_design` in the same session then leaves every inferred RAM as an unresolved
  `bboxRAM` black box (`opt_design` stops with `DRC INBB-3`). `build.tcl` lints to a relative
  file name in the scratch directory and copies the report.
- On Windows, `synth_design` right after the lint run occasionally aborts with
  `Designutils 20-411 … could not be deleted and may be locked`; `build.tcl` retries it. It
  happened in two earlier runs and not in the committed ones.

## Not done

- No bitstream, no board, no hardware test — out-of-context implementation only.
- IP Integrator packaging / interface inference not exercised.
- Only the three `PROBE_W=32` configurations were built; no other widths, no `RLE_EN=0`, no Fmax
  sweep.
- `sim/run.sh` (Verilator) and the SymbiYosys proofs were not re-run after the source changes.
