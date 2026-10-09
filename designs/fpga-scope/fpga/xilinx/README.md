# fpga-scope on AMD Vivado (Artix-7, AXI4-Lite)

`scope_axil_top` = `scope_top` (`XPORT="CSR"`) + `rtl/if/scope_axil.sv`, wrapped with a standard
`s_axi_*` AXI4-Lite slave port group for Vivado IP Integrator. Built out-of-context for
`xc7a100tcsg324-1` at **100 MHz** with Vivado 2025.2, three configurations, all timing-clean.

| File | What |
|---|---|
| `scope_axil_top.sv` | AXI4-Lite top. Parameters `PROBE_W`, `DEPTH_LOG2`, `RLE_EN` (default 1), `ID_VALUE` pass through to `scope_top`. Ports: `clk`, `s_axi_aresetn`, `s_axi_*`, `probe`, `trig_ext_i/o`, `armed`, `triggered`. |
| `scope.xdc` | OOC constraints: 10 ns clock on `clk`, 3 ns boundary budget on every port. |
| `build.tcl` | Non-project flow: lint → synth (OOC) → opt/place/route → reports. |
| `reports/w<PROBE_W>_d<DEPTH_LOG2>/` | `lint`, `utilization` (+`_synth`, `_hier`), `ram_utilization`, `timing_summary`, `methodology`, `drc` reports and a `summary.txt`. |
| `reports/vivado_mcp_session.log` | Transcript of the Vivado session that produced everything here, including the failed first attempts quoted below. |
| `../../sim/run_xsim.tcl` | xsim regression; transcripts in `../../sim/xsim_<tb>.log`. |

## How to run

```sh
# one configuration (RLE_EN is an optional third argument, default 1)
vivado -mode batch -source fpga/xilinx/build.tcl -tclargs 32 8
vivado -mode batch -source fpga/xilinx/build.tcl -tclargs 32 12
vivado -mode batch -source fpga/xilinx/build.tcl -tclargs 32 15

# xsim regression (needs python on PATH for the tb_csr golden vectors)
vivado -mode batch -source sim/run_xsim.tcl
```

Or from an open Vivado Tcl console: `set argv {32 12}; source fpga/xilinx/build.tcl` and
`set argv {}; source sim/run_xsim.tcl`. **That second form is how every result in this
directory was produced** (one Vivado Tcl session, scripts `source`d into it). The
`vivado -mode batch` command lines above were not executed.

## Results (Artix-7 `xc7a100tcsg324-1`, speed -1, 100 MHz, routed, out-of-context)

`PROBE_W=32`, `RLE_EN=1` (stored word = 33 bits), `XPORT="CSR"`, AXI4-Lite front-end. Mirrors
the top-level README's Agilex 3 "Logic usage" table; note that table is the `XPORT="UART"`
build, which additionally contains the drain engine, UART and CDC FIFOs, so the logic columns
are not like-for-like.

| PROBE_W | Depth (2ᴺ) | Slice LUTs | Slice FFs | RAMB36 | RAMB18 | buffer bits | WNS (ns) | TNS (ns) | WHS (ns) |
|---|---|---|---|---|---|---|---|---|---|
| 32 | 256 (N=8)    | 1,186 / 63,400 (1.87%) | 1,181 / 126,800 (0.93%) | 0  | 2 | 8,448     | +0.726 | 0.000 | +0.060 |
| 32 | 4096 (N=12)  | 1,235 / 63,400 (1.95%) | 1,212 / 126,800 (0.96%) | 4  | 1 | 135,168   | +0.288 | 0.000 | +0.058 |
| 32 | 32768 (N=15) | 1,277 / 63,400 (2.01%) | 1,255 / 126,800 (0.99%) | 33 | 1 | 1,081,344 | +0.581 | 0.000 | +0.133 |

