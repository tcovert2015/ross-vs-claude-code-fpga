# AMD Synthesis & Timing (Vivado, Artix-7)

The device-agnostic RTL builds for an AMD 7-series device; the only vendor-specific
file is `rtl/xilinx/i3c_io_xilinx.sv` (SDA `IOBUF`), selected at compile time with
`I3C_IO_MODULE=i3c_io_xilinx` (see "RTL changes").

## Build
Non-project batch flow, out-of-context (the core is an IP, not a pinned top):
```
vivado -mode batch -source syn/xilinx/build.tcl     # lint -> synth -> opt/place/route -> reports
powershell -ExecutionPolicy Bypass -File sim\run_xsim.ps1   # xsim regression -> sim/xsim.log
```
Files: `build.tcl` (flow), `i3c_target.xdc` (timing, port of `syn/altera/i3c_target.sdc`).
Part **`xc7a100tcsg324-1`**, top `i3c_target_top`, `clk` = 8.000 ns (125 MHz).
Toolchain: `C:\AMDDesignTools\2025.2\Vivado`. Reports land in `reports/` (committed);
checkpoints and logs in `build/` (ignored).

`build.tcl` uses relative paths on purpose: in Vivado 2025.2, `synth_design -lint -file`
with a path containing a space writes no report and leaves lint mode switched on for the
next `synth_design` (which then produces black-box RAMs and fails `opt_design`).

## Results (Vivado 2025.2, `xc7a100tcsg324-1`, out-of-context)
| Stage | Result | Evidence |
|---|---|---|
| RTL lint (`synth_design -lint`) | **0 errors, 0 critical warnings, 52 warnings, 0 info** | `reports/lint.rpt` |
| Synthesis | **0 errors** | `reports/utilization_synth.rpt` |
| Place & route | **0 errors**, 744/744 routable nets routed, 0 routing errors | `reports/route_status.rpt` |
| DRC | 2 critical warnings + 2 warnings, all expected for an unpinned OOC build (below) | `reports/drc.rpt` |
| xsim regression | **29 passed, 0 failed** | `sim/xsim.log` |

### Utilization (post-route, `reports/utilization.rpt`)
| Resource | Used | Available | Util |
|---|---|---|---|
| Slice LUTs | **496** (480 logic + 16 distributed RAM) | 63400 | 0.78% |
| Slice registers (FFs) | **341** (0 latches) | 126800 | 0.27% |
| Block RAM tiles | **0** | 135 | 0.00% |
| DSPs | 0 | 240 | 0.00% |
| Bonded IOB | **1** (SDA: `IBUF` + `OBUFT`) | 210 | 0.48% |
| Slices | 162 | 15850 | 1.02% |

Post-synthesis estimate was 502 LUTs / 341 FFs. The two depth-8 FIFOs map to distributed
RAM (the 2 RAM blocks in the Altera build), hence 0 BRAM. Only SDA is a bonded IOB: in an
out-of-context build the other 83 port bits are module-boundary pins, not pads.

### Timing — read this carefully

Overall numbers from `reports/timing_summary.rpt` (865 endpoints):

| | Value | |
|---|---|---|
| **WNS** (setup) | **+0.786 ns** | MET |
| **TNS** | **0.000 ns** (0 failing endpoints) | MET |
| **WHS** (hold) | **−0.984 ns** | **NOT met** — 93 failing endpoints, THS −73.811 ns |
| WPWS (pulse width) | +2.750 ns | MET |

Vivado's verdict is "Timing constraints are not met", because of hold. Split by path class
(`reports/timing_split.rpt`, post-route worst slack in ns):

| Path class | Setup | Hold | Verdict |
|---|---|---|---|
| **Register-to-register** (the actual logic) | **+0.786** | **+0.070** | **MET** |
| Avalon input port → register | +1.721 | **−0.984** | hold not met standalone (see below) |
| Register → Avalon output port | +1.742 | +1.439 | MET |
| Port → port (`avs_waitrequest`) | +2.834 | +1.811 | MET |

**The internal logic meets 125 MHz for setup and hold.** The worst setup path is
`u_be/rx_byte_reg[6]` → `u_be/tx_shift_reg[2]/CE`, 6 logic levels, 6.888 ns data path.

