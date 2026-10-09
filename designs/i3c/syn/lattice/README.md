# Lattice Synthesis & Timing (Radiant 2026.1, Certus-NX)

The device-agnostic RTL builds for a Lattice Nexus device; the only Lattice-specific
file is `rtl/lattice/i3c_io_lattice.sv` (tri-state SDA pad, same ports and drive model
as `rtl/altera/i3c_io_altera.sv`).

## Build
Radiant runs natively on Windows; nothing is staged elsewhere. From `designs/i3c/`:
```
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe syn/lattice/build.tcl > syn/lattice/reports/build_console.log 2>&1
pwsh sim/run_questa.ps1          # Questa regression, log -> sim/questa.log
```
`build.tcl` creates a scratch project in `syn/lattice/build/` (git-ignored, deleted on
every run) and runs **Synplify Pro synthesis → map → place & route → STA**, then copies
the reports into `syn/lattice/reports/`:

| File | What |
|---|---|
| `i3c_target_impl_1.srr` | Synplify Pro synthesis log |
| `i3c_target_impl_1.mrp` | map report (utilization, map warnings, IO attributes) |
| `i3c_target_impl_1.par` | place & route report |
| `i3c_target_impl_1.twr` | STA, **all paths** as constrained by `i3c_target.sdc` |
| `i3c_target_impl_1.r2r.twr` | STA, same routed design, **register-to-register only** |
| `i3c_target_impl_1.pad` | the pins PAR picked |
| `build_console.log` | full console output of the run |

Files: `build.tcl` (flow), `i3c_target.sdc` (timing, mirrors the Altera SDC),
`i3c_target.pdc` (pad pull mode only), `i3c_target_r2r.sdc` (analysis-only overlay for
the second STA pass). Device **`LFD2NX-40-8BG256C`**, performance grade
`8_High-Performance_1.0V`, top `i3c_target_top`, `clk` = 8.0 ns (125 MHz).

**Pinout:** none. Radiant did not insist on pin locations; PAR placed every pad itself
(`clk` landed on a dedicated clock pin, C16, and is routed as a primary clock). The
`.pdc` assigns no locations.

## Results (Radiant 2026.1.1.229.0, Synplify Pro X-2025.09LR-SP1, `LFD2NX-40-8BG256C`)
| Stage | Result |
|---|---|
| Synthesis (Synplify Pro) | **0 errors**, 34 warnings |
| Map | **0 errors**, 0 criticals, 22 warnings |
| Place & route | **0 errors**, 4401/4401 connections routed, 0 unrouted |
| Questa regression | **29 passed, 0 failed** (`sim/questa.log`) |

### Utilization (post-map, `.mrp`)
| Resource | Used | Available |
|---|---|---|
| LUT4 | **914** (816 logic, 36 distributed RAM, 62 ripple/carry) | 32256 (3%) |
| Registers | **331** (330 slice + 1 PIO input register on SDA) | 32811 (1%) |
| EBR (block RAM) | **0** | 84 |
| PIO | **73** used (plus 7 reserved for sysCONFIG) | 185 |

The two 8-deep FIFOs map to distributed RAM (6 × `DPR16X4`), not EBR, which is why EBR
is 0 where the Cyclone 10 GX build reports 2 RAM blocks. The top has 84 ports; 11 are
unconnected inputs in the default `AVL_ASYNC=0` build (see warnings) and get no pad,
hence 73.

### Timing — read this carefully

Same situation as the Altera build, and reported the same way: split by path class.

| Path class | Worst setup slack @ 8.0 ns | Worst hold slack | Verdict |
|---|---|---|---|
| **Register-to-register** (`.r2r.twr`) | **+1.082 ns** → 6.918 ns, **Fmax 144.55 MHz** | **+0.084 ns** | **MET**, 0 failing endpoints in every corner |
| **All paths incl. Avalon pins** (`.twr`) | **−5.338 ns** (`irq`), 27 failing endpoints, TNS 75.647 ns; reported Fmax 74.97 MHz | **−0.714 ns**, 130 failing endpoints | does **not** close standalone |

