# Lattice Synthesis & Timing (Radiant, Certus-NX)

The device-agnostic RTL builds for a Lattice Nexus device; the only Lattice-specific
file is `rtl/lattice/i3c_io_lattice.sv` (tri-state SDA pad, same ports and drive
semantics as `rtl/altera/i3c_io_altera.sv`).

## Build
```
powershell -File syn/lattice/build.ps1      # runs build.tcl, tees console to reports/build_console.log
# or directly:
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe syn/lattice/build.tcl
```
`build.tcl` is a Radiant **project flow** (`prj_*` Tcl). It recreates a scratch project
in `syn/lattice/build/` (git-ignored) and runs, in order: **Synplify Pro synthesis →
map → place & route → STA**, then copies the reports to `syn/lattice/reports/`.
A full run takes about one minute.

| File | Purpose |
|---|---|
| `build.tcl` / `build.ps1` | the flow / a wrapper that keeps the console log |
| `i3c_target.sdc` | timing constraints (synthesis, map, PAR, STA) — `clk` = 8.0 ns |
| `i3c_target.pdc` | physical constraints: `PULLMODE=NONE` on SDA/SCL only, **no pin locations** |
| `i3c_target_core.sdc` | extra false-paths for the second, core-only STA pass (not used by PAR) |
| `reports/synthesis.srr` | Synplify Pro log |
| `reports/map.mrp` | map report |
| `reports/par.par`, `reports/pad.pad` | PAR report, pad report (the auto-chosen pins) |
| `reports/timing.twr` | post-route STA, full constraints |
| `reports/timing_core.twr` | post-route STA, same routed design, chip-pin paths cut |
| `reports/build_console.log` | whole console output (carries the Radiant-side messages) |

Device **`LFD2NX-40-8BG256C`** (Certus-NX, performance grade `8_High-Performance_1.0V`),
top `i3c_target_top`, default parameters (`AVL_ASYNC=0`). Tools: Radiant 2026.1.1.229.0,
Synplify Pro X-2025.09LR-SP1.

**Pinout:** none assigned. Radiant did not insist on locations; PAR placed all 73 ports
itself (`reports/pad.pad`) and put `clk` on a dedicated clock pin (C16, `PCLKT0_0`)
driving a primary clock net. All pads are at the tool default `LVCMOS33`.

## Results

| Stage | Result |
|---|---|
| Synthesis (Synplify Pro) | **0 errors**, 34 warnings, 371 notes |
| Map | **0 errors**, 22 warnings (11 distinct, each printed twice) |
| Place & route | **0 errors**, completely routed, 11 warnings (the same 11 as map) |
| STA, full constraints | **FAILS**: 27 setup + 130 hold endpoints, all on Avalon chip-pin paths |
| STA, core-only | **MET**: 0 setup, 0 hold failing endpoints |

### Utilization (`reports/map.mrp`)
| Resource | Used | Available |
|---|---|---|
| LUT4 | **914** (816 logic, 36 distributed RAM, 62 ripple/carry) | 32256 (3%) |
| Registers | **331** (330 slice + 1 PIO input register) | 32811 (1%) |
| EBR (block RAM) | **0** | 84 |
| IO (PIO) | **73** | 185 |
| Primary clocks | 1 (`clk_c`, 337 loads) | |

The two 8-deep FIFOs map to distributed RAM (6 × `DPR16X4`), not EBR — which is why the
Altera build shows 2 RAM blocks and this one shows none. The one PIO input register is
the first SDA synchronizer flop, which Synplify packed into the pad cell. IO count is 73
rather than Altera's 84 because 11 unused input ports get no pad here (see warnings).

### Timing — read this carefully

Constraint: `clk` 8.0 ns (125 MHz). Setup is analysed at the 85 °C and 0 °C corners of
speed grade 8, hold at the `m` (min) corner; the table gives the worst of them.