Every hold failure is an Avalon **input port → first register** path, and I assess it as an
out-of-context modeling artifact rather than a design flaw:

- The XDC gives the Avalon inputs the Altera SDC's placeholder budget
  (`set_input_delay -min 0.3`), i.e. data changes 0.3 ns after an *ideal, zero-latency*
  clock edge at the port.
- The capture register, however, sees the real routed clock tree (`HD.CLK_SRC` puts a
  global buffer in front of `clk`; 1.816 ns of clock path skew against the port on the worst path).
- The port nets themselves are unrouted in OOC (no `HD.PARTPIN_LOCS`), so their delay is an estimate
  (0.924 ns on the worst path) and the router cannot add hold-fix detours to them.

In a real system the Avalon master's launch flop sits on the same clock tree, so launch
and capture latency cancel and the path is an ordinary reg-to-reg path (hold +0.070 ns
class). **This has not been demonstrated here** — it needs an in-context build with the
real interconnect. Without `HD.CLK_SRC` the same build reported WHS −0.141 ns on the same
path class (clock delay only estimated); I kept `HD.CLK_SRC` because it makes the
reg-to-reg numbers trustworthy, at the price of a larger port-hold number. I did not tune
the I/O budgets to make the summary go green.

Unlike the Altera standalone build, `avs_waitrequest` closes here (+2.834 ns): in OOC
there are no pad buffers on the Avalon ports, which is exactly the on-chip situation the
Altera README describes.

`check_timing`: 0 unclocked registers, 0 unconstrained internal endpoints, 0 ports missing
I/O delay; 3 inputs and 1 output are covered by false paths only (`SCL`, `SDA`, `rst_n` /
`SDA`), by design.

### Constraints (`i3c_target.xdc`)
Same content as the SDC: `create_clock` 8.000 ns on `clk`; async `SDA`/`SCL` pads and
`rst_n` cut with `set_false_path` (metastability closed by the synchronizers, not STA);
Avalon-MM I/O given the same placeholder 1.0 / 0.3 ns `set_input_delay`/`set_output_delay`.
Differences: `derive_clock_uncertainty` dropped (Quartus-only); `avl_rst_n` is not
constrained (no loads in the default `AVL_ASYNC=0` build); `HD.CLK_SRC` added for OOC
clock modeling.

### Lint findings (`reports/lint.rpt`)
52 messages, all severity WARNING, two rules, both "signal/port bit is never read":

| Rule | Severity | Count | Meaning |
|---|---|---|---|
| ASSIGN-10 | WARNING | 32 | input port (bits) not read inside the module |
| ASSIGN-6 | WARNING | 20 | internal signal (bits) assigned but not read |

By module: `i3c_target_top` 20, `i3c_error_recovery` 7, `i3c_ccc` 6, `i3c_protocol_fsm` 5,
`i3c_daa` 4, `i3c_regfile` 3, `i3c_sda_mux` 2, `i3c_ibi` 2, `i3c_fifo` 2, `i3c_avalon_mm` 1.
No latch, multi-driver, width, incomplete-case or reset findings were reported.

My assessment (none of these changes synthesized behavior; nothing was "fixed" in RTL):

**Worth a look by the RTL owners (possible functional gaps, not Vivado issues):**
- `txf_overflow` (`i3c_target_top.sv:193`) — the TX FIFO's sticky overflow flag is
  connected to nothing, so an application push into a full TX FIFO is not reported.
- `daa_arb_lost` (`:131`), `fr_parity_ok` / `fr_t_drive_val` (`:115`),
  `rf_last_reset_was_whole` (`:172`), `hdr_trp_body_valid` (`:161`), `ibi_addr` (`:153`),
  `av_static_addr_en` / `av_prn_send_en` (`:187`) — status/config outputs produced by a
  block and dropped at the top. `av_static_addr_en` and `av_prn_send_en` are
  application-writable controls with no effect; the others are unused status.
- `mdb_is_prn` and `bcr` bits in `i3c_ibi` (`:67`, `:61`), `is_broadcast` in `i3c_ccc`
  (`:50`) — inputs wired in but not used by the logic.

