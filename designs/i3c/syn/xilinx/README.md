# AMD Synthesis & Timing (Vivado 2025.2, Artix-7)

The device-agnostic RTL builds for an AMD 7-series device; the only vendor-specific
file is `rtl/xilinx/i3c_io_xilinx.sv` (SDA `IOBUF` + SCL `IBUF`). The build is
**out-of-context** (`synth_design -mode out_of_context`): this is an IP core, not a
pinned top.

## Build
```
vivado -mode batch -source syn/xilinx/build.tcl     # lint -> synth -> opt/place/route -> reports
vivado -mode batch -source sim/run_xsim.tcl         # xsim regression -> sim/xsim.log
```
Both scripts locate the design root from their own path, so they run from any directory
(or `source` them in an open Vivado Tcl session — that is how the committed results were
produced). Files: `build.tcl` (non-project flow), `i3c_target.xdc` (timing). Part
**`xc7a100tcsg324-1`**, top `i3c_target_top`, `clk` = 8.0 ns (125 MHz). Reports go to
`syn/xilinx/reports/`, checkpoints to `syn/xilinx/build/` (not committed).

`reports/lint.csv` is `reports/lint.rpt` converted by the Ross `vivado-rtl-lint` skill's
`parse_lint_report.py`; it is not produced by `build.tcl`.

## Results (Vivado 2025.2, `xc7a100tcsg324-1`, out-of-context)
| Stage | Result | Source |
|---|---|---|
| RTL lint (`synth_design -lint`) | **52 messages: 0 critical warning, 52 warning, 0 info** | `reports/lint.rpt` |
| Synthesis / opt / place / route | completed; **749 of 749 routable nets fully routed, 0 routing errors** | `reports/route_status.rpt` |
| Resources (post-route) | **497 LUTs** (481 logic + 16 distributed RAM), **341 FFs**, **0 BRAM**, 0 DSP, **2 bonded IOBs** (SDA, SCL) | `reports/utilization.rpt` |
| Setup @ 8.0 ns | **WNS +0.969 ns, TNS 0.000 ns** (0 failing endpoints of 1039) — **MET** | `reports/timing_summary.rpt` |
| Hold | **WHS −0.984 ns, THS −86.448 ns, 115 failing endpoints** — see below | `reports/timing_summary.rpt` |
| DRC | 3 checks: 1 critical warning (UCIO-1), 2 warnings (CFGBVS-1, RTSTAT-10) | `reports/drc.rpt` |
| Timing methodology (`report_methodology`) | 0 checks found | `reports/methodology.rpt` |
| xsim regression (`tb_i3c_target`) | **29 passed, 0 failed** | `sim/xsim.log` |

The two FIFOs (8×11 and 8×9) map to distributed RAM, so BRAM is 0 (Quartus used 2 RAM
blocks). Only SDA and SCL are IOBs because OOC synthesis does not buffer the other ports.

### Timing — read this carefully

Worst slack by path class (`reports/timing_split.rpt`, written by `build.tcl`):

| Path class | Setup slack | Hold slack | Verdict |
|---|---|---|---|
| **Register → register** (the actual logic) | **+0.969 ns** | **+0.069 ns** | **MET** |
| Input port → register | +1.886 ns | **−0.984 ns** | setup met; hold **violated** on 115 endpoints |
| Register → output port | +1.298 ns | +1.452 ns | MET |
| Input port → output port (`avs_waitrequest`) | +3.054 ns | +1.720 ns | MET |

**The design does not report clean hold timing as constrained.** All 115 failing hold
endpoints are input-port → register paths; register-to-register hold has 0 failures.

My assessment is that this is a constraint-modelling artifact of the OOC build, not a
logic problem, but it is an assessment, not something the reports prove:

- The XDC copies the Altera SDC's `set_input_delay -min 0.3`, referenced to the `clk`
  *port*. In the worst path (detail at the end of `timing_split.rpt`) the data arrives
  0.300 ns (input delay) + 0.924 ns (net) after the clock edge at the port, while the
  capturing flop's clock arrives 1.816 ns after it (estimated clock-network delay, source
  clock delay 0.000 ns). The 0.3 ns budget therefore assumes a launching register with
  *no* clock insertion delay.
