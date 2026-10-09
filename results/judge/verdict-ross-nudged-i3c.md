## Judge verdict: ross-nudged / i3c  (branch `ross-nudged/i3c` @ ee0edd0)

Third arm: identical prompt plus `harness/prompts/_nudge.md` (use the Vivado MCP for every step, invoke the Ross skills, use doc-search). Judged from committed artifacts only; build and xsim re-run from a clean checkout (`results/judge/ross-nudged-i3c/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `vivado -mode batch -source syn/xilinx/build.tcl`: exit 0 in 116 s; reports reproduced. The agent had only ever `source`d the script inside its MCP session and said so; it still runs standalone. |
| G2 lint reported truthfully | **PASS** | README: 52 warnings (32 ASSIGN-10 + 20 ASSIGN-6); `lint.rpt` re-run identical. Also committed `lint.csv` from the Ross skill's parser and labelled it as such. |
| G3 synth + impl reports committed | **PASS** | utilization (+hier, +synth), timing_summary, timing_split, drc, methodology, route_status |
| G4 WNS ≥ 0 at 125 MHz | **PASS** | WNS +0.969 ns, TNS 0. Hold fails on 115 input-port endpoints (WHS −0.984); README gives the mechanism with the actual path numbers (0.3 + 0.924 ns data vs 1.816 ns clock) and says it did not tune the budget. |
| G5 xsim regression | **PASS** | `vivado -mode batch -source sim/run_xsim.tcl`: `XSIM PASS (xilinx IO cell): 29 passed, 0 failed` in 12 s |
| G6 no silent core-RTL change | **PASS** | one change, `i3c_target_top.sv`: pad cell behind `I3C_IO_CELL` macro defaulting to `i3c_io_altera`. Cross-checked the **unchanged default configuration** under xsim (29/29, `sim/xsim_altera_io.log` committed) via an `I3C_SIM_IO=altera` switch in the runner. |
| G7 README numbers match reports | **PASS** | WNS/WHS/115 endpoints, 497 LUT / 341 FF / 0 BRAM / 2 IOB, lint 52, 29/29 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | `IOBUF` + `IBUF`, `HD.CLK_SRC`, and — uniquely among the i3c cells — the IOBUF-inside-OOC-module decision is backed by a **UG905 citation obtained from amd-doc-search** and quoted in the README. Times `rst_n` as a synchronous input instead of copying the SDC's false path, with the RTL evidence for why. Adds a placeholder `IOSTANDARD`. Did not build the inferred-tri-state variant and says so. |
| S2 lint triage | **3** | Same 52 items triaged; additionally spotted that `AVL_ASYNC=1` would clock the Avalon bridge across single-clock FIFOs with no CDC — a real latent bug neither other i3c cell reported. |
| S3 README usefulness | **3** | Per-class timing table, the hold mechanism with numbers, DRC table, cited documentation, explicit list of what was not re-run. |
| S4 efficiency | **2** | 54 turns, $3.08, **10.0 min wall** (fastest i3c cell), 19 MCP calls, 0 shell Vivado launches. Costlier than plain/i3c ($1.93) and ross/i3c ($2.08); the extra turns are skill invocations and MCP round-trips. |
| S5 recovery | **3** | Handled the lint path bug; Icarus 11 failure handled with a committed xsim cross-check of the untouched configuration. |

**Total: 14/15, all gates pass.**

### Ross-tooling observations (the point of this arm)
- **Vivado MCP: 19 calls** (`vivado_start` ×1, `vivado_execute` ×18), one session reused throughout, no hangs. **0 shell launches** of vivado/xsim (verified in the transcript).
- **amd-doc-search: 1 call**, and the UG905 passage it returned is quoted and used correctly in both the README and the shim header.
- **Skills: 3** — `vivado-rtl-lint` (produced `lint.csv` via its parser), `vivado-timing-methodology-checks` (a `report_methodology` run, 0 findings), `vivado-simulate-rtl`.
- Net effect vs ross/i3c (discovery arm, 13/15): +1 point, better-cited design decisions, one more real finding, 30 % less wall time, 50 % more cost.

### Notes
- Cost/turn/tool data: `results/ross-nudged/i3c/summary-20261009-160344.md`.
