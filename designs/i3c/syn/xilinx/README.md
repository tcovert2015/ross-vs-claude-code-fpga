# AMD/Xilinx Synthesis & Timing (Vivado)

The device-agnostic RTL builds for a real AMD device; the only vendor-specific file is
`rtl/xilinx/i3c_io_xilinx.sv` (SDA/SCL pad cells), selected with the
`I3C_IO_CELL=i3c_io_xilinx` define.

## Build
Non-project batch flow, out-of-context (the core is an IP, not a pinned top):
```
vivado -mode batch -source syn/xilinx/build.tcl -log syn/xilinx/reports/vivado.log
```
(here: `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`). The script `cd`s to its own
directory and uses relative paths only, because several Vivado commands mis-parse absolute
paths containing spaces. Stages, in order: RTL lint (`synth_design -lint`) → synthesis
(`-mode out_of_context`) → `opt_design` / `place_design` / `phys_opt_design` /
`route_design` → reports.

Files: `build.tcl` (flow), `i3c_target.xdc` (timing; XDC translation of
`syn/altera/i3c_target.sdc`). Part **`xc7a100tcsg324-1`**, top `i3c_target_top`, `clk` =
8.000 ns (125 MHz). Checkpoints go to `syn/xilinx/build/` (ignored); evidence is committed
under `syn/xilinx/reports/`:

| File | Content |
|---|---|
| `vivado.log` | full console log of the run the numbers below come from |
| `lint.rpt` | RTL linter report |
| `utilization.rpt`, `utilization_hier.rpt` | post-route utilization (`utilization_synth.rpt`: post-synthesis) |
| `timing_summary.rpt` | post-route timing summary incl. `check_timing` |
| `timing_split.txt` | worst setup/hold slack per path class |
| `drc.rpt`, `methodology.rpt`, `route_status.rpt` | DRC, methodology checks, routing status |
| `trial_inferred_tristate/` | log + netlist probe of the rejected inferred-tri-state shim (see below) |

### Simulation (xsim)
```
powershell -ExecutionPolicy Bypass -File sim/run_xsim.ps1
```
Compiles the same file list as `sim/run.sh` with `rtl/xilinx/i3c_io_xilinx.sv` in place of
the Altera shim (plus `glbl` and `-L unisims_ver` for the `IOBUF`/`IBUF` models) and runs
`tb_i3c_target`. Result in `sim/xsim.log`: **29 passed, 0 failed**, no xvlog/xelab/xsim
warnings or errors.

## Results (Vivado 2025.2, Artix-7 `xc7a100tcsg324-1`, out-of-context)
| Stage | Result |
|---|---|
| RTL lint | 0 errors, 0 critical warnings, **52 warnings** |
| Synthesis | **0 errors, 0 critical warnings**, 55 warnings |
| Place & route | **0 errors**; 748 of 748 routable nets fully routed, 0 routing errors |
| Resources (post-route) | **496 LUTs** (480 logic + 16 distributed RAM), **341 FFs**, **0 BRAM**, 0 DSP, **2 bonded IOBs** (SDA, SCL), 158 slices |
| xsim regression | 29 / 29 PASS |

The two FIFOs map to distributed RAM (16 LUTs), not block RAM, at the default depths.
Only SDA and SCL are pads; every other port is an out-of-context boundary pin.
Largest blocks (`utilization_hier.rpt`): `u_ccc` 107 LUTs / 37 FFs, `u_av` 92 / 74,
`u_fe` 55 / 34, `u_rf` 27 / 54.

### Timing — read this carefully
Whole design, from `timing_summary.rpt`:

| Metric @ 8.000 ns | Value |
|---|---|
| WNS (setup) | **+1.147 ns**, TNS 0.000 ns, 0 of 865 endpoints failing |
| WHS (hold) | **−0.202 ns**, THS −2.276 ns, **42 of 865 endpoints failing** |
| WPWS (pulse width) | +2.750 ns |

Vivado's verdict is therefore "Timing constraints are not met". Split by path class
(`timing_split.txt`):