- In a real system the Avalon master's flops sit on the same global clock network as this
  core, so launch and capture see similar insertion delay, and the router fixes any
  residual hold on the real flop-to-flop nets. In OOC the port nets have no physical
  source, so `route_design` cannot add hold delay to them.

To get a hold number worth signing off, either implement the core inside its parent
design, or replace the placeholder `-min` input delays with values that include the
master's clock insertion delay. I did not tune the budget to make the number go away.

Unlike the Altera standalone build, `avs_waitrequest` closes here (+3.054 ns): with no
pad buffers on the Avalon ports the combinational path is short, which is what the
Altera README predicted for on-chip use.

`check_timing` (in `timing_summary.rpt`) reports no unclocked registers and no
unconstrained internal endpoints; the only entries are the 2 input ports and 1 output
port that are deliberately false-pathed (SCL, SDA).

### Constraints (`i3c_target.xdc`)
Mirrors `syn/altera/i3c_target.sdc`: `create_clock` 8.000 ns on `clk`, false paths on the
asynchronous SDA/SCL pads, and the same 1.0 / 0.3 ns Avalon I/O delay placeholders.
Differences:

- **`rst_n` is timed, not false-pathed.** Every flop uses `rst_n` as a *synchronous*
  reset (`always_ff @(posedge clk) if (!rst_n)`), so it is a normal clk-domain input; it
  gets the same input delays as the Avalon inputs. The Altera SDC cuts it.
- **`HD.CLK_SRC BUFGCTRL_X0Y0` on `clk`**, so the timer models the clock as arriving
  from a global buffer in the parent. From amd-doc-search → UG905 *Hierarchical Design*,
  "I/O and Clock Buffers": when an OOC clock port is driven from the top level, "the
  HD.CLK_SRC constraint should be used to help improve timing estimations".
- `derive_clock_uncertainty` is Quartus-only and is dropped.
- `IOSTANDARD LVCMOS18` on SDA/SCL as a placeholder; no pin LOCs (IP-level build).

### DRC (`reports/drc.rpt`)
- **UCIO-1 (critical warning)** — SDA and SCL have no pin LOC. Expected for an IP-level
  build; the board XDC must assign them before a bitstream.
- **CFGBVS-1 (warning)** — CFGBVS/CONFIG_VOLTAGE not set. Board-level property.
- **RTSTAT-10 (warning)** — 26 nets with no routable loads (`avs_readdata[23:0]`,
  `avs_readdatavalid`, `irq`): flop outputs that go straight to OOC ports, which have no
  physical load. Expected in OOC.

