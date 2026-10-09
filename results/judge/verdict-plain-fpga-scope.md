## Judge verdict: plain / fpga-scope  (PR #12, branch `plain/fpga-scope` @ 7e1fc69)

Judged from committed artifacts only; the three-config flow and the xsim regression were re-run from a clean checkout (`harness/judge_rerun.ps1`, logs in `results/judge/plain-fpga-scope/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `fpga/xilinx/run_all.ps1` re-run: (32,8) and (32,12) PASS in 109 s; (32,15) was killed mid-DRC by a machine-wide `taskkill /F /IM vivado.exe` issued by the *ross/fpga-scope* agent at 22:16:06 (see that cell's verdict), re-run alone: `PASS pw32_d15 ramb36=33 ramb18=1 lutram=0 wns_ns=0.906`. All reports regenerated with identical numbers. |
| G2 lint reported truthfully | **PASS** | README: 6 warnings (5 ASSIGN-6 + 1 ASSIGN-1), each with location and reason; `lint.rpt` re-run identical for all three configs |
| G3 synth + impl reports committed | **PASS** | per config: lint, utilization (+hier, +synth), timing_summary, drc, ram, route_status, summary.txt, vivado.log; plus `_baseline/` for the pre-change RTL and `ipi_check.log` |
| G4 WNS ≥ 0 at 100 MHz | **PASS** | (32,8) +0.791, (32,12) +0.603, (32,15) +0.906 ns, TNS 0 in all three; hold met internally (port hold excluded with a stated rationale). The baseline RTL *failed* (32,8) at −0.211 ns; the agent kept those reports and fixed it in RTL rather than hiding it. |
| G5 xsim regression | **PASS** | re-run: `tb_smoke`, `tb_csr`, `tb_csr_if`, and the new `tb_axil_top` all `TB_RESULT: PASS`, `ALL XSIM TESTBENCHES PASSED` |
| G6 no silent core-RTL change | **PASS, two core changes, both justified** | `rtl/scope_csr.sv`: comparator lane write-mask computed from a constant table instead of runtime arithmetic on the address (closes timing; same function, same predicate, register map unchanged; A/B reports in `_baseline/`). `rtl/scope_top.sv`: four wire declarations moved above first use (IEEE 1800 order; xvlog rejects the original). Testbenches: declaration-order fixes and two poll loops rewritten around an isolated xsim defect (`sim/xsim_repro_loop_cast.sv`). Verified by the repo's own Verilator regression under WSL: 17/17 with `-Wall` (`sim/verilator_run.log`, confirmed in the transcript). Formal proofs not re-run (no `sby`), and the README says so. |
| G7 README numbers match reports | **PASS** | spot-checked WNS/TNS/WHS, LUT/FF, RAMB36/RAMB18 for all three configs and the three baselines, lint 6, 4/4 xsim, 17/17 Verilator — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | `scope_axil_top.sv` is a zero-logic wrapper with `X_INTERFACE_*` attributes; the agent actually tested IP Integrator inference (`check_ipi.tcl`, `IPI_CHECK: PASS`) and found IPI will not take a SystemVerilog top, so added a Verilog shim. XDC with 2 ns port budgets and a reasoned port-hold exception. `report_ram_utilization` used to prove BRAM mapping. Parallel 3-config runner with a targeted retry for the Vivado `.Xil` lock. |
| S2 lint triage | **3** | All 6 items explained against the repo's own `unused` idiom; separately triages the 122–135 synthesis warnings by ID and calls out the two real issues the linter missed (declaration order, deep CSR decode). |
| S3 README usefulness | **3** | Utilization table mirrors the Agilex table and warns the LUT/ALM comparison is apples-to-oranges; BRAM mapping per config from `ram.rpt`; before/after timing table for the RTL change; IPI integration notes; tool-quirk section. The xsim loop defect is isolated in a 56-line reproducer other users can file. |
| S4 efficiency | **2** | 83 turns, $5.86, 52 min, 37 Vivado/xsim launches. The most expensive cell of the six, but little of it was waste: the spend bought a timing fix with A/B evidence, an IPI check, a new end-to-end testbench and a full Verilator cross-check. |
| S5 recovery | **3** | Diagnosed the lint path bug the same way as the others; isolated an xsim simulator defect with a minimal reproducer instead of hacking around it; handled CRLF for WSL; retried the transient Vivado lock. |

**Total: 14/15, all gates pass.**

### Notes
- Judge re-run interference: the (32,15) failure on the first judge pass was caused by the ross/fpga-scope agent killing every `vivado.exe` on the machine; it is not a defect of this branch.
- Shared confound: space in the worktree path.
- Cost/turn/tool data: `results/plain/fpga-scope/summary-20261008-212058.md`.