Setup figures are the worse of the two setup corners (85 °C; the 0 °C corner gives
+1.134 ns / 145.65 MHz register-to-register and −5.268 ns all-paths). Hold is analysed
at the min (`m`) corner. Constraint coverage is 100 %, no combinational loops.

**The internal logic meets 125 MHz with 1.08 ns of margin.** The critical path is
`u_be/byte_done` → CCC decode → `u_rf/mwl[8]` clock enable, 7 logic levels.

**The build as constrained does not meet timing**, and the PAR report says so too
(`.par`: estimated worst setup slack −6.128 ns). Every failing endpoint is on a
top-level port path: cutting the port paths (`i3c_target_r2r.sdc`) on the *same routed
database* leaves 0 setup and 0 hold errors. What fails:

- **Setup, Avalon outputs.** Worst are `irq` (−5.338 ns) and `avs_waitrequest`
  (−5.058 ns), then `avs_readdata[*]` / `avs_readdatavalid` (about −2.7 ns). On the `irq`
  path the clock takes 4.098 ns to reach the launch register (pad 1.468 + clock tree
  2.630) and the output pad buffer alone is 4.665 ns, so pad-in plus pad-out already
  exceeds the 7.0 ns left after the 1.0 ns output delay, before any logic. Even the
  registered `avs_readdata` cannot make it through an LVCMOS33 pad in this budget.
- **Hold, Avalon inputs.** The 10 worst hold paths all start at `avs_writedata[*]`
  pins: with a 0.3 ns minimum input delay the data beats the 4.1 ns clock insertion
  delay to the register.

This is the same **out-of-context artifact** the Altera README describes, and it is
larger here because every Avalon port goes through a general-purpose 3.3 V pad with no
pin planning. An Avalon-MM agent is an on-chip IP boundary; inside a real design these
ports connect to fabric, not pads. I did not relax or remove the Altera I/O budgets to
make the summary go green — the SDC carries the same clock, cuts and
`set_input_delay`/`set_output_delay` values as `syn/altera/i3c_target.sdc`.

One consequence worth knowing: PAR spent its effort on the unfixable I/O paths. The
register-to-register numbers above are therefore what this placement happens to give,
not the best the device can do for this logic.

**Unconstrained ports:** `avl_clk` and `avl_rst_n` (unused in the default build), as in
the Altera run. The 9 unconnected `avs_writedata[31:24]` / `avs_byteenable[3]` inputs
are listed as "no arrival" start points because they drive nothing.

### Warnings

**Synplify Pro: 34 warnings, 0 errors** (`.srr`). None is a functional problem.

| Count | ID | What | Assessment |
|---|---|---|---|
| 9 | MT682 | `set_input_delay` on unconnected port (`avs_writedata[31:24]`, `avs_byteenable[3]`) | Benign. No register uses those bits. Kept in the SDC to match the Altera constraint set. |
| 7 | BN132 | `u_av.rd_data_q[31:25]` merged into `[24]` as equivalent registers | Benign optimisation: those read-data bits always carry the same value. |
| 5 | CL169 | Unused registers pruned (`m7e_q`, `mda_q`, `is_mdb`, `mdb_en`, `outstanding`) | Benign dead logic, but real in the sense that the RTL carries registers nothing reads. Worth a cleanup upstream. |
| 2+2 | CL246 / CL247 | Unused input port bits (`app_wr_data[31:24]`, `app_wr_be[3]`, `bcr[7:3]`, `bcr[0]`) | Benign, same root cause as MT682. |
| 2 | CL260 | Register bits pruned (`bit_idx[3]`, `payload_idx[6]`) | Benign: counters declared one bit wider than they ever count. |
| 2 | CG1340 | "Index into `hdr_word` / `cur_byte` could be out of range" (`i3c_ibi.sv:115,117`) | False positive. The index is `3'd7 - bidx` with a 3-bit `bidx`, always 0..7 into an 8-bit vector. |
| 2 | FX474 | Registers with declared initial values | Informational. |
| 1 | CL265 | Unused bit 7 of `shift_reg` removed (`i3c_bit_engine.sv:63`) | Benign. |
| 1+1 | FX310 / BW295 | Tool notes (no DCC in this technology; clock forward-annotated on the driving pin) | Not about the design. |