**Benign / by design:**
- `avl_clk`, `avl_rst_n` (top) and `rd_clk`, `rd_rst_n` (`i3c_fifo`) — only used when
  `AVL_ASYNC=1`; the default build is single-clock.
- `clk`, `rst_n` on `i3c_sda_mux` — the mux is purely combinational outside `FORMAL`.
- `scl_rising` / `scl_falling` / `start_stb` / `bit_cnt` / `ack_slot` / `tbit_slot` /
  `bus_available` / `bus_idle` / `match_7e` / `match_da` / `is_read` / `ccc_supported` /
  `trp_trigger` ports and `hdr_open` (`i3c_ccc.sv:114`) — common bus-event inputs that a
  given block does not need, or that are read only by `` `ifdef FORMAL `` properties.
- `app_wr_data` from bit 24 and `app_wr_be[3]` (`i3c_regfile`) — no writable register
  field in the top byte.
- `pl_sel` bit 6 (`i3c_daa.sv:89`) — a 7-bit index into a 64-bit word; the MSB is unused.
- `pf_state_idle`, `pf_state_ignore`, `pf_addr_capture_armed`, `pf_to_ccc`, `ccc_code`,
  `ccc_is_direct`, `ibi_active`, `rxf_wr_level`, `txf_rd_level` — debug/observation taps.

Synthesis agrees with the lint picture: 55 "port unconnected or has no load" and 10
"unused sequential element removed" warnings in the build log (not committed), no others
of note.

### DRC (`reports/drc.rpt`)
| Rule | Severity | Assessment |
|---|---|---|
| NSTD-1 | Critical Warning | `SDA` has no `IOSTANDARD` — expected, no board XDC; must be set before a bitstream |
| UCIO-1 | Critical Warning | `SDA` has no pin `LOC` — expected, same reason |
| CFGBVS-1 | Warning | `CFGBVS`/`CONFIG_VOLTAGE` unset — board-level property |
| RTSTAT-10 | Warning | 26 nets with no routable loads (`avs_readdata[23:0]`, `avs_readdatavalid`, `irq`) — OOC output ports |

Vivado also notes that connectivity DRCs are reduced for an out-of-context design.

## RTL changes
One change to core RTL, vendor-neutral, in `rtl/i3c_target_top.sv`:

```systemverilog
`ifndef I3C_IO_MODULE
  `define I3C_IO_MODULE i3c_io_altera
`endif
`I3C_IO_MODULE u_io ( ... );
```

**Why:** the top instantiated `i3c_io_altera` by name, so a second vendor shim could not
be used without either editing the top or giving the Xilinx module the Altera name. The
macro defaults to `i3c_io_altera`, so the Quartus, Icarus and formal flows are unchanged
with no extra defines; Vivado/xsim pass `I3C_IO_MODULE=i3c_io_xilinx`. Checked: the
unmodified `sim/run.sh` file list still gives 29/29 with Icarus 12 (run by hand under WSL;
not re-run in Quartus or SymbiYosys, which are not part of this port).

New file `rtl/xilinx/i3c_io_xilinx.sv`: same ports and drive semantics as the Altera shim,
with an explicit `IOBUF` (`T = ~sda_oe`) instead of an inferred tri-state — OOC synthesis
inserts no I/O buffers, so the pad buffer is instantiated where it belongs. Rationale is
in the file header. No other RTL or testbench file was touched.

## xsim regression (`sim/run_xsim.ps1`)
Same file list as `sim/run.sh` with the Xilinx shim; links `unisims_ver` + `glbl` for the
`IOBUF` model. Result in `sim/xsim.log`: **29 passed, 0 failed**, `ALL TESTS PASSED`,
`$finish` at 49995 ns. The script exits non-zero unless that line is present.

## Notes / next steps for a real board
- Add `PACKAGE_PIN` / `IOSTANDARD` (and `PULLUP` or an external pull-up) for `SDA`/`SCL`
  and `clk` in a board XDC; that clears NSTD-1/UCIO-1.
- Confirm Avalon input hold in-context (or replace the placeholder `set_input_delay -min`
  with the real master's numbers).
- `AVL_ASYNC=1` builds need a second `create_clock` and `set_clock_groups -asynchronous`
  (see the XDC header); not built here.
