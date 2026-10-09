# fpga-scope on Lattice Radiant (Certus-NX, `LFD2NX-40-8BG256C`)

Port of the scope to Lattice Radiant 2026.1 with Synplify Pro: an AXI4-Lite top, a scripted
synthesis → map → PAR → timing flow, and a QuestaSim regression. Every number below is copied
from a checked-in report under [`reports/`](reports/) or a log under `sim/questa_*.log`.

| File | What |
|---|---|
| [`scope_axil_top.sv`](scope_axil_top.sv) | build top: `scope_top` (`XPORT="CSR"`) + `scope_axil`, `s_axi_*` slave port group |
| [`build.tcl`](build.tcl) | Radiant flow, one `(PROBE_W, DEPTH_LOG2)` configuration per run |
| [`scope.sdc`](scope.sdc) | `clk` = 100 MHz |
| `reports/w<PROBE_W>_d<DEPTH_LOG2>/` | `synthesis.srr`, `map.mrp`, `par.par`, `timing_par.twr` (+ `synthesis_resources.rpt`, `pad.pad`) |
| [`../../sim/run_questa.sh`](../../sim/run_questa.sh) | Questa regression, logs in `sim/questa_<tb>.log` |

No `.pdc`: the top is a fabric-level block, so pins are left to PAR (132 PIOs, auto-placed —
see `pad.pad`). A real integration puts this behind a bus master inside the FPGA.

## The top: `scope_axil_top`

Parameters `PROBE_W` (default 32), `DEPTH_LOG2` (default 12), `RLE_EN` (default 1, as in the
main README's table, so the stored word is `PROBE_W+1` bits) and `ID_VALUE` pass straight
through to `scope_top`.

| Port group | Ports |
|---|---|
| clock / reset | `clk` (capture clock **and** AXI clock), `s_axi_aresetn` (active low, synchronous) |
| AXI4-Lite slave | `s_axi_awaddr[9:0]`, `s_axi_awprot[2:0]`, `s_axi_awvalid`, `s_axi_awready`, `s_axi_wdata[31:0]`, `s_axi_wstrb[3:0]`, `s_axi_wvalid`, `s_axi_wready`, `s_axi_bresp[1:0]`, `s_axi_bvalid`, `s_axi_bready`, `s_axi_araddr[9:0]`, `s_axi_arprot[2:0]`, `s_axi_arvalid`, `s_axi_arready`, `s_axi_rdata[31:0]`, `s_axi_rresp[1:0]`, `s_axi_rvalid`, `s_axi_rready` |
| scope | `probe[PROBE_W-1:0]`, `trig_ext_i`, `trig_ext_o`, `armed`, `triggered` |

Byte address; `addr[9:2]` is the CSR word of `docs/INTERFACES.md`. `awprot`/`arprot`/`wstrb`
and `addr[1:0]` are accepted and ignored, responses are always OKAY (the `scope_axil` contract).
The unused transport side of `scope_top` (`xclk`, byte stream, UART) is tied off.

## How to run

Build (Radiant Tcl console; one run per configuration, a few minutes each):

```sh
cd fpga/lattice
for d in 8 12 15; do
  /d/lscc/radiant/2026.1/bin/nt64/radiantc.exe build.tcl 32 $d    # <PROBE_W> <DEPTH_LOG2>
done
```

The project is created in `build/w32_d<N>/` (scratch, git-ignored); the four reports are copied
to `reports/w32_d<N>/` and the script exits non-zero if any is missing. Device, performance
grade (`8_High-Performance_1.0V`), Synplify Pro, top and the two HDL parameters are all set in
`build.tcl`; nothing is configured in the GUI.

Simulate (QuestaSim Lattice OEM Edition 2025.2 bundled with Radiant; Git Bash; needs `python`
for the golden-vector model, exactly as `run.sh` does):

```sh
bash sim/run_questa.sh                           # all 17 testbenches
bash sim/run_questa.sh tb_smoke tb_csr tb_csr_if # a subset
```

`QUESTA_BIN` and `PYTHON` override the tool locations.

## Results

Three configurations of the main README's Agilex 3 table, `PROBE_W=32`, `RLE_EN=1`. Note the
transport differs: this build is `XPORT="CSR"` + AXI4-Lite (no async FIFOs, drain codec or
UART), the Agilex table is `XPORT="UART"`, so the logic columns are not like-for-like.

### Utilization (`reports/*/map.mrp`, "Design Summary")

| PROBE_W | Depth (2ᴺ) | LUT4 | registers | EBR blocks | buffer bits |
|---|---|---|---|---|---|
| 32 | 256 (N=8)    | 1,909 / 32,256 (6%) | 1,198 / 32,811 (4%) | 2 / 84 (2%)   | 8,448 |
| 32 | 4096 (N=12)  | 2,030 / 32,256 (6%) | 1,228 / 32,811 (4%) | 10 / 84 (12%) | 135,168 |
| 32 | 32768 (N=15) | 2,120 / 32,256 (7%) | 1,251 / 32,811 (4%) | 67 / 84 (80%) | 1,081,344 |

LUT4 breakdown (logic / distributed RAM / ripple): 1,357 / 192 / 360, 1,442 / 192 / 396 and
1,514 / 192 / 414. "Buffer bits" is `DEPTH × 33`, the width and depth Synplify reports for the
inferred RAM (`synthesis.srr`: `Found RAM mem, depth=256|4096|32768, width=33`).

**What the capture buffer mapped to.** EBR, in every configuration. The map report's component
list places `u_scope/u_core/u_buf/mem_mem_*` on `PDPSC16K` cells of type `EBR_CORE`:
**1, 9 and 66 EBRs** for N = 8, 12, 15. The one remaining EBR in each build is
`u_scope/u_core/u_win_meta` (the 256-entry per-window metadata RAM). Large RAMs used: 0.
At N=15 the buffer takes 66 of the device's 84 EBRs — it fits, but that is the practical
ceiling for 33-bit words on an LFD2NX-40.

The 192 LUT4s of distributed RAM are **not** the capture buffer: they are the comparator
configuration registers `u_scope/u_csr/cmp_q` (four 4×32 arrays, `synthesis.srr` notes
MF135/FO126), which Synplify packs into 32 `SPR16X4` cells. That is a sensible mapping for
4-word arrays and it is the same count in all three builds.

### Timing (`reports/*/timing_par.twr`, post-PAR, `clk` = 10.000 ns)

| Config | Worst setup slack | Fmax (85 °C corner) | Fmax (0 °C corner) | Worst hold slack | Timing errors |
|---|---|---|---|---|---|
| (32, 8)  | 2.209 ns | 128.353 MHz | 128.982 MHz | 0.123 ns | 0 |
| (32, 12) | 2.142 ns | 127.259 MHz | 127.828 MHz | 0.146 ns | 0 |
| (32, 15) | 1.420 ns | 116.550 MHz | 116.932 MHz | 0.112 ns | 0 |

All three meet 100 MHz with zero failing endpoints at both setup corners and at hold. PAR
completed with 0 unrouted connections and 0 errors in each (`par.par`). The worst path at N=8
is the trigger sequencer's occurrence counter (`u_csr/seq_cnt_q` → `u_trigger/occ_reg` clock
enable, 25 logic levels through the carry chain).

