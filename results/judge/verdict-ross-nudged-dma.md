## Judge verdict: ross-nudged / dma  (PR #31, branch `ross-nudged/dma` @ 144d188)

Third arm (Ross tooling explicitly required). Judged from committed artifacts only; flow and xsim re-run from a clean checkout in the batch form the agent never executed itself (`results/judge/ross-nudged-dma/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `vivado -mode batch -source vivado/build.tcl`: exit 0; WNS −0.456 / TNS −4.546 / 10 endpoints / WHS +0.080 reproduced to the digit, 1333 LUT / 831 FF identical |
| G2 lint reported truthfully | **PASS** | README: 12 warnings (10 ASSIGN-10 + 2 ASSIGN-6), 0 errors; `lint.rpt` re-run identical; `lint.csv` from the skill parser labelled as such |
| G3 synth + impl reports committed | **PASS** | full set for 8.000 ns plus `period_8.500/` and `period_9.000/`; checkpoints correctly left untracked |
| G4 WNS ≥ 0 at 125 MHz **or honest, specific explanation** | **PASS (timing not met)** | WNS **−0.456 ns** with `PerformanceOptimized` + `-retiming` synthesis and Explore-class implementation, the **best 125 MHz result of the four Vivado dma cells** (others −1.02 to −1.04). Names the reg-to-reg burst-sizing path (12 levels), shows 8.5 ns still fails (−0.306) and 9.0 ns closes (+0.024), states 111 MHz as demonstrated Fmax, declines to pipeline core RTL and says why. |
| G5 xsim regression | **PASS** | `vivado -mode batch -source scripts/run_xsim.tcl`: AXI4 and AXI4+STALLS seeds 1–3, 6/6 PASS |
| G6 no silent core-RTL change | **PASS** | `rtl/` untouched; one testbench line (`void'($urandom)` → assignment to a dedicated sink), documented. `ASYNC_REG` via XDC. |
| G7 README numbers match reports | **PASS** | all timing rows, utilization, lint counts, 6/6 match and reproduced; the two figures from an overwritten I/O-constraint trial are flagged as uncommitted in the README |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | XDC derives the port budgets from `$clk_period` so the period sweep stays consistent; `HD.CLK_SRC`; datapath-only port budgets (same conclusion as the Lattice cells reached independently) with the literal form's 204 false hold violations explained; `build.tcl` guards against the lint black-box failure and writes a `summary.txt`. High-effort directives are deliberate and documented, including the deprecated `-retiming`. |
| S2 lint triage | **3** | All 12 classified; unselected buses, single-ID AXI, reserved descriptor bits. |
| S3 README usefulness | **3** | Leads with the failure; sweep table; names the fix not made; honest about the crash, the removed post-route `phys_opt`, and the uncommitted trial figures. |
| S4 efficiency | **1** | 100 turns, $5.29, **75 min** (longest dma cell; plain/dma 46 min, ross/dma 17 min). ~10 min lost to the Vivado crash and session restart; the rest to high-effort builds at three periods. |
| S5 recovery | **3** | Vivado died with an access violation inside post-route `phys_opt_design` (MCP proxy log, 16:53:28); the agent inspected the log, dropped that step, started a new session with `vivado_start` and regenerated every report. No process killing. |

**Total: 13/15, all gates pass (G4 via honest explanation).**

### Ross-tooling observations
- **Vivado MCP: 31 calls** (`vivado_start` 2, `vivado_execute` 26, `vivado_status` 3) across two sessions; **0 shell launches** of Vivado. **amd-doc-search: 3. Skills: 3.**
- The crash recovery is the clearest MCP benefit seen in the whole benchmark: the proxy recorded the crash the same second, and the agent resumed with one tool call instead of hunting and killing processes (compare ross/fpga-scope).

### Notes
- Cost/turn/tool data: `results/ross-nudged/dma/summary-20261009-160344.md`.