**Map: 22 warnings, 0 criticals, 0 errors** (`.mrp`). All 22 are one message,
`71003020 Top module port '…' does not connect to anything`, for 11 ports reported
twice: `avl_clk`, `avl_rst_n`, `avs_writedata[31:24]`, `avs_byteenable[3]`. Real but
expected: the first two are unused by design when `AVL_ASYNC=0`, the rest are write
bits no register implements. PAR repeats the same 11.

**Elsewhere in `build_console.log`** (not in the synthesis log or map report):
- 2 × `35931002 net io_sda_i / io_scl_i does not have a driver` from Radiant's
  pre-synthesis source compile. That pass does not elaborate the macro-selected IO shim
  (it never lists `i3c_io_lattice` among the modules it compiles). It is not true of
  the netlist that gets built: Synplify synthesizes `i3c_io_lattice`, the `.srr` cell
  list has 1 `BB` (SDA) feeding the `sda_sr[0]` synchronizer flop, and the `.mrp` /
  `.pad` show SDA as a bidirectional pad. The 29/29 simulation exercises the same path.
- 20 × `35811116 Attribute '…' on Module '…' cannot be supported` — localparam names
  Synplify forwards as attributes. Noise.

## RTL changes

One, in core RTL, vendor-neutral: `rtl/i3c_target_top.sv` instantiated `i3c_io_altera`
by name, so no other vendor's shim could be used without editing the top. The instance
is now `` `I3C_IO_SHIM u_io (...) `` with

```systemverilog
`ifndef I3C_IO_SHIM
  `define I3C_IO_SHIM i3c_io_altera
`endif
```

The default is the Altera shim, so the Quartus project, `sim/run.sh` and the formal
flow see the same design as before. The Lattice flows pass
`I3C_IO_SHIM=i3c_io_lattice`. No logic changed. Checked: the testbench passes 29/29 in
Questa with the Lattice shim (`sim/questa.log`) and also with no define, i.e. the
default Altera shim. **Not re-run:** `sim/run.sh` under Icarus (the Icarus 11/12
available on this machine stops with a syntax error in the untouched `rtl/i3c_pkg.sv`),
the Quartus build, and the formal proofs.

New files only otherwise: `rtl/lattice/i3c_io_lattice.sv` uses an inferred tri-state,
which Synplify maps to the Nexus `BB` primitive; the reasons are in its header.

## Simulation (`sim/run_questa.ps1`)
Compiles the `sim/run.sh` file list with `rtl/lattice/i3c_io_lattice.sv` in place of
the Altera shim and runs `tb_i3c_target` in the QuestaSim Lattice Edition bundled with
Radiant (`qrun`, Questa 2025.2). Result: **29 passed, 0 failed**, 0 errors, 0 warnings.
`-mfcu` compiles the list as one compilation unit, as Icarus does; without it Questa
recompiles `i3c_pkg` for each file that includes it and prints 13 overwrite warnings
(the result is the same). No Lattice primitive library is needed because the shim is
plain SystemVerilog.

## Notes / next steps for a real board
- Add `ldc_set_location` pin assignments and the bus `IO_TYPE` to `i3c_target.pdc`.
- `i3c_target.pdc` already sets `PULLMODE=NONE` on SDA and SCL. The Nexus default for
  an unconstrained pad is a weak pull-**down**, which would fight the I3C pull-up /
  high-keeper; the `.pad` report confirms the two bus pads now show `PULLMODE:NONE`.
  Leave `OPENDRAIN` off on SDA: I3C needs push-pull drive in SDR data phases.
- The pad defaults also include `GLITCHFILTER:ON` and `HYSTERESIS:ON` on SDA/SCL. Not
  evaluated here against I3C timing at 12.5 MHz; check before board use.
- For a chip-pin Avalon deployment the I/O paths need pin planning, a faster IO
  standard, and I/O delays budgeted to the real master. As an embedded IP none of that
  applies.