Sources: `reports/<cfg>/utilization.rpt` (Slice LUTs, Slice Registers, Block RAM table),
`reports/<cfg>/timing_summary.rpt` (Design Timing Summary; "All user specified timing
constraints are met" in all three), `buffer bits` = `DEPTH × 33` as reported in the "Memory
Description" table of `ram_utilization.rpt`. No LUTs are used as memory in any configuration
(`LUT as Memory = 0`). `summary.txt` repeats the same data; its `lut_cells` line counts LUT
primitives before LUT6_2 packing, so it is higher than "Slice LUTs" (e.g. 1,315 vs 1,186).

As on Agilex, logic is flat across depth (+91 LUTs / +74 FFs from N=8 to N=15, from wider
address/counter paths) and only the block RAM scales.

### What the capture buffer mapped to

**Block RAM in every configuration, no distributed RAM** (`ram_utilization.rpt`, `summary.txt`
`u_buf_primitives`). `prim_ram_1r1w` was inferred unmodified — no `ram_style` attribute needed.

| Config | `u_core/u_buf` (capture buffer) | BRAM capacity used / buffer bits | `u_core/u_win_meta` (window sideband) |
|---|---|---|---|
| N=8  | 1 × RAMB18E1, 256×33 simple dual-port | 18,432 / 8,448 | 1 × RAMB18E1 (256×9) |
| N=12 | 4 × RAMB36E1 (3 × 4096×9 + 1 × 4096×6) | 147,456 / 135,168 = 1.09× | 1 × RAMB18E1 (256×13) |
| N=15 | 33 × RAMB36E1 (33 × 32768×1) | 1,216,512 / 1,081,344 = 1.125× | 1 × RAMB18E1 (256×16) |

The overhead at N=12/15 is only 36 Kb-block granularity, inside the design doc's "≤ ~1.2× raw
BRAM" target. Both RAMs are simple dual-port with the read register left in fabric, which is
what the 1-cycle-latency, read-old-data contract of `prim_ram_1r1w` requires.

### Timing notes

* Worst setup path per config (`timing_summary.rpt`): N=8 `trig_ext_i` → `u_core` FSM
  (10 levels); N=12 `s_axi_aresetn` → CSR register resets (1 level, 7.4 ns of routing — the
  combinationally inverted reset fanning out to the CSR flops); N=15 `dec_cnt` → `u_core` FSM
  (register-to-register, 14 levels).
* The margins are small (0.3–0.7 ns) on a -1 device and include a 3 ns external budget on
  every port. Slack will move with placement in a real design; a registered reset in the
  parent, or a tighter/looser boundary budget, changes the port-limited paths directly.
* `report_methodology` (`methodology.rpt`): no `TIMING-*` violations. Two warning classes
  only: **XDCH-2** ×95 (same min/max input delay — deliberate, see `scope.xdc`) and
  **SYNTH-6** ×2 / ×5 / ×34 (no output register merged into the RAMB — inherent to the
  1-cycle read contract; adding one would change `prim_ram_1r1w` latency).
* `report_drc` (`drc.rpt`): 1 warning, **CFGBVS-1** (configuration bank voltage not set —
  a device-level property that does not apply to an out-of-context block). No errors.

### Constraint decisions (`scope.xdc`)

* **OOC**: `synth_design -mode out_of_context` (no I/O buffers) and
  `read_xdc -mode out_of_context`, following the non-project OOC recipe that `amd-doc-search`
  returned from UG903 "Out-of-Context Constraints" (*"In Non-Project Mode:
  `read_xdc -mode out_of_context constraints_ooc.xdc`"*) and UG901 "Creating a Lower-Level
  Netlist" (*"`-mode out_of_context` to have the tool not insert any I/O buffers"*).
* **`HD.CLK_SRC BUFGCTRL_X0Y0` on `clk`** so clock insertion is estimated as a BUFG-driven
  net. `amd-doc-search` returned nothing relevant for this property (the hits were Versal MBUFG
  and Spartan-3 DCM pages), so this is from general Vivado OOC practice, not a cited source.
* **I/O budget**: 3.0 ns `set_input_delay` / `set_output_delay -max` on every port, an
  assumption about the parent design, not a requirement of the core. Input min = max on
  purpose: with `-min 1.0` the build reported WHS = -0.254 ns on `s_axi_wdata` → CSR register
  paths purely because an OOC port launches at 0 ns while the capture flops see ~1.7 ns of
  estimated clock insertion (`vivado_mcp_session.log`, search `WHS=-0.254`).

## RTL lint (`synth_design -lint`)

Identical in all three configurations (`reports/<cfg>/lint.rpt`):

| Severity | Count | Rule |
|---|---|---|
| CRITICAL WARNING | 0 | — |
| WARNING | 1 | ASSIGN-1 (arithmetic result not used with full precision) |
| WARNING | 5 | ASSIGN-6 (bits assigned but not read) |
| **Total** | **6** | |

| Rule | Location | Item | Assessment |
|---|---|---|---|
| ASSIGN-1 | `scope_csr.sv:170` | `seq_idx = 2'(csr_addr - 8'(CSR_SEQ_CNT_BASE))` keeps 2 of 8 bits | Intentional: explicit `2'()` truncation, only consumed when `is_seq_addr` bounds the address to 4 words. No change. |
| ASSIGN-6 | `scope_axil.sv:99` | `_unused` | Deliberate unused-signal sink (`wstrb`, address LSBs), kept for Verilator `-Wall`. |
| ASSIGN-6 | `scope_axil_top.sv:129` | `unused_xport` | Same pattern in the new wrapper (stream/UART outputs unused in CSR mode). |
| ASSIGN-6 | `scope_top.sv:297` | `g_csr_mode.unused_csr_mode` | Same pattern. |
| ASSIGN-6 | `scope_top.sv:282` | `unused_status` | Same pattern. |
| ASSIGN-6 | `scope_trigger.sv:131` | `unused_combine_reserved` | Same pattern (reserved TRIG_COMBINE bits). |

Assessment: the lint is clean in substance. All five ASSIGN-6 hits are the repo's own
lint-waiver idiom for another tool, and the ASSIGN-1 is a guarded, explicit truncation. No
latches, multi-driven nets, incomplete cases or width-mismatched assignments were reported.
Nothing was waived or edited to change the count.

One finding came from the elaborator rather than the lint table, on the first run:
`WARNING: [Synth 8-6901] identifier 'sample_en' is used before its declaration`
(`scope_top.sv:161`). Fixed — see RTL changes.

Flow hazard found here and worked around in `build.tcl`: with Vivado 2025.2,
`synth_design -lint -file <path containing a space>` aborts internally
(`rt::set_parameter … Detected extra character(s)`), still prints "completed successfully",
writes no report, and leaves the *next* `synth_design` in linter mode — it emitted the RAMs as
`*_bboxRAM` black boxes and `opt_design` failed with DRC INBB-3. `build.tcl` therefore runs
the lint from inside the report directory with a bare file name.

## xsim regression (`sim/run_xsim.tcl`)

| Testbench | Covers | Result | Log |
|---|---|---|---|
| `tb_smoke` | harness | `TB_RESULT: PASS` | `sim/xsim_tb_smoke.log` |
| `tb_csr` | native CSR matrix, cfg_err lockout, BUF_DATA drain vs golden vectors (W=32/N=8 and W=512/N=10/RLE) | `TB_RESULT: PASS` | `sim/xsim_tb_csr.log` |
| `tb_csr_if` | same matrix through Avalon-MM and AXI4-Lite front-ends | `TB_RESULT: PASS` | `sim/xsim_tb_csr_if.log` |
| `tb_axil_top` (new) | `scope_axil_top` end to end over AXI4-Lite: ID/HWCFG, arm/trigger pins, 256-sample drain, seam position vs TRIG_INDEX | `TB_RESULT: PASS` | `sim/xsim_tb_axil_top.log` |

The logs are from the final RTL (run after the last RTL edit). xelab gets
`-timescale 1ns/1ps`, the same default `sim/run.sh` gives Verilator, because the RTL files
carry no `` `timescale ``.

`tb_csr` **does** need Python golden vectors (it `$readmemh`s the two `capture` sets), so
`run_xsim.tcl` generates exactly those two with `sim/model/scope_ref.py` and the arguments
from `sim/run.sh`. `tb_smoke`, `tb_csr_if` and `tb_axil_top` need none.

Testbench changes needed for xsim (all legal SystemVerilog before and after; no check was
weakened):

| File | Change | Why |
|---|---|---|
| `sim/tb_csr.sv` | `win_rd_addr` / `win_rd_data` declarations moved above the DUT instances that connect them | xvlog `ERROR: [VRFC 10-2938] 'win_rd_addr' is already implicitly declared` — used in a port connection before its declaration. |
| `sim/tb_csr_if.sv` | `rd, id_val, hwcfg_val` declaration moved above the `_unused` sink that references `rd` | xvlog `ERROR: [VRFC 10-3380] identifier 'rd' is used before its declaration`. |
| `sim/tb_csr.sv` | two STATUS poll loops: `do csr_rd(…); while (v[2:0] != 3'(SCOPE_ST_x));` → `do begin csr_rd(…); end while (v[2:0] != SCOPE_ST_x);` | xsim 2025.2 runs the original loop **once** and falls through (TB then failed `STATUS.triggered` at 12,320 ns). Reproduced in a 20-line standalone case: the same comparison is correct outside a do-while condition. Dropping only the cast made the loop never exit (50 ms watchdog); cast-free plus `begin/end` passes. Looks like an xsim defect, not a TB bug; `amd-doc-search` found no matching Answer Record. |

## RTL changes (vendor-neutral)

| File | Change | Justification |
|---|---|---|
| `rtl/scope_top.sv` | The four `wire` declarations `dec_tick`, `qual_hit`, `sample_en`, `trig_fire` moved above the `always_ff` that reads `sample_en`. No logic change. | IEEE 1800 declare-before-use; Vivado `Synth 8-6901`. Gone from the final lint transcripts. |
| `rtl/scope_csr.sv` | The comparator-lane "implemented" test and write mask are now selected from per-lane constants (`lane_impl`, `lane_mask`: a loop over the 16 constant lane indices) instead of being computed from the run-time `lane_idx` (`32 * 32'(lane_idx) < PROBE_W`, `lane_wmask(lane_idx)`). Same function, same `lane_wmask`. | **Timing closure at 100 MHz.** Vivado built the run-time form as 32-bit multiply/compare/shift carry chains in the CSR write path: 14 logic levels (8 × CARRY4) from `s_axi_wvalid` to `cmp_q`, WNS = **-0.333 ns** at N=8, and only +0.431 ns register-to-register (`vivado_mcp_session.log`, search `-0.333`). After the change that path is no longer critical and N=8 closes at +0.726 ns, with fewer LUT primitives (1,351 → 1,315, `lut_cells` in the same log). |

Verification of both: the four xsim testbenches above pass on the changed RTL — `tb_csr`
exercises every comparator × field × lane at `PROBE_W=32` and `512`, including top-lane
masking and unimplemented lanes, against the unchanged expectations. **Not re-verified:** the
Verilator regression (`sim/run.sh`), the SBY formal proofs and the Quartus build — none of
those tools are installed on this machine. The edits use only constructs already present in
the file (`always_comb`, `for (int unsigned …)`, the existing `lane_wmask` function).

## Not done / caveats

* No bitstream and no hardware run — out-of-context implementation only; no board pinout.
* The `vivado -mode batch` invocations were not executed (results come from `source` in a
  live session); `run_xsim.tcl` was exercised on Windows only.
* Not packaged as an IP-XACT core. `scope_axil_top` is meant for IP Integrator's
  "Add Module" (RTL module reference), which infers the `s_axi` interface from the port names
  plus the `X_INTERFACE_*` attributes; that inference was not tested in a block design.
* `s_axi_awprot` / `s_axi_arprot` are not implemented; `wstrb` is accepted and ignored
  (upstream `scope_axil` behaviour).
