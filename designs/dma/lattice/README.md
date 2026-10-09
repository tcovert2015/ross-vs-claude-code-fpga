# Lattice Radiant port (Certus-NX)

Radiant 2026.1 flow and QuestaSim regression for the PCIe scatter-gather DMA
engine. Every number below is copied from a file committed under
`lattice/reports/` or `sim/build/`; the source file is named next to it.

| Item | Value |
|---|---|
| Tool | Lattice Radiant 2026.1.1.229.0, Synplify Pro X-2025.09LR-SP1, QuestaSim Lattice Edition (bundled) |
| Device | `LFD2NX-40-8BG256C` (performance grade `8_High-Performance_1.0V`) |
| Top / parameters | `pcie_dma_top`, `SYS_IF="AXI4"`, `RESET_SYNC=1` |
| Clock | `clk`, 125 MHz (8.000 ns) |
| RTL changes | **none** |

## How to run

```bat
:: implementation: synthesis -> map -> map timing -> PAR -> PAR timing
cd lattice
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe build.tcl
```

Scratch output goes to `lattice/build/` (git-ignored). Reports are copied to
`lattice/reports/`:

| File | Content |
|---|---|
| `synthesis.srr` | Synplify Pro log |
| `map.mrp` | map report (utilization, map warnings) |
| `par.par` | place & route report |
| `timing_map.tw1` | post-map timing (pre-placement estimate) |
| `timing_par.twr` | post-route static timing analysis (sign-off numbers below) |

```sh
# simulation (Git Bash): AXI4 and AXI4+STALLS, seeds 1 2 3
./scripts/run_questa.sh
```

Logs: `sim/build/questa_<cfg>_seed<n>.log`. `sim/build/` and `*.log` are
git-ignored by the upstream `.gitignore`, so the logs were committed with
`git add -f`.