| Path class | Setup slack | Hold slack | Verdict |
|---|---|---|---|
| **Register → register** (the actual logic) | **+1.147 ns** | **+0.079 ns** | **MET** |
| Input port → register | +1.251 ns | **−0.202 ns** | setup met, hold **not met** standalone |
| Register → output port | +2.448 ns | +1.226 ns | MET |
| Input port → output port (`avs_waitrequest`) | +2.711 ns | +1.907 ns | MET |

**Setup closes everywhere at 125 MHz and the internal logic meets both setup and hold.**
All 42 hold violations are launched from an Avalon-MM *input port* (`timing_split.txt`
counts 42 of 42); none is register-to-register.

Why the port hold paths fail, and why it is an out-of-context artifact rather than a
design flaw:
- The IP has no clock buffer, so `clk` is analysed as entering at the port with an
  estimated net delay to each flop (0.973 ns on the worst path). The Avalon inputs carry
  the same 0.3 ns placeholder `set_input_delay -min` as the Altera SDC, referenced to the
  clock *at the port*. The data net is a 0.924 ns boundary stub, so data arrives at 1.224 ns
  against a 1.426 ns requirement. In a real system the launching register is on the same
  clock tree, so that 0.973 ns is common to both ends instead of being pure skew.
- The router cannot repair it here: boundary pins have no routing to detour (`vivado.log`:
  `Route 35-426 … unable to fix hold violation on … partition pins`). In-context it can.
- Unlike the Altera standalone build, `avs_waitrequest` **does** close (+2.711 ns): the
  out-of-context ports have no pad buffers, which is exactly the on-chip situation the
  Altera README describes.

Caveats on the numbers: without a clock source (`HD.CLK_SRC`) and pin locations
(`HD.PARTPIN_LOCS`) Vivado estimates clock skew and boundary-net delays (`Timing 38-242`,
`Route 35-197`, `Route 35-198` in `vivado.log`), so port-path slacks and the small
register-to-register hold margin are estimates until the core is placed in a real design.
Setting `HD.CLK_SRC` was tried and did not change that; it only enlarged the port-hold
artifact, so it is left out.

### Constraints (`i3c_target.xdc`)
Same intent as the Altera SDC: `create_clock` 8.000 ns on `clk`; SDA/SCL pads and `rst_n` /
`avl_rst_n` cut with `set_false_path` (closed by the synchronizers, not STA); Avalon-MM
inputs/outputs given 1.0 ns max / 0.3 ns min placeholder delays. `check_timing` reports no
unconstrained endpoints; its only entries are the ports that are deliberately false-pathed
(`SCL`, `SDA`, `rst_n` as inputs, `SDA` as output). `derive_clock_uncertainty` has no XDC
equivalent and is dropped.

### DRC / methodology
`report_methodology`: 0 violations. `report_drc`: 0 errors, 2 critical warnings,
2 warnings, all consequences of building an unpinned IP:

| Rule | Severity | Assessment |
|---|---|---|
| NSTD-1 | Critical Warning | SDA/SCL have no `IOSTANDARD` — board decision, not set here |
| UCIO-1 | Critical Warning | SDA/SCL have no pin `LOC` — board decision |
| CFGBVS-1 | Warning | no `CFGBVS`/`CONFIG_VOLTAGE` — board decision |
| RTSTAT-10 | Warning | 26 output boundary nets (`avs_readdata[23:0]`, `avs_readdatavalid`, `irq`) have no load out of context |

## Lint findings (`lint.rpt`)
52 violations, all severity WARNING, none waived; no errors or critical warnings.

| Rule | Count | Meaning |
|---|---|---|
| ASSIGN-10 | 32 | module input (or some of its bits) never read |
| ASSIGN-6 | 20 | signal assigned but never read |

None is a functional bug in what the RTL implements, and none needed an RTL change. Sorted
by how much attention they deserve:

**Worth a look — register bits / status with no consumer (real, but feature gaps, not
port problems):**
- `av_static_addr_en` (CTRL[4]) and `av_prn_send_en` (CTRL[5]) in `i3c_target_top`, and
  `mdb_is_prn` (IBI_CTRL[15]) into `i3c_ibi`: documented, writable register bits that drive
  nothing. Software can set them with no effect.
- `txf_overflow`: the TX FIFO overflow flag is left unconnected, while the RX one is routed
  to the Avalon block.
