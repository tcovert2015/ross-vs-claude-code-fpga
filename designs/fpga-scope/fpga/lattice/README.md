# fpga-scope on Lattice Radiant (Certus-NX `LFD2NX-40-8BG256C`)

Port of the vendor-neutral `scope_top` to Lattice Radiant 2026.1 with an AXI4-Lite CSR front-end:
`scope_axil_top` = `scope_top` (`XPORT="CSR"`, `RLE_EN=1`) + `rtl/if/scope_axil.sv`. No vendor
primitives were added; the capture buffer is still inferred from `rtl/prim/prim_ram_1r1w.sv`.

Tools used for everything below: Radiant 2026.1.1.229.0, Synplify Pro X-2025.09LR-SP1 (build 154R),
Questa Lattice OEM Edition 2025.2 (all three version strings are in the committed reports/logs).

| File | What |
|---|---|
| `scope_axil_top.sv` | Radiant top: `s_axi_*` AXI4-Lite slave + `probe`, `trig_ext_i/o`, `armed`, `triggered`; parameters `PROBE_W`, `DEPTH_LOG2` (plus `RLE_EN`, `ID_VALUE`) pass through |
| `build.tcl` | one configuration: creates the project, Synplify Pro synthesis, map, PAR, post-route STA; copies the reports |
| `build_all.ps1` | runs `build.tcl` for (32, 8), (32, 12), (32, 15) |
| `scope.sdc` | `create_clock` 10.000 ns on `clk` (the only constraint; no `.pdc`, pins are auto-placed) |
| `summarize.py` | scrapes `reports/` into `reports/summary.md` (the tables below are pasted from it) |
| `reports/<cfg>/` | `synthesis.srr` (Synplify log), `map.mrp`, `par.par`, `timing.twr`, `console.txt` (full `radiantc` console output) |
| `../../sim/run_questa.ps1` | Questa regression; logs in `../../sim/questa_<tb>.log` |

## How to run

```powershell
# one configuration (PROBE_W DEPTH_LOG2) -> fpga/lattice/reports/w<PROBE_W>_d<DEPTH_LOG2>/
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe fpga\lattice\build.tcl 32 12

# the three README configurations, then regenerate the summary tables
pwsh fpga\lattice\build_all.ps1
python fpga\lattice\summarize.py > fpga\lattice\reports\summary.md

# Questa regression (needs python for the tb_csr golden vectors, same generator as sim/run.sh)
pwsh sim\run_questa.ps1
```

`build.tcl` works from any directory; the project tree goes to `fpga/lattice/build/<cfg>/`
(git-ignored). The parameters reach the top through the implementation option
`HDL_PARAM "PROBE_W=..;DEPTH_LOG2=.."`; the Synplify log confirms them (e.g. `Found RAM mem,
depth=32768, width=33` in `reports/w32_d15/synthesis.srr`). `prj_run_par` also runs the post-route
static timing analysis (`timing -sethld`), which is where `timing.twr` comes from — there is no
separate STA command in the script.

## Results

All three configurations complete synthesis, map and PAR with 0 errors, 0 unrouted connections,
and meet 100 MHz with 0 setup and 0 hold timing errors.

### Utilization (Certus-NX, from `reports/<cfg>/map.mrp`)

Mirrors the "Logic usage" table of the top-level README (same `PROBE_W=32`, `RLE_EN=1`, so
`STORE_W=33`). Not like-for-like with the Agilex 3 rows in one respect: those were built with
`XPORT="UART"`; this top is `XPORT="CSR"` + AXI4-Lite, so there are no transport FIFOs, UART or
framing logic here.

| PROBE_W | Depth (2ᴺ) | LUT4 | of which logic / ripple / distributed RAM | registers | EBR blocks | of which capture buffer / win-meta | buffer bits |
|---|---|---|---|---|---|---|---|
| 32 | 256 (N=8) | 1,907 / 32,256 | 1355 / 360 / 192 | 1,198 / 32,811 | 2 / 84 | 1 / 1 | 8,448 |
| 32 | 4096 (N=12) | 2,030 / 32,256 | 1442 / 396 / 192 | 1,228 / 32,811 | 10 / 84 | 9 / 1 | 135,168 |
| 32 | 32768 (N=15) | 2,120 / 32,256 | 1514 / 414 / 192 | 1,251 / 32,811 | 67 / 84 | 66 / 1 | 1,081,344 |

Large RAMs (LRAM) used: w32_d8: 0, w32_d12: 0, w32_d15: 0.

* **The capture buffer maps to EBR (block RAM), not distributed RAM**, in all three configs. The
  map reports list every `u_scope/u_core/u_buf/mem_mem_*` instance as `PDPSC16K_MODE_inst`,
  `Type: EBR_CORE` (pseudo-dual-port 16K EBR): 1, 9 and 66 blocks. The one remaining EBR is the
  256-entry per-window metadata RAM (`u_core/u_win_meta`). No Large RAM (LRAM) is used.