## IO shim: why `IOBUF`/`IBUF` rather than an inferred tri-state
OOC synthesis does not insert I/O buffers on top-level ports, so an inferred
`assign SDA = oe ? o : 1'bz` would only become a pad buffer if the parent happened to
route the port straight to a pin. SDA and SCL are always device pads, so the buffers are
instantiated in `i3c_io_xilinx.sv` and travel with the IP. This follows the UG905 passage
returned by amd-doc-search ("If an OOC port connects directly to an I/O buffer in the top
level, it is recommended to move this buffer inside the OOC module"). `IOBUF.T` is
active-high, so `T = ~sda_oe`. Consequence: simulation needs `-L unisims_ver` and `glbl`
(handled in `sim/run_xsim.tcl`). I did not build the inferred variant for comparison.

## Lint findings (`reports/lint.rpt`, 52 warnings)
| Rule | Severity | Count | Meaning |
|---|---|---|---|
| ASSIGN-10 | Warning | 32 | module input (or some of its bits) never read |
| ASSIGN-6 | Warning | 20 | signal assigned but never read |

By file: `i3c_target_top.sv` 20, `i3c_error_recovery.sv` 7, `i3c_ccc.sv` 6,
`i3c_protocol_fsm.sv` 5, `i3c_daa.sv` 4, `i3c_regfile.sv` 3, `i3c_sda_mux.sv` 2,
`i3c_ibi.sv` 2, `i3c_fifo.sv` 2, `i3c_avalon_mm.sv` 1. No latches, multi-driver,
width-truncation or incomplete-case rules fired. Nothing here blocks synthesis.

Items I consider **real** (dead plumbing with a user-visible effect; not fixed — out of
scope for a port):
- `av_static_addr_en`, `av_prn_send_en` (top) — CTRL[4] and CTRL[5] are writable register
  bits that drive nothing. Static-address support is controlled only by the
  `STATIC_ADDR_EN` parameter.
- `mdb_is_prn` (`i3c_ibi`) — the Pending-Read-Notification flag from the application is
  never used by the IBI engine outside `FORMAL` covers.
- `txf_overflow` (top) — TX FIFO overflow is never reported to the application
  (`rx_overflow` is).
- `bus_idle` (`i3c_avalon_mm`) — passed in but not exposed in any status field.
- `avl_clk`, `avl_rst_n` (top) and `rd_clk`, `rd_rst_n` (`i3c_fifo`) — correct for the
  default `AVL_ASYNC=0`, but worth knowing: the top hard-wires both FIFOs to `ASYNC=0`
  and `i3c_fifo` documents the async variant as not implemented, so **`AVL_ASYNC=1`
  would clock the Avalon bridge from `avl_clk` across single-clock FIFOs with no CDC**.

Items I consider **benign**:
- Unused strobes/fields on module interfaces that follow the frozen connectivity map
  (`scl_rising`/`scl_falling`/`bit_cnt`/`start_stb`/`match_7e`/… in `i3c_ccc`,
  `i3c_daa`, `i3c_error_recovery`, `i3c_protocol_fsm`; `bcr` bits in `i3c_ibi`;
  `app_wr_data[31:24]`, `app_wr_be[3]`, `trp_trigger` in `i3c_regfile`).
- Debug/status outputs left unconnected at the top (`ccc_code`, `ccc_is_direct`,
  `pf_state_idle`, `pf_state_ignore`, `pf_to_ccc`, `ibi_active`, `ibi_addr`,
  `fr_parity_ok`, `fr_t_drive_val`, `hdr_trp_body_valid`, `daa_arb_lost`,
  `pf_addr_capture_armed`, `rf_last_reset_was_whole`, `rxf_wr_level`, `txf_rd_level`).
- `hdr_open` (`i3c_ccc`) is used only under `FORMAL`; `pl_sel[6]` (`i3c_daa`) is an
  index wider than the 64-bit word it selects from; `clk`/`rst_n` on the purely
  combinational `i3c_sda_mux`.

## RTL changes
One change to core RTL, vendor-neutral:

- **`rtl/i3c_target_top.sv`** — the IO wrapper instance was hard-coded as
  `i3c_io_altera u_io (...)`. It is now `` `I3C_IO_CELL u_io (...) `` with
  `` `define I3C_IO_CELL i3c_io_altera `` as the default when the macro is not set.
  Vivado and xsim pass `I3C_IO_CELL=i3c_io_xilinx`. Without this, the Xilinx shim could
  only be used by naming it `i3c_io_altera`. Existing flows need no change: with the
  original `sim/run.sh` file list and no define, xsim elaborates `i3c_io_altera` and the
  testbench reports 29 passed, 0 failed (`sim/xsim_altera_io.log`, produced by
  `I3C_SIM_IO=altera` + `sim/run_xsim.tcl`).

No other RTL was touched. The `(* ramstyle = "MLAB, no_rw_check" *)` attribute in
`i3c_fifo.sv` is Quartus-specific and left as is.

**Not re-run:** the Icarus regression (`sim/run.sh`) and the Quartus build. On this
machine Icarus 11.0 stops with a syntax error at `rtl/i3c_pkg.sv:89`, a file this port
does not modify, so the Icarus flow could not be used to confirm the change; the xsim
cross-check above stands in for it.

## Notes / next steps for a real board
- Add `PACKAGE_PIN` for SDA/SCL, the real `IOSTANDARD`, and CFGBVS/CONFIG_VOLTAGE.
- An open-drain bus needs an external pull-up (or `PULLUP` on the SDA pad); pick
  `DRIVE`/`SLEW` for the push-pull phases.
- Replace the placeholder Avalon I/O delays with the real master's numbers, or drop them
  and time the core in its parent design.