**Caveat — I/O paths are not constrained.** `scope.sdc` holds only the clock, so the slack and
Fmax above cover register-to-register (and RAM) paths. Constraint coverage is 85.4%, 86.1% and
88.4%; the uncovered remainder is pin-to-register and register-to-pin paths (at N=8: 33
unconstrained start points, 1,294 unconstrained end points). That includes the combinational
AXI paths through `scope_axil` — e.g. `s_axi_araddr` → CSR read mux → `rdata_q`. I left them
unconstrained rather than invent pad delays for a block that is not meant to sit on pins; when
it is embedded behind a registered master those become ordinary internal paths and must be
re-timed there.

### Warnings

| Stage | (32, 8) | (32, 12) | (32, 15) |
|---|---|---|---|
| Synplify errors (`@E`) | 0 | 0 | 0 |
| Synplify warnings (`@W`) | 11 | 13 | 16 |
| Synplify notes (`@N`) | 319 | 316 | 321 |
| Map warnings / errors | 28 / 0 | 28 / 0 | 28 / 0 |
| PAR warnings / errors | 14 / 0 | 14 / 0 | 14 / 0 |

Synplify warnings by ID, and what I make of them:

| ID | Count (N=8 / 12 / 15) | Item | Assessment |
|---|---|---|---|
| CL246 | 6 / 6 / 6 | unused input bits: `awaddr[1:0]`, `araddr[1:0]` in `scope_axil`; four 3-bit reserved fields of `trig_combine` in `scope_trigger` | By design (word-aligned addresses, reserved CSR bits). Benign. |
| FX107 | 2 / 2 / 2 | `u_buf` and `u_win_meta` RAMs have no read/write conflict check | **The one worth reading — see below.** |
| BN132 | 0 / 3 / 6 | duplicate `u_core.slice_mask[i]` registers merged | Normal optimisation; count grows with `DEPTH_LOG2`. Benign. |
| CL260 | 1 / 0 / 0 | `weff_log2_q[3]` pruned in `scope_core` | Constant bit at N=8. Benign. |
| BW295 | 1 / 1 / 1 | clock forward-annotation to input pins not allowed | Tool note about its own `.ldc`; the clock is constrained (see timing). Benign. |
| FX310 | 1 / 1 / 1 | `-dcc_insertion` ignored, technology has no DCC | Tool default option. Benign. |

