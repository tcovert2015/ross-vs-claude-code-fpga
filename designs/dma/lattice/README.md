# Lattice Radiant port (Certus-NX)

Port of the Quartus project in `quartus/` to Lattice Radiant 2026.1
(`Radiant Software (64-bit) 2026.1.1.229.0`, Synplify Pro `X-2025.09LR-SP1`).

| Item      | Value                                                        |
|-----------|--------------------------------------------------------------|
| Part      | `LFD2NX-40-8BG256C` (performance grade `8_High-Performance_1.0V`) |
| Top       | `pcie_dma_top`, `SYS_IF="AXI4"`, `RESET_SYNC=1`              |
| Synthesis | Synplify Pro                                                 |
| Clock     | `clk`, 125 MHz (8.000 ns), as in `quartus/pcie_dma.sdc`      |

Every number below is taken from a file under `lattice/reports/` or
`sim/build/`; the file is named next to it.

## Files

| File | Purpose |
|------|---------|
| `lattice/build.tcl` | Creates the project in `lattice/build/` (git-ignored), runs synthesis, map, PAR + STA, copies the reports to `lattice/reports/`. Exits non-zero if a stage fails or a report is missing. |
| `lattice/pcie_dma.sdc` | Pre-synthesis timing constraints (clock, reset false path, 1 ns I/O budget). |
| `lattice/pcie_dma.pdc` | Post-synthesis constraints: repeats the `rst_n` false path (Synplify does not forward it). No pin locations. |
| `scripts/run_questa.ps1` | Questa regression (AXI4, AXI4+STALLS x seeds 1 2 3). |
| `lattice/reports/synthesis.srr` | Synplify Pro log |
| `lattice/reports/map.mrp` | Map report |
| `lattice/reports/par.par` | Place & route report |
| `lattice/reports/timing.twr` | Post-route static timing report |
| `lattice/reports/build_console.log` | Console output of the `build.tcl` run that produced the reports above |
| `lattice/reports/timing_io_delay_variant.twr` | Post-route timing of an earlier run with Quartus-style `set_input_delay`/`set_output_delay` (kept as evidence for "I/O timing model" below; not produced by `build.tcl`) |

## How to run

From `designs/dma` (PowerShell; Git Bash works the same with forward slashes):

```powershell
# synthesis + map + PAR + STA  (about 1 min 48 s on the machine used here)
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe lattice\build.tcl > lattice\reports\build_console.log 2>&1

# Questa regression (QuestaSim Lattice Edition bundled with Radiant)
pwsh scripts\run_questa.ps1
```

`build.tcl` deletes and recreates `lattice/build/`, so do not run it from a
shell whose current directory is inside `lattice/build/` (Windows refuses the
delete). `run_questa.ps1` uses `D:\lscc\radiant\2026.1` unless `RADIANT_HOME`
is set.

## Pinout / virtual I/O

No pin locations are assigned. `pcie_dma_top` has 763 bus-port bits, the BG256
package has 185 PIOs (`map.mrp`, Design Summary). As with
`quartus/virtual_pins.tcl`, the ports are virtual: the strategy option
`map_set_virtual_io_all_ports=True` (`map -vio`) strips the I/O buffers and
puts a feed-through LUT4 on each port (`Number of Virtual IOs: 763`).

- `clk` is the one exception: map keeps its pad because it drives a clock
  (`WARNING <52281049>`), and PAR picked a clock-capable site for it
  (`par.par`: `PRIMARY "clk_c" ... on CLK_PIN site "C16 (PT76A)"`). That
  location was chosen by the tool, not constrained.
- Disabling I/O insertion in Synplify instead (`syn_disable_io_insert`) does
  not work: map then stops with `ERROR <71006014> Design is without any IO
  buffer`. I/O insertion is therefore left on.

## Results

### Timing at 125 MHz (`reports/timing.twr`, post-route)