| View | Worst setup slack | Worst hold slack | Fmax (all paths in view) | Verdict |
|---|---|---|---|---|
| **Full constraints** (`timing.twr`) — Avalon ports timed as chip pins | **−5.338 ns** (`irq`) | **−0.714 ns** (`avs_writedata[23]` → `u_av/ibi_plen_q_reg[7]`) | **74.97 MHz** (13.338 ns) | **NOT MET** |
| **Core-only** (`timing_core.twr`) — register-to-register | **+1.082 ns** (`u_rf/mwl[8]` CE) | **+0.084 ns** (`u_rxfifo` RAM write address) | **144.55 MHz** (6.918 ns) | **MET** |

Both rows are the *same* placed-and-routed netlist; the second is a re-run of `timing`
with `i3c_target_core.sdc` adding false-paths on every data port, so it isolates the
internal logic. Nothing was re-optimised for it. (Synplify's own pre-route estimate was
135.1 MHz, +0.599 ns.)

**The internal logic meets 125 MHz with 1.08 ns of margin. The design as a standalone
chip, with the placeholder 1.0 / 0.3 ns Avalon I/O budgets copied from the Altera SDC,
does not.** Same out-of-context situation as the Altera build, but larger here:

- **Setup, 27 endpoints** — every one is an Avalon output pin (`irq`, `avs_waitrequest`,
  `avs_readdatavalid`, `avs_readdata[*]`). On the worst path (`irq`, `timing.twr` path 1)
  the clock takes 4.098 ns to reach the launch flop (pad + clock tree, no PLL to remove
  it), the output pad buffer costs 4.665 ns, and 1.0 ns is reserved by `set_output_delay`
  — 9.8 ns of the 8 ns period before any logic. Even the registered `avs_readdata` bits
  miss by ~2.7 ns for this reason.
- **Hold, 130 endpoints** — Avalon *input* pins into registers / FIFO RAM. The data
  arrives 0.3 ns (min input delay) + pad after the clock edge, but the clock arrives
  ~2.1 ns later at the flop, so the data changes too early. PAR did not repair these
  (`par.par` reports no hold slack estimate).

Neither class exists when the block is used as intended — an on-chip IP whose Avalon
ports connect to fabric, with no pads and no clock-insertion mismatch. For a real
chip-pin Avalon deployment these are genuine and need fixing on the board/system side:
real I/O budgets instead of the placeholders, a PLL (or source-synchronous clocking) to
cancel clock insertion delay, pin locations with a faster IO type, and — for `irq`, which
is a combinational OR of status bits — an output register. `avs_waitrequest` must stay
combinational (Avalon), exactly as discussed in `syn/altera/README.md`.

**Constraint coverage:** 100 % (`timing.twr` §1.2). Unconstrained items: `avl_clk` and
`avl_rst_n` (unused in the `AVL_ASYNC=0` build) and the 9 unused data inputs listed
below. SDA, SCL and `rst_n` are false-pathed (asynchronous; closed by the synchronizers).

### Warnings — synthesis (`reports/synthesis.srr`): 0 errors, 34 warnings

| ID | # | What | Assessment |
|---|---|---|---|
| MT682 | 9 | `set_input_delay` has no effect on unconnected port: `avs_writedata[31:24]`, `avs_byteenable[3]` | **Real but harmless.** No register uses the top byte of write data, so those inputs drive nothing. An RTL property, not a flow problem. |
| BN132 | 7 | `u_av.rd_data_q[31:25]` removed as equivalent to bit 24 | Benign: upper read-data bits are always equal (zero-extended registers); 7 flops saved. |
| CL169 | 5 | Pruning unused registers: `m7e_q`, `mda_q` (protocol_fsm), `is_mdb`, `mdb_en` (ibi), `outstanding[1:0]` (avalon_mm) | **Real dead code** — assigned but never read. Harmless, worth cleaning upstream. |
| CL246/CL247 | 4 | Unused input port bits: `app_wr_data[31:24]`, `app_wr_be[3]` (regfile), `bcr[7:3]`, `bcr[0]` (ibi) | Benign; the source of the MT682 group above. |
| CL260 / CL265 | 3 | Pruned register bits: `bit_idx[3]` (ibi), `payload_idx[6]` (daa), `shift_reg[7]` (bit_engine) | Benign; counters/shifters declared one bit wider than used. |
| CG1340 | 2 | "Index … could be out of range" at `i3c_ibi.sv:115,117` | **False positive.** The index is `3'd7 - bidx` with a 3-bit `bidx`, always 0–7 into an 8-bit vector. |
| FX474 | 2 | User-specified initial values on sequential elements | Benign; reset/initial values are honoured, the message is QoR advice. |
| FX310 | 1 | `-dcc_insertion` ignored | Tool noise (option Radiant always passes). |
| BW295 | 1 | Clock forward-annotated on the driving pin instead of the input port | Tool noise; the clock is constrained (see `timing.twr` §1.1). |

