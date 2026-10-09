## Judge verdict: ross-nudged / fpga-scope  (PR #18, branch `ross-nudged/fpga-scope` @ ad057f0)

Third arm (Ross tooling explicitly required). Judged from committed artifacts only; the three builds and the xsim regression were re-run from a clean checkout with the batch command lines the agent never ran itself (`results/judge/ross-nudged-fpga-scope/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `vivado -mode batch -source fpga/xilinx/build.tcl -tclargs 32 {8,12,15}`: exit 0 in 145 / 131 / 135 s; every number reproduced |
| G2 lint reported truthfully | **PASS** | README: 6 warnings (5 ASSIGN-6 + 1 ASSIGN-1) with locations; `lint.rpt` re-run identical in all three configs |
| G3 synth + impl reports committed | **PASS** | per config: lint, utilization (+hier, +synth), ram_utilization, timing_summary, methodology, drc, summary.txt. Plus `reports/vivado_mcp_session.log`: the full 7,282-line transcript of the MCP session that produced them, including the failed first attempts |
| G4 WNS ≥ 0 at 100 MHz | **PASS** | (32,8) +0.726, (32,12) +0.288, (32,15) +0.581 ns, TNS 0, hold met. Closed by the same vendor-neutral `scope_csr.sv` fix the plain arm found (first build −0.333 ns, visible in the committed session log), under a 3 ns symmetric port budget stated as an assumption. |
| G5 xsim regression | **PASS** | `vivado -mode batch -source sim/run_xsim.tcl`: tb_smoke, tb_csr, tb_csr_if, tb_axil_top all `TB_RESULT: PASS`, `ALL XSIM TESTBENCHES PASSED` in 27 s |
| G6 no silent core-RTL change | **PASS** | `scope_csr.sv` lane-mask constant folding (same intent as plain's, implemented as a constant 16:1 mux) and `scope_top.sv` declaration order; both justified in README. Testbench loop rewrite for the xsim defect. Verified only by the four xsim testbenches; README says Verilator "not installed", but Verilator 5.020 is in WSL (same miss as ross/fpga-scope). |
| G7 README numbers match reports | **PASS** | WNS/TNS/WHS, LUT/FF, RAMB36/RAMB18 for all three configs, lint 6, 4/4 xsim — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | Clean wrapper with `X_INTERFACE_*` attributes, `HD.CLK_SRC`, `report_ram_utilization` to prove BRAM mapping, `report_methodology` included, per-config `summary.txt`. The RTL timing fix is real (not a budget relaxation). IP Integrator inference not exercised. |
| S2 lint triage | **3** | All 6 items explained with file:line against the repo's `unused` idiom. |
| S3 README usefulness | **3** | Utilization/BRAM/timing tables per config, cites UG901/UG903 from amd-doc-search where they informed the OOC flow and says plainly where doc-search returned nothing useful. Commits the MCP session transcript as evidence. |
| S4 efficiency | **2** | 99 turns, $5.44, **29 min wall** (half of ross/fpga-scope, 45 % less than plain), 27 MCP calls, 0 shell Vivado launches, 0 process kills. |
| S5 recovery | **3** | Diagnosed the lint path bug and the xsim `do…while` cast defect; recovered the −0.333 ns timing failure with an RTL fix rather than a constraint change. |

**Total: 14/15, all gates pass** (equal to plain/fpga-scope; +3 over ross/fpga-scope).

### Ross-tooling observations
- **Vivado MCP: 27 calls** (`vivado_start` 1, `vivado_execute` 23, `vivado_status`/`vivado_history`/`vivado_log_messages` 1 each); one session reused for all three builds and the regression; no hangs, no kills.
- **amd-doc-search: 4 calls**; two produced citations used in the README, two returned nothing useful (HD.CLK_SRC, the xsim loop bug) and the README says so.
- **Skills: 3** (`vivado-rtl-lint`, `vivado-timing-methodology-checks`, `vivado-simulate-rtl`).
- Left its Vivado session open at the end (judge closed it); the README notes it.

### Notes
- Cost/turn/tool data: `results/ross-nudged/fpga-scope/summary-20261009-160344.md`.