* The 192 LUT4 of distributed RAM (identical in all configs) are **not** the buffer: they are the
  comparator configuration registers `scope_csr.cmp_q[0..3]` (four `depth=4, width=32` arrays,
  `Found RAM cmp_q[k]` in the Synplify log, 32 distributed RAM cells in its mapping summary).
* Logic barely moves with depth (1,907 → 2,120 LUT4, 1,198 → 1,251 registers); only the EBR count
  scales. N=15 uses 67 of the device's 84 EBRs.
* "buffer bits" is `2^DEPTH_LOG2 × 33`, the same definition as the top-level README column.

### Timing at 100 MHz (post-route STA, from `reports/<cfg>/timing.twr`)

| cfg | worst setup slack | setup slack 85 °C / 0 °C | Fmax (worst corner) | worst hold slack | timing errors (setup 85 / setup 0 / hold) | constraint coverage | comb. loops |
|---|---|---|---|---|---|---|---|
| w32_d8 | 1.828 ns | 1.828 / 1.890 ns | 122.369 MHz (8.172 ns) | 0.144 ns | 0 / 0 / 0 | 85.3807% | none |
| w32_d12 | 2.303 ns | 2.303 / 2.367 ns | 129.921 MHz (7.697 ns) | 0.124 ns | 0 / 0 / 0 | 86.0572% | none |
| w32_d15 | 1.412 ns | 1.412 / 1.456 ns | 116.442 MHz (8.588 ns) | 0.145 ns | 0 / 0 / 0 | 88.3501% | none |

Fmax is the slower of the two setup corners (85 °C); hold is analysed at the fast (`m`) corner.
Worst paths (first path of section 2.3 in each `timing.twr`): w32_d8 `u_axil/st[1]` → a
`u_csr/cmp_q` clock-enable (9 logic levels); w32_d12 `u_axil/st[1]` → `u_axil/rdata_q[12]`
(11 levels, the combinational CSR read mux); w32_d15 `u_trigger/dly[1][11]` →
`u_core/u_win_meta` write-enable (21 levels).

Constraint coverage is 85–88 %, not 100 %: the only constraint is the clock, so the
register-to-register paths are covered but the top-level I/O is not (`timing.twr` §1.4 lists the
141 I/O ports without constraint; register pins fed straight from a port, such as the `rst` →
`LSR` pins listed there, show up as "no arrival time"). That is deliberate — `scope_axil_top` is meant to sit inside a design behind an
AXI interconnect, and its pins here are auto-placed, so I/O delays would be invented numbers. The
slack/Fmax above are therefore internal (reg-to-reg) figures. If the block is ever pinned out
directly, add `set_input_delay`/`set_output_delay` and a `.pdc`.

### Warnings

| cfg | Synplify @E | Synplify @W | Synplify @N | map errors / criticals / warnings | PAR errors / warnings | unrouted |
|---|---|---|---|---|---|---|
| w32_d8 | 0 | 11 | 319 | 0 / 0 / 28 | 0 / 14 | 0 |
| w32_d12 | 0 | 13 | 316 | 0 / 0 / 28 | 0 / 14 | 0 |
| w32_d15 | 0 | 16 | 321 | 0 / 0 / 28 | 0 / 14 | 0 |

Synplify @W by message ID:

| cfg | BN132 | BW295 | CL246 | CL260 | FX107 | FX310 |
|---|---|---|---|---|---|---|
| w32_d8 | 0 | 1 | 6 | 1 | 2 | 1 |
| w32_d12 | 3 | 1 | 6 | 0 | 2 | 1 |
| w32_d15 | 6 | 1 | 6 | 0 | 2 | 1 |

Map warnings by message ID: w32_d8: 71003020 ×28; w32_d12: 71003020 ×28; w32_d15: 71003020 ×28.

No errors or critical warnings in any stage. PAR reports 14 messages and the map report 28 (the
same 14, listed twice). The full console output in `reports/<cfg>/console.txt` has one further
warning that appears in none of the four tool reports: `35811116 Attribute 'RESP_OKAY' on Module
'scope_axil' cannot be supported` (×1 per config).