| Check | Corner | Errors | Worst slack | Worst endpoint |
|-------|--------|--------|-------------|----------------|
| Setup | `8_High-Performance_1.0V`, 85 °C | 0 endpoints, TNS 0.000 ns | **+1.097 ns** | `u_core/u_mover/r_read_q.ff_inst/CE` |
| Setup | `8_High-Performance_1.0V`, 0 °C  | 0 endpoints, TNS 0.000 ns | +1.177 ns | same |
| Hold  | `m`, 0 °C                        | 0 endpoints, TNS 0.000 ns | **+0.143 ns** | `u_core/base_reg[22].ff_inst/DF` |

- **Timing is met at 125 MHz.** Constraint coverage 100 %, combinational
  loops: none.
- Critical path: `u_core/u_mover/u_fifo/rptr[0]` -> `u_core/u_mover/r_read_q`
  clock enable, 11 logic levels, 56.3 % route / 43.7 % logic. It goes through
  the FIFO's asynchronous-read distributed RAM (see Utilization).
- **Achievable Fmax.** With +1.097 ns of slack on the 8.000 ns constraint the
  design would close at a period of 8.000 - 1.097 = **6.903 ns (about
  144.9 MHz)**. Radiant's own clock summary for the same corner reports
  `Actual (all paths) 6.877 ns / 145.412 MHz` (146.778 MHz at 0 °C). This is
  an estimate from a run constrained at 8 ns; it was not re-run at a tighter
  period.
- The ten worst setup endpoints at 85 °C are all register-to-register
  (+1.097 to +1.267 ns). The worst port path listed is `host_writedata[21]`,
  +1.294 ns against its 7.000 ns budget (0 °C section).
- `clk_pad.bb_inst/B (MPW)` limits the clock pad to 5.000 ns / 200 MHz
  minimum pulse width; not a constraint at 125 MHz.
- 132 input ports are reported as "I/O ports without constraint": the
  `avm_*` and AHB inputs, which are unconnected for `SYS_IF="AXI4"`.

### I/O timing model (difference from `quartus/pcie_dma.sdc`)

`quartus/pcie_dma.sdc` puts `set_input_delay`/`set_output_delay -clock clk 1.0`
on the bus ports. Ported literally, that fails here, and the failure is an
artifact of the virtual pins rather than of the design
(`reports/timing_io_delay_variant.twr`, same RTL and flow, I/O delays instead
of max-delay budgets):

| | Errors | Worst slack |
|---|---|---|
| Setup, 85 °C | 206 endpoints | -2.056 ns (`rptr_reg[3]` -> `host_writedata[26]`), "Actual" 99.443 MHz |
| Hold, `m` 0 °C | 1489 endpoints | -1.048 ns (`host_readdata[37]` -> `beats_0_[37]`) |

In both worst paths the whole violation is clock skew: the launching/capturing
flop sees the clock after the pad and primary clock network (4.098 ns at the
slow corner, 2.104 ns at the fast corner) while the port is referenced to the
clock at the `clk` port with zero latency. The worst setup path's data delay is
4.958 ns. In a real integration the neighbouring logic sits on the same clock
network, so that skew does not exist.

`lattice/pcie_dma.sdc` therefore expresses the same 1 ns budgets as
datapath-only limits, which do not include the clock insertion delay:

```
set_max_delay -from <input ports>               -datapath_only 7.0   ;# 8 - 1
set_max_delay -from [get_clocks clk] -to [all_outputs] -datapath_only 7.0
set_max_delay -from <input ports> -to [all_outputs]    -datapath_only 6.0   ;# 8 - 1 - 1
```

Consequences to be aware of:

- Port paths are setup-checked only; there is no hold check on them (the hold
  relationship to the neighbouring logic can only be checked once integrated).
- Synplify reports the 6.0 ns port-to-port constraint as unused (`MT444`,
  "none of the paths specified by the constraint exist"): there is no
  combinational input-to-output path in this configuration. It is kept so the
  SDC stays correct if one appears.