Optional second implementation run with the literal `set_input_delay` /
`set_output_delay` constraints (see [I/O constraints](#io-constraints-and-the-one-deviation-from-the-quartus-sdc)):

```bat
set DMA_SDC=pcie_dma_iodelay.sdc
D:\lscc\radiant\2026.1\bin\nt64\radiantc.exe build.tcl
```

It builds in `lattice/build_iodelay/` and reports to `lattice/reports/iodelay/`.

## Pins

No pin locations are assigned and there is no `.pdc`. `pcie_dma_top` has far
more ports than the package has pins (185 PIOs available, `map.mrp`). The
Quartus project solves this with `VIRTUAL_PIN`; the Radiant equivalent is the
map strategy option `map_set_virtual_io_all_ports=True`, set in `build.tcl`.
Result (`map.mrp`): 763 virtual I/Os, 1 real PIO (`clk`; map ignores the virtual
I/O request on a clock port, warning 52281049). `rst_n` is virtual as well.
Radiant picked the site for `clk` itself.

## Results at 125 MHz

### Timing (`reports/timing_par.twr`, post-route)

| Check | Corner | Worst slack | Endpoint | Failing endpoints |
|---|---|---|---|---|
| Setup | grade 8, 85 °C | **+1.097 ns** | `u_core/u_mover/r_read_q` CE | 0 |
| Setup | grade 8, 0 °C | +1.177 ns | `u_core/u_mover/r_read_q` CE | 0 |
| Hold | grade m, 0 °C | **+0.143 ns** | `u_core/base_reg[22]` D | 0 |

- **Timing is met at 125 MHz.** Constraint coverage 99.9887 %.
- Worst port (I/O budget) path: `u_fifo/rptr` → `host_writedata[21]`,
  +1.286 ns against the 7.0 ns budget (8 logic levels: the asynchronous read of
  the 256-deep distributed-RAM FIFO feeds the output port combinationally).
- PAR's own estimate (`par.par`) is a little more pessimistic: setup +0.807 ns,
  hold +0.143 ns, 0 unrouted connections.

### Fmax

Radiant reports "Actual (all paths)" **6.877 ns = 145.412 MHz** at the slow
corner (6.813 ns = 146.778 MHz at 0 °C). From the worst setup slack,
8.000 − 1.097 = 6.903 ns (≈ 144.9 MHz). So a period of about **6.9 ns
(≈ 145 MHz)** should close with this placement. That is derived from the 8 ns
run; I did not re-run the flow at a tighter period to confirm it, and a
different target changes placement.

### Pre-route estimates (not sign-off)

- Synplify (`synthesis.srr`): estimated 8.130 ns / 123.0 MHz, slack −0.130 ns
  on `u_fifo.rptr[0]` → `u_mover.w_dcnt[0]` (14 levels). Wire-load estimate
  only; the routed design passes.
- Post-map (`timing_map.tw1`): 1466 failing setup endpoints, worst −12.289 ns.
  This is before placement; one net (`rptr_0`, fanout 1036) is estimated at
  13.050 ns. Routed, the same class of path has positive slack. Ignore for
  sign-off.

### Utilization (`reports/map.mrp`)

| Resource | Used | Available | |
|---|---|---|---|
| LUT4 | 4880 | 32256 | 15 % |
| – logic | 2097 | | |
| – distributed RAM | 1536 | | data FIFO, 256 × 64 |
| – ripple (carry) | 484 | | |
| – virtual-I/O feed-through | 763 | | flow artifact, not design logic |
| Registers | 816 | 32811 | 2 % |
| EBR (block RAM) | 0 | 84 | 0 % |
| Large RAM | 0 | 2 | |
| DSP | 0 | | |
| PIO | 1 used + 7 reserved | 185 | |

Excluding the 763 feed-through LUTs that exist only to model virtual I/O, the
design itself uses 4117 LUT4 (4880 − 763).

The FIFO is in distributed RAM, not EBR, because `dma_fifo.sv` reads the memory
asynchronously (show-ahead); EBR needs a registered read. Moving it to EBR
would save about 1536 LUT4 but needs an RTL change to the FIFO read path, which
I did not make.

## Warnings

No errors or critical warnings in any stage.

| Stage | Notes | Warnings | Source |
|---|---|---|---|
| Synthesis (Synplify) | 335 | 24 | `synthesis.srr` (lines starting `@N`, `@W`) |
| Map | – | 273 | `map.mrp` |
| PAR | – | 136 | `par.par` |

### Synthesis warnings (24)

| ID | Count | Message | Assessment |
|---|---|---|---|
| CL190 / CL279 | 5 / 1 | `err_code[7:3]` optimized to constant 0 and pruned (`dma_engine_core.sv:228`) | Benign. The defined error codes are 0x00 to 0x06 (`dma_pkg.sv`), so only 3 bits are ever non-zero. |
| BN132 | 4 | Equivalent registers merged: `wstate[0]`≡`w_write_q`, `w_burstcount_q`≡`w_blen`, `r_burstcount_q`≡`r_blen`, `f_start`≡`estate[1]` | Benign area optimization. |
| CL169 / CL271 | 1 / 2 | Unused descriptor bits pruned in `dma_descriptor_fetch.sv:128` (`beats[3]`, upper bits of `beats[2]`, `beats[1]`) | Benign. Reserved descriptor bytes 24–31 and the unused upper sys-address/control bits. |
| CL247 | 2 | `axi_bresp[0]`, `axi_rresp[0]` unused (`gmm_to_axi4.sv`) | Benign and intended: the adapter tests bit 1 only (SLVERR/DECERR). |
| CL246 | 1 | `length[2:0]` unused in `dma_data_mover.sv` | Benign: the engine rejects lengths that are not a multiple of 8 bytes before the mover runs (`ERR_BAD_LEN` in `dma_pkg.sv`). |
| CS141 | 2 | "Unrecognized synthesis directive hint" (`reset_sync.sv:28`) | Cosmetic. The comment on that line starts with the words "Synthesis hint", which Synplify parses as a `// synthesis <directive>` pragma. Nothing is affected. The `altera_attribute` on the next line is ignored on Lattice. |
| FX107 | 1 | FIFO RAM has no read/write conflict check | **Worth a look, judged safe.** The FIFO never reads the address being written unless it is empty or full, and both cases are gated by `empty` / `full`. |
| MT447 | 1 | `set_false_path -from rst_n` not applied, no such paths | Expected. Synplify does not time the asynchronous reset pin. See note below. |
| MT444 | 1 | port→port `set_max_delay 6.0` not applied, no such paths | Informative: there is no combinational input-to-output path in the AXI4 build. Constraint kept for the other configurations. |
| MF511 | 1 | "Found issues with constraints" | Summary line for MT447/MT444. |
| BW295 | 1 | Clock not forward-annotated to input pins | Tool housekeeping; `create_clock` reaches Radiant (listed in `timing_par.twr` §1.1). |
| FX310 | 1 | `-dcc_insertion` ignored | Tool default option not applicable to this device. |

Real issues needing an RTL fix: none.

### Map warnings (273) and PAR warnings (136)

- **71003020 "Top module port … does not connect to anything"** – 272 in map
  (136 ports, each reported twice) and 136 in PAR. These are the inputs of the
  SYS buses not selected by `SYS_IF="AXI4"` (`avm_readdata[63:0]`,
  `avm_readdatavalid`, `avm_waitrequest`, `hrdata[63:0]`, `hready`, `hresp`)
  plus the four unused AXI bits (`axi_bid`, `axi_rid`, `axi_bresp[0]`,
  `axi_rresp[0]`). Expected by design: all three bus port groups are always
  present on the module.
- **52281049** (1, map) – virtual I/O ignored on `clk` because it drives a
  clock. Expected.

## I/O constraints and the one deviation from the Quartus SDC

`quartus/pcie_dma.sdc` gives every data/control port a 1 ns budget with
`set_input_delay` / `set_output_delay`. `lattice/pcie_dma.sdc` applies the same
1 ns budget as `set_max_delay -datapath_only` (7 ns port↔register, 6 ns
port→port) instead. This is a deliberate change; here is why and what the
literal version gives.

The ports are virtual (no pad, no location, zero delay), but `clk` comes in
through a real pad and the global clock tree: 2.104 ns of latency at the hold
corner and 4.098 ns at the slow setup corner (`timing_par.twr` /
`iodelay/timing_par.twr` clock paths). With `set_input_delay` /
`set_output_delay` the port side of each path is referenced to the ideal clock
edge and the register side to the delayed clock, so the clock-tree latency is
charged in full against every output path and appears as a hold violation on
every input path.

Literal version, `pcie_dma_iodelay.sdc` → `reports/iodelay/timing_par.twr`:

| Check | Worst slack | Failing endpoints | Worst path |
|---|---|---|---|
| Setup, 85 °C | −2.056 ns | 206 | `u_fifo/rptr` → `host_writedata[26]` |
| Setup, 0 °C | (9.949 ns actual) | 204 | |
| Hold | −1.048 ns | 1489 | input port → first register, e.g. `host_readdata[37]` → `u_fetch/beats_0_[37]` |

So **with the constraints ported literally, this standalone build does not
meet 125 MHz on the port paths** (Radiant reports 10.056 ns / 99.443 MHz). I
judge that to be an artifact of the standalone virtual-I/O model rather than a
property of the core: once integrated, the logic on the other side of each port
sits on the same clock tree and that skew disappears. The same output path
that fails by 2.056 ns here has 5.714 ns of real datapath delay
(`timing_par.twr`, path to `host_writedata[21]`). Please treat this as my
assessment, not a tool result: if the core will be used with a clock relationship
where the port-side logic really is ahead of the clock tree, the literal numbers
are the relevant ones.

Other constraint notes:

- `set_false_path -from [get_ports rst_n]` is in the SDC, but Synplify drops it
  (MT447) and it does not appear in Radiant's constraint list. The effect is
  the same: `rst_n` → the two `reset_sync` flops' async reset pins are the only
  unconstrained endpoints in `timing_par.twr` (2, "No arrival time"), i.e. not
  timed.
- 133 I/O ports are listed "without constraint" in `timing_par.twr`: `rst_n`
  and the unused Avalon/AHB ports, which have no logic behind them in this
  build.
- Radiant rejects `set_max_delay -to <ports> -datapath_only` without a `-from`;
  the register→port constraint therefore uses `-from [get_clocks clk]`.

## Simulation (QuestaSim)

`scripts/run_questa.sh`, pass criterion identical to `scripts/run_sim.sh` (log
contains `=== PASS`).

| Configuration | Defines | Seed 1 | Seed 2 | Seed 3 |
|---|---|---|---|---|
| AXI4 | `USE_AXI` | PASS | PASS | PASS |
| AXI4_STALLS | `USE_AXI STALLS` | PASS | PASS | PASS |
| AXI4_RSTSYNC (extra) | `USE_AXI RESET_SYNC_EN` | PASS | PASS | PASS |
| AXI4_STALLS_RSTSYNC (extra) | `USE_AXI STALLS RESET_SYNC_EN` | PASS | PASS | PASS |

The first two rows are the requested regression. The testbench instantiates
`RESET_SYNC=0` unless `RESET_SYNC_EN` is defined, so I added the two extra rows
to simulate the parameter set that is actually synthesized (`RESET_SYNC=1`).
All logs end with `Errors: 0, Warnings: 0`.

One simulator accommodation, no source change: `vsim` is run with
`-suppress 7061`. The testbench preloads the memory models by hierarchical
reference (`host_mem.mem[..] = ...`) while the models write the same array
from an `always_ff`; Questa treats that as a suppressible error (vopt-7061,
5 occurrences, shown as "Suppressed Errors: 5" in the seed-1 logs), Icarus does
not check it. It affects testbench/model code only, not the RTL.

This is RTL simulation. No gate-level or timing simulation of the Radiant
netlist was run.

## RTL changes

None. `rtl/` is untouched. Candidates I left alone, for a maintainer to decide:

1. `reset_sync.sv:28` – reword the comment so it does not start with
   "Synthesis" (removes CS141).
2. `dma_fifo.sv` – registered read to allow EBR inference (saves ~1536 LUT4,
   changes FIFO timing, needs re-verification).

## Not done

- No bitstream (no pinout; not requested).
- Fmax not confirmed by a run at a tighter period.
- Only `SYS_IF="AXI4"` was implemented; Avalon and AHB builds were not run.
