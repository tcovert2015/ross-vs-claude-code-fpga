## Judge verdict: ross / dma  (branch `ross/dma` @ 89708d7)

Judged from committed artifacts only; the 125 MHz default flow and the xsim sweep were re-run from a clean checkout (`harness/judge_rerun.ps1`, logs in `results/judge/ross-dma/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `vivado/run_build.ps1` re-run: exit 0 in 125 s, `BUILD_SUMMARY flow=default period=8.000 ns WNS=-1.019 ns WHS=0.034 ns` |
| G2 lint reported truthfully | **PASS** | README: 12 linter-rule findings (10 ASSIGN-10 + 2 ASSIGN-6) in `lint.rpt` plus 65 elaboration messages counted from the log = 77; `lint.rpt` re-run identical |
| G3 synth + impl reports committed | **PASS** | full report set for 4 runs: `reports/` (8.0 ns), `explore/`, `p9_000/`, `p9_250/` |
| G4 WNS ≥ 0 at 125 MHz **or honest, specific explanation** | **PASS (timing not met)** | WNS **−1.019 ns**, TNS −18.5, 55/5248 endpoints. README names the critical path (`w_addr_reg` → burst sizing `beats_to_boundary`/`min3` → write-FSM CE, 12 levels, 5 CARRY4), shows directives recover only 0.074 ns, demonstrates closure at 9.25 ns (+0.047) and that the 9.0 ns extrapolation does *not* close (−0.334). Declines to pipeline core RTL and says why. This is the honest explanation the gate asks for. |
| G5 xsim regression | **PASS** | re-run: AXI4 seeds 1-3 PASS, AXI4+STALLS seeds 1-3 PASS (6/6) |
| G6 no silent core-RTL change | **PASS** | `rtl/` untouched. One testbench line: `void'($urandom(seed))` → `rng_discard = $urandom(seed)` because xsim rejects the void cast (XSIM 43-3122); same call, documented. `ASYNC_REG` applied from the XDC instead of editing `reset_sync.sv` — good vendor-neutral discipline. |
| G7 README numbers match reports | **PASS, one disclosed exception** | spot-checked WNS/TNS/endpoints for all four runs, 1373 LUT (1029 + 344 LUTRAM) / 825 FF / 0 BRAM, lint 12+65, 6/6 — all match and all reproduced on re-run. The README quotes WHS −0.343 / 204 hold endpoints from an earlier min=max I/O-delay run whose reports were overwritten; it says so explicitly. |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | XDC mirrors the SDC line by line with a translation table; `HD.CLK_SRC` for OOC clock modeling; `ASYNC_REG` via XDC. Setup-only I/O delays is a judgement call, but it is argued (port-referenced launch vs 1.8 ns insertion delay) and its consequences in `check_timing`/`methodology` are listed rather than hidden. `build.tcl` is parameterised for period/tag/directive sweeps with reports per tag so the 125 MHz results are never overwritten. |
| S2 lint triage | **3** | Every item classified with a reason; `Synth 8-7137` (async-reset block without a reset branch → reset folded into CE) correctly called real-but-benign with the clean fix named. |
| S3 README usefulness | **3** | Headline states the failure up front. Timing table across four runs, critical path with file:line, Fmax stated conservatively (demonstrated 9.25 ns, not the extrapolated 9.02), utilization by hierarchy, explicit "not done" list. |
| S4 efficiency | **2** | 39 turns, $2.15, 16.5 min, 29 Vivado/xsim shell launches including four full implementation runs. The sweep was purposeful, but a 9.0–9.25 ns bisection was left undone after spending the runs. |
| S5 recovery | **3** | Diagnosed the xsim `void'` incompatibility and made the minimal portable fix; handled the space-in-path bug; worked around the repo-root `build/` ignore rule with `git add -f` and said so. |

**Total: 14/15, all gates pass (G4 via honest explanation).**

### Ross-specific observations
- **Vivado MCP server: 0 calls** (connected and advertised; never used). **amd-doc-search: 0 calls. Skills: 0.**
- Every Vivado launch went through `vivado.bat` from `Bash`/`PowerShell`, i.e. the Ross arm behaved as plain Claude Code on this cell.

### Notes
- Shared confound: space in the worktree path; this agent worked around it by running from `vivado/build/` with relative paths.
- Cost/turn/tool data: `results/ross/dma/summary-20261008-210558.md`.