Map's 28 warnings are a single message, `<71003020> Top module port '…' does not connect to
anything`, for 14 ports each reported twice: `s_axi_awaddr[1:0]`, `s_axi_araddr[1:0]`,
`s_axi_awprot[2:0]`, `s_axi_arprot[2:0]`, `s_axi_wstrb[3:0]`. PAR repeats the same 14 once.
These are the AXI signals the adapter deliberately ignores; expected.

**FX107 (read/write conflict).** `prim_ram_1r1w` promises *old data* when the same address is
read and written in one cycle. Synplify maps it to an EBR without adding bypass logic and warns
that the hardware may not honour that policy on a collision. I did not add the `rw_check`
bypass, and I have not verified the EBR's collision behaviour on hardware or in gate-level
simulation — so treat the following as reasoning, not proof. In this `XPORT="CSR"` build the
only two RAMs are `u_buf` and `u_win_meta`, both read with `rd_en` tied high. `u_buf` is only
meaningfully read by the BUF_DATA drain after capture has stopped writing, and the output
register refreshes every cycle, so a collision during capture is overwritten before it can be
consumed. `u_win_meta` collides only if the host has `WIN_SEL` pointing at the window that is
completing in that exact cycle and samples it one cycle later. So I expect no functional
impact here, but the `XPORT="UART"`/`"STREAM"` builds use `prim_fifo_sync` on the same
primitive and were **not** built or analysed in this port; anyone porting those should
re-check this warning (or set `syn_ramstyle = "rw_check"`).

### Questa regression (`sim/questa_<tb>.log`)

All 17 testbenches print `TB_RESULT: PASS` with `Errors: 0, Warnings: 0` from both `vlog` and
`vsim`: the required `tb_smoke`, `tb_csr`, `tb_csr_if`, the other 13 that `sim/run.sh` runs
(`tb_prim_ram`, `tb_prim_fifo_sync`, `tb_prim_fifo_async`, `tb_capture_basic`,
`tb_trigger_cmp`, `tb_trigger_seq`, `tb_pretrig`, `tb_windows`, `tb_drain_cdc`, `tb_uart`,
`tb_rle`, `tb_ext_trig`, `tb_jtag`), and one new one, `sim/tb_axil_top.sv`, which drives
`scope_axil_top` itself over AXI4-Lite: ID, CSR read-back, arm → `armed` pin, force-trigger →
`triggered` pin, then a 256-word BUF_DATA drain checked against the probe counter.

`tb_cosim` is not run (DPI-C + Python harness, also outside `run.sh`). Verilator is not
installed on this machine, so `sim/run.sh` was **not** re-run after the edits below; they are
declaration reorders only, but that is unverified under Verilator.

## Source changes

Questa enforces IEEE 1800 declaration-before-use; Verilator and Synplify accepted
the originals. Each fix moves an existing declaration above its first use — no logic, name or
width changed.

| File | Moved up |
|---|---|
| `rtl/scope_top.sv` | `dec_tick`, `qual_hit`, `sample_en`, `trig_fire` wires, above the `always_ff` that reads `sample_en` |
| `sim/tb_csr.sv` | `win_rd_addr`, `win_rd_data` |
| `sim/tb_csr_if.sv` | `rd`, `id_val`, `hwcfg_val` |
| `sim/tb_trigger_seq.sv` | `unused_win_meta` |
| `sim/tb_uart.sv`, `sim/tb_drain_cdc.sv` | `unused_ext_rdata` |

`rtl/scope_top.sv` is the only RTL change and it is vendor-neutral. No Lattice primitives,
attributes or pragmas were added anywhere; block-RAM inference needed no help. The reports
here were generated after that change.

Also added: `.gitattributes` (keeps `sim/run_questa.sh` LF under `core.autocrlf`) and
`.gitignore` exemptions so the reports and Questa logs can be checked in.