- `derive_clock_uncertainty` has no Radiant equivalent and is dropped; no
  clock uncertainty is applied (`Uncertainty 0.000` in the path reports). The
  slack above has to absorb the jitter of whatever eventually drives `clk`.

### Utilization (`reports/map.mrp`, Design Summary; `reports/par.par`)

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT4 (total) | 4880 | 32256 | 15 % |
| - logic | 2097 | | |
| - distributed RAM | 1536 | | |
| - ripple logic (CCU2) | 484 | | |
| - feed-through LUTs for virtual I/O | 763 | | |
| Registers | 816 | 32811 | 2 % |
| EBR (Block RAMs) | 0 | 84 | 0 % |
| Large RAMs | 0 | 2 | 0 % |
| DSP | 0 | | |
| SLICEs (post-PAR) | 4209 | 16128 | 26 % |
| PIOs used | 1 (`clk`) | 185 | |

- The 763 feed-through LUT4s exist only because of the virtual I/O; without
  them the design uses 4880 - 763 = 4117 LUT4.
- **EBR = 0 is a property of the RTL, not a tool miss.** The 256 x 64 data
  FIFO (`rtl/core/dma_fifo.sv`) is show-ahead with a combinational read
  (`assign rd_data = mem[rptr]`). Certus-NX EBR has a synchronous read port,
  so Synplify maps the memory to distributed RAM (1536 LUT4), and its output
  mux is in the critical path. Mapping it to EBR needs a registered-read FIFO
  (with a show-ahead bypass stage); that changes core RTL and its timing
  behaviour, so it was **not** done here.

### Warnings

Counts: `grep -c` over the committed reports.

| Stage | Errors | Warnings | Other |
|-------|--------|----------|-------|
| Synthesis (`synthesis.srr`) | 0 | 24 (`@W`) | 2 advisories (`@A`), 335 notes (`@N`) |
| Map (`map.mrp`) | 0 | 273 | 0 criticals |
| PAR (`par.par`) | 0 | 136 | |

Synthesis warnings, by ID:

| ID | Count | What | Assessment |
|----|-------|------|------------|
| CL190 | 5 | `err_code[7:3]` optimized to constant 0 (`dma_engine_core.sv:228`) | Benign: upper error-code bits are never set. |
| CL279 | 1 | Pruning `err_code[7:3]` | Same as above. |
| BN132 | 4 | Equivalent registers merged (`wstate[0]`/`w_write_q`, `w_burstcount_q`/`w_blen`, `r_burstcount_q`/`r_blen`, `f_start`/`estate[1]`) | Benign optimization. |
| CS141 | 2 | `altera_attribute` on `reset_sync.sv:28` not recognized | Expected: Quartus-only attribute. Both synchronizer flops are present in the netlist (`sync_q_reg[0]` in `build_console.log`, `sync_q[1]` driving `rst_n_int` in the `par.par` clock report), but nothing vendor-specific keeps them adjacent. Worth a look before hardware; see "Left undone". |
| CL169 / CL271 | 1 / 2 | Unused descriptor beat registers/bits pruned (`dma_descriptor_fetch.sv:128`) | Benign: reserved descriptor bits. |
| CL247 | 2 | `axi_bresp[0]`, `axi_rresp[0]` unused (`gmm_to_axi4.sv`) | Design choice: only bit 1 (SLVERR/DECERR) is decoded, so EXOKAY is treated as OKAY. |
| CL246 | 1 | `length[2:0]` unused in `dma_data_mover` | Design choice: transfers are whole 64-bit beats. |
| FX107 | 1 | FIFO RAM has no read/write conflict check | Benign here: asynchronous-read distributed RAM, and the head is not consumed while `empty`. |
| MT447 | 1 | `set_false_path -from rst_n` not applied by Synplify | Tool behaviour (`rst_n` has no arrival time in Synplify's timer). Re-applied in `pcie_dma.pdc`; it appears in `timing.twr` section 1.1. |
| MT444 | 1 | 6.0 ns port-to-port `set_max_delay` not applied | No such paths exist (see above). |
| MF511 | 1 | "Found issues with constraints" | Summary line for MT447/MT444. |
| BW295 | 1 | Clock forward annotation moved to driving pin | Tool note; `clk` is constrained in `timing.twr`. |
| FX310 | 1 | `-dcc_insertion` ignored | Tool option not applicable. |

Advisories: 2 x CL282 "feedback mux created" for `aw_len_q`, `aw_addr_q`
(`gmm_to_axi4.sv:149`), registers without reset; area/timing hint only.

Map: 272 of the 273 warnings are `WARNING <71003020> Top module port ... does
not connect to anything`, reported twice for each of 136 unused input bits
(`avm_readdata[63:0]`, `avm_readdatavalid`, `avm_waitrequest`, `hrdata[63:0]`,
`hready`, `hresp`, `axi_bid`, `axi_rid`, `axi_bresp[0]`, `axi_rresp[0]`). The
remaining one is `WARNING <52281049>` (`clk` keeps its pad). PAR repeats the
same 136 unused-port warnings. All expected: `pcie_dma_top` always carries the
port groups of all three buses and only AXI4 is selected.

**None of the warnings indicates a functional problem.** The two items worth a
reader's attention are structural rather than warnings: the FIFO not mapping to
EBR, and the reset synchronizer having no Lattice placement/identification
attribute.

### Questa regression (`sim/build/questa_<cfg>_seed<n>.log`)

`scripts/run_questa.ps1`, QuestaSim Lattice Edition from the Radiant install,
pass criterion `=== PASS` in the run log (same as `scripts/run_sim.sh`):

| Config | Defines | seed 1 | seed 2 | seed 3 |
|--------|---------|--------|--------|--------|
| AXI4 (`questa_axi4_seed<n>.log`) | `+define+USE_AXI` | PASS | PASS | PASS |
| AXI4 + stalls (`questa_axi4_stalls_seed<n>.log`) | `+define+USE_AXI +define+STALLS` | PASS | PASS | PASS |

All six logs report `Errors: 0, Warnings: 0`.

- `vsim` is run with `-suppress 7061`. Without it Questa refuses to elaborate:
  the testbench backdoor-writes the memory models' `mem` arrays
  (`sim/tb_pcie_dma.sv`, e.g. lines 394, 490, 682) while the models also write
  `mem` from an `always_ff`, which Questa flags as a suppressible error
  (vopt-7061, 5 occurrences; the first run of each config logs `Suppressed
  Errors: 5`). Icarus accepts it. It is testbench-only code, so the check is
  suppressed instead of editing the testbench.
- As in `run_sim.sh`, these two configurations simulate the testbench default
  `RESET_SYNC=0`; the synthesized configuration uses `RESET_SYNC=1`. The
  `RESET_SYNC_EN` testbench option exists but is not part of this regression.

## RTL changes

**None.** No file under `rtl/` or `sim/` was modified. The port consists of new
files only (`lattice/`, `scripts/run_questa.ps1`) plus a `.gitignore` entry for
`lattice/build/`.

## Left undone / caveats

- No bitstream was generated (not requested; the design has no pinout).
- Fmax is derived from the slack of the 8 ns run, not confirmed by a run at a
  tighter period.
- No hold check and no clock uncertainty on port paths (see "I/O timing
  model").
- FIFO stays in distributed RAM (0 EBR); moving it to EBR needs a core RTL
  change that was deliberately not made.
- `reset_sync` carries only an Altera synchronizer attribute; no Lattice
  equivalent was added because that would be an RTL change.
- The Questa regression covers RTL simulation only; no post-synthesis or
  post-route gate-level simulation was run.