| Message | Count | Assessment |
|---|---|---|
| map/PAR `71003020` Top module port ... does not connect to anything | 14 unique (`s_axi_awaddr[1:0]`, `s_axi_araddr[1:0]`, `s_axi_awprot[2:0]`, `s_axi_arprot[2:0]`, `s_axi_wstrb[3:0]`) | Expected. CSRs are word-addressed, `PROT` is ignored and `WSTRB` is documented as "accepted, not enforced" in `scope_axil.sv`. These pins disappear when the block is embedded. |
| Synplify `FX107` RAM ... does not have a read/write conflict check | 2 (`u_buf`, `u_win_meta`) | **The one to understand.** `prim_ram_1r1w` promises old-data on a same-address read-during-write; Synplify maps to EBR without adding collision logic, so hardware may return something else on that cycle. My analysis (from the RTL, not a measurement): in this top both read ports have `rd_en` tied high and their read addresses (`drain_addr`, `win_sel_q`) come from CSR state, so a collided read is refreshed on the next clock, and the host only drains after capture has stopped writing. I did not find a consumer of a collided read in `XPORT="CSR"` mode, so I left the option off rather than add bypass logic to the buffer. Not verified in gate-level simulation or on hardware. The UART/STREAM FIFOs (not built here) use the same primitive and would need their own review. |
| Synplify `CL246` Input port bits ... unused | 6 | Benign: reserved bits of `trig_combine` (4) and the low address bits of `awaddr`/`araddr` (2). |
| Synplify `CL260` Pruning register bit 3 of `weff_log2_q` (N=8 only) / `BN132` Removing equivalent instance `slice_mask[..]` (3 at N=12, 6 at N=15) | 1 / 3 / 6 | Benign optimisation of the window-slicing logic; which message appears depends on `DEPTH_LOG2`. |
| Synplify `BW295` Forward annotation of clocks to input pins not allowed | 1 | Tool note about how the `clk` constraint is forward-annotated; the clock is constrained (see the `create_clock` echoed in `timing.twr` §2.1). |
| Synplify `FX310` Ignoring option `-dcc_insertion` | 1 | Flow default not applicable to this device; nothing to do. |
| `35811116` Attribute `RESP_OKAY` cannot be supported | 1 (console only) | The netlist import complaining about the `RESP_OKAY` localparam in `scope_axil.sv`; no functional effect seen (BRESP/RRESP are constant OKAY and `tb_axil_top` checks them at RTL level). |

The 316–321 Synplify `@N` notes are informational (file reads, FSM/RAM inference, etc.) and were
not reviewed line by line.

## Questa regression

`sim/run_questa.ps1` compiles with `vlog -sv` and runs `vsim -c` from the QuestaSim bundled with
Radiant, one library per testbench, from the repo root (same source order and `-timescale 1ns/1ps`
as `sim/run.sh`). Result of the committed run — each log has `TB_RESULT: PASS`, 0 errors,
0 warnings:

| Testbench | Log | Result |
|---|---|---|
| `tb_smoke` | `sim/questa_tb_smoke.log` | PASS |
| `tb_csr` (w32_d8 and w512_d10 legs) | `sim/questa_tb_csr.log` | PASS |
| `tb_csr_if` (Avalon-MM and AXI4-Lite legs) | `sim/questa_tb_csr_if.log` | PASS |
| `tb_axil_top` (new, see below) | `sim/questa_tb_axil_top.log` | PASS |

`sim/tb_axil_top.sv` is new: the existing testbenches never instantiate the Radiant wrapper, so
this one drives `scope_axil_top` through `s_axi_*` (ID readback, a CSR round trip, arm +
force-trigger raising `armed`/`triggered`, and a 256-sample `BUF_DATA` drain of a counter probe).
It is RTL-level only and runs with `RLE_EN=0`; there is no gate-level (post-synthesis or
post-route) simulation.

## Source changes outside `fpga/lattice/`

Questa rejected three identifiers that are used before their declaration (`vlog-2730` /
`vlog-2388`); Verilator accepts that. Radiant's own front end had flagged the RTL one as well
(`VERI-1875 identifier sample_en is used before its declaration` on the console of the first
build; absent from the committed `console.txt` files, which were produced after the fix). The fix
in each case is only to move the declaration above its first use — no logic, names or widths
changed:

| File | Change |
|---|---|
| `rtl/scope_top.sv` | the four `wire` declarations `dec_tick`, `qual_hit`, `sample_en`, `trig_fire` moved above the `always_ff` that reads `sample_en` (vendor-neutral; SystemVerilog requires declaration before use) |
| `sim/tb_csr.sv` | `win_rd_addr` / `win_rd_data` declared before the two instances that connect them |
| `sim/tb_csr_if.sv` | `rd` declared before the `_unused` sink that references it |
| `.gitignore` | `!sim/questa_*.log` so the Questa transcripts can be committed |

No other Verilator-only constructs needed changing. **Not re-verified:** Verilator is not
installed on this machine, so `sim/run.sh` (and the formal proofs) were not re-run after the
`scope_top.sv` edit. The reordered files compile and pass in Questa, and all three Radiant
builds were re-run from scratch after the edit, so the reports here match the committed RTL.

## Not done

* No bitstream, no pin constraints, nothing run on hardware.
* No gate-level simulation; the `FX107` assessment above is by inspection.
* Only the three `PROBE_W=32` configurations were built; other widths are untested on Certus-NX.
* Single PAR run per configuration (default seed/strategy), no seed sweep.