- `trp_trigger` into `i3c_regfile`: read only by a formal `cover`; the reset itself is
  applied through `rg_whole_reset` / `rg_periph_reset` in the top.

**Benign — formal/observability taps:** the other top-level ASSIGN-6 nets (`ccc_code`,
`ccc_is_direct`, `daa_arb_lost`, `fr_parity_ok`, `fr_t_drive_val`, `hdr_trp_body_valid`,
`ibi_active`, `ibi_addr`, `pf_*`, `rf_last_reset_was_whole`, `rxf_wr_level`,
`txf_rd_level`) and `hdr_open` in `i3c_ccc` are outputs kept for the `` `ifdef FORMAL ``
properties. Synthesis removes the matching flops for the same reason (5 distinct
`Synth 8-6014` registers: `m7e_q`, `mda_q`, `is_mdb`, `mdb_en`, `outstanding`).

**Benign — uniform module interfaces:** most ASSIGN-10 items are strobes a block is handed
but does not need (`scl_rising`/`scl_falling`/`start_stb`/`bit_cnt` into `i3c_ccc`,
`i3c_daa`, `i3c_error_recovery`, `i3c_protocol_fsm`), partially used buses (`bcr` in
`i3c_ibi`, `app_wr_data[31:24]` / `app_wr_be[3]` in `i3c_regfile`, `pl_sel[6]` in
`i3c_daa`), and `clk`/`rst_n` on the purely combinational `i3c_sda_mux`.

**Benign — single-clock configuration:** `avl_clk` / `avl_rst_n` on the top and `rd_clk` /
`rd_rst_n` on `i3c_fifo` are only used when `AVL_ASYNC=1`.

The 55 synthesis warnings in `vivado.log` are the same unused ports restated per bit
(`Synth 8-7129`).

## RTL changes
One change to core RTL, vendor-neutral and behaviour-preserving by default:

- **`rtl/i3c_target_top.sv`** instantiated `i3c_io_altera` by name. The pad cell is now
  `` `I3C_IO_CELL ``, defaulting to `i3c_io_altera` when the macro is undefined, so the
  Quartus and Icarus flows are untouched and the Vivado/xsim flows pass
  `I3C_IO_CELL=i3c_io_xilinx`. Justification: without it a second vendor shim cannot be
  selected at all, short of naming the Xilinx module `i3c_io_altera`.

New vendor file **`rtl/xilinx/i3c_io_xilinx.sv`**: same ports and drive semantics as the
Altera shim, implemented with an instantiated `IOBUF` (SDA, `T = ~sda_oe`) and `IBUF` (SCL).
An inferred tri-state was tried first and rejected on evidence
(`reports/trial_inferred_tristate/`): out of context Vivado has no pad buffer to absorb the
`1'bz` and converts it to logic (`CRITICAL WARNING Synth 8-5799`). The probe of that netlist
shows SDA driven by a `LUT2` with `INIT=4'h8` (`sda_o & sda_oe`), that same net feeding the
SDA synchronizer, and zero tri-state cells — a Target that can neither release the bus nor
hear the Controller, with timing still "passing". The instantiated primitives survive
synthesis (1 `IOBUF`, 1 `IBUF` in the synthesis cell report; `OBUFT` + 2 `IBUF` post-route).

## Notes / next steps for a real board
- Add `PACKAGE_PIN` and `IOSTANDARD` for SDA/SCL (and `CFGBVS` / `CONFIG_VOLTAGE`); that
  clears NSTD-1 / UCIO-1 / CFGBVS-1.
- A parent design that black-boxes the out-of-context netlist must treat SDA/SCL as pad
  pins (`black_box_pad_pin`, or `IO_BUFFER_TYPE none` on its own ports) so they are not
  buffered twice. Synthesizing the RTL in-context needs nothing special.
- Replace the placeholder Avalon I/O delays with the real interconnect budget; in-context
  the port-hold artifact above disappears.
- Not verified here: the Icarus flow (`sim/run.sh`) could not be re-run on this machine —
  the installed Icarus 11.0 stops with a syntax error in the unmodified `rtl/i3c_pkg.sv`.
  The default (Altera-shim) configuration of the edited top was instead compiled and run
  once under xsim as a scratch check and passed; that log is not committed.
