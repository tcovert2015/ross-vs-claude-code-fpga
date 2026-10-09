## Judge verdict: plain / i3c  (PR #8, branch `plain/i3c` @ 384a411)

Judged from committed artifacts only; flow and xsim re-run from a clean checkout (`harness/judge_rerun.ps1`, logs in `results/judge/plain-i3c/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `build.tcl` re-run: exit 0 in 89 s, `RESULT: WNS=1.147 ns WHS=-0.202 ns` |
| G2 lint reported truthfully | **PASS** | README says 52 warnings (32 ASSIGN-10 + 20 ASSIGN-6); `lint.rpt` re-run identical |
| G3 synth + impl reports committed | **PASS** | utilization, timing_summary, drc, methodology, route_status, timing_split |
| G4 WNS ≥ 0 at 125 MHz | **PASS** | WNS +1.147 ns, TNS 0. Hold fails on 42 input-port endpoints (WHS −0.202); README explains the OOC port-hold artifact specifically and does not mask it |
| G5 xsim regression | **PASS** | re-run: `RESULT: 29 passed, 0 failed`, `XSIM REGRESSION PASSED` |
| G6 no silent core-RTL change | **PASS** | one change, `i3c_target_top.sv`: pad cell behind `I3C_IO_CELL` macro defaulting to `i3c_io_altera`; justified in README; default behaviour unchanged |
| G7 README numbers match reports | **PASS** | spot-checked WNS/WHS/failing endpoints, 496 LUT / 341 FF / 0 BRAM / 2 IOB, lint 52, 29/29 — all match; re-run reproduced every number to the digit |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | `IOBUF` (SDA) + `IBUF` (SCL). Tried inferred tri-state first, caught Vivado converting it to logic in OOC (`Synth 8-5799`), kept the netlist probe as evidence in `reports/trial_inferred_tristate/`. XDC is a faithful SDC translation. Minor: `read_xdc` without `-mode out_of_context`; `phys_opt_design` included. |
| S2 lint triage | **3** | All 52 classified; separates real feature gaps (CTRL[4]/[5], IBI_CTRL[15] drive nothing, `txf_overflow` unconnected) from FORMAL taps and uniform-interface strobes, with file:line refs. |
| S3 README usefulness | **3** | Per-path-class timing table, honest hold discussion with the mechanism (0.973 ns est. clock delay vs 0.3 ns placeholder input delay), DRC table, next-steps for a real board. An engineer could reuse it as-is. |
| S4 efficiency | **3** | 33 turns, $1.93, 14.2 min wall, 14 Vivado/xsim shell launches, 2 commits. |
| S5 recovery | **3** | Hit the Vivado space-in-path bug, switched to `cd`+relative paths. Icarus 11 could not parse the package; ran the default Altera-shim config under xsim as a scratch check instead and said so. |

**Total: 15/15, all gates pass.**

### Notes
- Confound shared with every cell: the worktree path `D:\AMD Ross Test\...` contains a space, which breaks `synth_design -lint -file` and `read_verilog` with absolute paths in Vivado 2025.2. Both arms hit it on this design and both recovered the same way.
- Cost/turn/tool data: `results/plain/i3c/summary-20261008-210558.md`.
