## Judge verdict: plain-lattice / fpga-scope  (PR #29, branch `plain-lattice/fpga-scope` @ 18ad0c6)

Lattice leg, plain arm (no plugin, no MCP). Judged from committed artifacts only; the three builds and the full Questa suite re-run from a clean checkout (`results/judge/plain-lattice-fpga-scope/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe fpga/lattice/build.tcl 32 {8,12,15}`: exit 0 each; every report reproduced, worst setup slack +2.209 / +2.142 / +1.420 ns (identical to committed) |
| G2 warnings reported truthfully | **PASS** | README: Synplify 11 / 13 / 16, map 28, PAR 14, 0 errors; matches the report files |
| G3 synth + impl reports committed | **PASS** | per config: `synthesis.srr`, `synthesis_resources.rpt`, `map.mrp`, `par.par`, `pad.pad`, `timing_par.twr` |
| G4 timing met at 100 MHz | **PASS** | 0 setup / 0 hold failing endpoints in all three configs; Fmax 128.4 / 127.3 / 116.6 MHz. Same caveat as the other Lattice fpga-scope cell and stated in the README: only `clk` is constrained (coverage 85–88 %), the combinational AXI input paths are untimed. |
| G5 Questa regression | **PASS** | re-run of the **whole 17-testbench suite** (`bash sim/run_questa.sh`): 16 passed on the first pass; `tb_prim_ram` failed with `License checkout has been disallowed … nodelocked license` because another judge re-run held the Questa seat at that second. Re-run alone: PASS, 17/17. Environmental, not a defect of the branch. |
| G6 no silent core-RTL change | **PASS** | `scope_top.sv` declaration order only; declaration moves in five testbenches; new `tb_axil_top`; `.gitattributes` to keep the bash runner LF. No Verilator re-run (WSL has it; not checked). |
| G7 README numbers match reports | **PASS** | LUT4 1909 / 2030 / 2120, regs 1198 / 1228 / 1251, EBR 2 / 10 / 67, slack, Fmax, hold, warning counts, 17/17 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **2** | Clean `s_axi_*` top; per-config `build.tcl` with scratch project; EBR mapping proven (`PDPSC16K`, 1 / 9 / 66 blocks). Minus one for the single-line SDC with no port budgets. |
| S2 warning triage | **3** | Per-stage, per-config counts; `FX107` collision warning singled out with an honest "not verified on hardware". |
| S3 README usefulness | **3** | Utilization/EBR/timing/hold per config, coverage caveat, not-like-for-like note, a bash runner that mirrors `run.sh` exactly. |
| S4 efficiency | **3** | 54 turns, $2.94, **13.1 min** while porting the **entire** 17-testbench suite to Questa (the brief asked for three). |
| S5 recovery | **3** | Declare-before-use failures across six files fixed minimally; CRLF handled with `.gitattributes`. |

**Total: 14/15, all gates pass.**

### Notes
- Used `ToolSearch` to load the `Monitor` tool (allowed; the harness only disallows `ScheduleWakeup`) and still finished the run normally.
- Within 0.1 % of lattice/fpga-scope on every number, at the same cost, in less time, with 13 more testbenches ported.
- Cost/turn/tool data: `results/plain-lattice/fpga-scope/summary-20261009-165217.md`.
