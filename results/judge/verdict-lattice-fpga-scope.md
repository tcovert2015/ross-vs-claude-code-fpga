## Judge verdict: lattice / fpga-scope  (PR #28, branch `lattice/fpga-scope` @ c364b94)

Lattice leg, tooling arm (Lattice Prompt skills plugin + `lattice-radiant-mcp` available). Judged from committed artifacts only; the three builds and the Questa regression re-run from a clean checkout (`results/judge/lattice-fpga-scope/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe fpga/lattice/build.tcl 32 {8,12,15}`: exit 0 each (~100 s); every report reproduced, worst setup slack on re-run: w32_d8=+1.828ns w32_d12=+2.303ns w32_d15=+1.412ns (committed +1.828 / +2.303 / +1.412) |
| G2 warnings reported truthfully | **PASS** | README: Synplify 11 / 13 / 16, map 28, PAR 14 per config, 0 errors; matches the `.srr`/`.mrp`/`.par` files |
| G3 synth + impl reports committed | **PASS** | per config: `synthesis.srr`, `map.mrp`, `par.par`, `timing.twr`, `console.txt`; plus a generated `reports/summary.md` (via a committed `summarize.py`) |
| G4 timing met at 100 MHz | **PASS** | 0 setup / 0 hold failing endpoints in all three configs; Fmax 122.4 / 129.9 / 116.4 MHz. **Caveat stated in the README:** only `clk` is constrained (coverage 85–88 %), so the AXI4-Lite input/output paths are not timed at all. Honest, but weaker than the Vivado-leg cells, which budgeted the ports. |
| G5 Questa regression | **PASS** | re-run: `tb_smoke`, `tb_csr`, `tb_csr_if`, `tb_axil_top` all `TB_RESULT: PASS` in 11 s |
| G6 no silent core-RTL change | **PASS** | `scope_top.sv` declaration order only (Questa enforces declare-before-use); testbench declaration moves; new `tb_axil_top`. No Verilator re-run (not installed on Windows; WSL has it, not checked). |
| G7 README numbers match reports | **PASS** | LUT4 1907 / 2030 / 2120, regs 1198 / 1228 / 1251, EBR 2 / 10 / 67, slack and Fmax per config, warning counts, 4/4 Questa — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **2** | Clean `s_axi_*` top; per-config `build.tcl` with scratch project; buffer-to-EBR mapping proven from the map report (`PDPSC16K`). Minus one: the SDC is a single `create_clock` line with no port budgets, so the combinational AXI request paths are untimed and the Fmax figures are register-to-register only. |
| S2 warning triage | **3** | Counts per stage and config; the `FX107` read/write-collision warning on the EBRs correctly singled out as the one to read, with an honest "not verified on hardware". |
| S3 README usefulness | **3** | Utilization/EBR/timing per config, coverage caveat up front, Agilex not-like-for-like note, generated summary table. |
| S4 efficiency | **2** | 49 turns, $2.89, 14.6 min, 7 shell invocations of radiantc/Questa. |
| S5 recovery | **3** | Declare-before-use failures diagnosed and fixed minimally; no detours. |

**Total: 13/15, all gates pass.**

### Lattice-tooling observations
- **lattice-radiant-mcp: 0 calls. Skills: 1** (`lattice-radiant-automation`, invoked once; the MCP tools it instructs the agent to load were never loaded). `lattice-radiant-webdocs`: never invoked.
- Numerically within 0.1 % of plain-lattice/fpga-scope (1907 vs 1909 LUT4 at N=8; identical elsewhere).

### Notes
- Cost/turn/tool data: `results/lattice/fpga-scope/summary-20261009-165047.md`.