### Warnings — map (`reports/map.mrp`): 0 errors, 22 warnings

One message, 11 ports, each printed twice: **"Top module port '…' does not connect to
anything"** for `avl_clk`, `avl_rst_n`, `avs_writedata[31:24]`, `avs_byteenable[3]`.
Expected: `avl_clk`/`avl_rst_n` are only used when `AVL_ASYNC=1`, and the other nine are
the unused write-data bits already flagged by synthesis. PAR repeats the same 11 once.

### Warnings — Radiant front end (only in `reports/build_console.log`)

| ID | # | What | Assessment |
|---|---|---|---|
| 35811116 | 20 | "Attribute 'ST_TBIT' … cannot be supported. It will be ignored" (post-synthesis netlist import) | Benign: `localparam` names carried as netlist attributes. |
| 35931002 (VDB-1002) | 2 | `io_sda_i` / `io_scl_i` "does not have a driver" | **Not real, but worth knowing.** Radiant's own pre-synthesis elaboration (used to distribute the SDC) does not elaborate the `u_io` shim instance and so sees its outputs as undriven. Synplify — which produces the actual netlist — does: `synthesis.srr` shows `i3c_io_lattice` synthesized and the resource report has exactly 1 `BB` (SDA) and 37 `IB` (SCL + other inputs). |
| 70001925 | 1 | "clock clk has been defined multiple times" | Expected, from the core-only STA pass re-declaring `clk`. |

## RTL changes

One, in `rtl/i3c_target_top.sv`, **vendor-neutral**: the IO shim instance was hard-coded
as `i3c_io_altera u_io (...)`. It is now `` `I3C_IO_MODULE u_io (...) `` with

```systemverilog
`ifndef I3C_IO_MODULE
  `define I3C_IO_MODULE i3c_io_altera
`endif
```

so every existing flow (Quartus, Icarus, formal) is unchanged when the macro is not
defined, and the Lattice flows pass `I3C_IO_MODULE=i3c_io_lattice` (`VERILOG_DIRECTIVES`
in `build.tcl`, `+define+` in `sim/run_questa.ps1`). Without this the top could not
select another vendor's wrapper at all. No other core RTL was touched. Checked both
ways in QuestaSim: 29/29 with the Lattice shim (`sim/questa.log`) and 29/29 with the
macro undefined (Altera shim; run by hand, not logged).

New file: `rtl/lattice/i3c_io_lattice.sv` — inferred tri-state rather than an explicit
`BB` primitive (rationale in its header); Synplify maps it to a `BB` pad cell.

## Simulation
```
powershell -File sim/run_questa.ps1         # -> sim/questa.log
```
Runs `tb_i3c_target` in the QuestaSim bundled with Radiant (2025.2), same file list as
`sim/run.sh` with the Lattice shim: **29 passed, 0 failed**, 0 compile/sim warnings.

## Notes / next steps for a real board
- Add `ldc_set_location` pin assignments and the real `IO_TYPE` (LVCMOS18/LVCMOS12 for
  I3C) for SDA/SCL/clk in `i3c_target.pdc`. Radiant's default pad pull is `DOWN`; the
  PDC already turns it off for SDA/SCL so it does not fight the bus pull-up. Leave
  `OPENDRAIN=OFF` — the pad must also drive push-pull High.
- Replace the placeholder Avalon I/O delays in `i3c_target.sdc` with real numbers, or
  drop them if the Avalon side stays on-chip.
- A timing-only map report (`MapTrace`) is not generated; post-route STA is the sign-off.
