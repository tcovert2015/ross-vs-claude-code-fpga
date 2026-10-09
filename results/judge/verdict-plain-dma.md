## Judge verdict: plain / dma  (PR #11, branch `plain/dma` @ b9e6eef)

Judged from committed artifacts only; the 125 MHz default flow and the xsim sweep were re-run from a clean checkout (`harness/judge_rerun.ps1`, logs in `results/judge/plain-dma/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `vivado\build.bat` re-run: exit 0 in 118 s, `BUILD_RESULT period=8.000 WNS=-1.035 WHS=0.126 achieved_period=9.035`. Re-run reports are byte-identical to the committed ones (git shows no modified report files). |
| G2 lint reported truthfully | **PASS** | README: 12 warnings (10 ASSIGN-10 + 2 ASSIGN-6), each listed with file:line and assessment; `lint.rpt` re-run identical. Also counts 17 `Synth 8-7137` from the log, verified. |
| G3 synth + impl reports committed | **PASS** | full report set for 9 runs: default, `explore`, `end`, `end_explore`, `spread` (all 8 ns) and `p9p00/25/50/75` |
| G4 WNS ≥ 0 at 125 MHz **or honest, specific explanation** | **PASS (timing not met)** | WNS **−1.035 ns**, TNS −13.0, 19/5248 endpoints; hold met (+0.126) with the full min/max 1 ns I/O budget. README names the critical path (`w_rem_reg[31]` → burst sizing → `w_burstcount_q/CE`, 13 levels, 61 % routing), shows five directive strategies fail (best −0.825), runs four relaxed periods and reports the non-monotonic result (9.25 closes, 9.5 fails) honestly, recommending ~100 MHz as the safe figure. Names the RTL change that would close it and why it was not made. |
| G5 xsim regression | **PASS** | re-run: AXI4, AXI4_STALLS and the extra AXI4_RSTSYNC config, seeds 1-3, **9/9 PASS** |
| G6 no silent core-RTL change | **PASS** | `rtl/` untouched. One testbench line: `void'($urandom(seed))` → `gi = $urandom(seed)` for xsim (XSIM 43-3122); reuses an existing scratch variable and the README proves `gi` is overwritten by `csr_rd` before its only later use (line 700). `ASYNC_REG` via XDC, not RTL. |
| G7 README numbers match reports | **PASS** | spot-checked all nine runs' WNS/TNS/endpoints, 1345 LUT (1001 + 344 LUTRAM) / 825 FF / 0 BRAM, lint 12, 8-7137 ×17, 9/9 — all match and all reproduced. |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **3** | XDC mirrors the SDC one-for-one including min *and* max I/O delays (and hold still closes, so no deviation was needed). `ASYNC_REG` applied from the XDC with `-quiet` for the `RESET_SYNC=0` case. `build.tcl` takes key/value `-tclargs` (with the cmd.exe `=` pitfall explained), wraps paths in `[list]` so spaces survive, isolates scratch per tag so runs can go in parallel. The most reusable flow script of the six cells. |
| S2 lint triage | **3** | Every linter item with file:line and verdict, cross-referenced to the source's own Verilator waivers; notes the EXOKAY-treated-as-OKAY consequence of ignoring `bresp[0]`. Synthesis warnings triaged separately with the `Synth 8-7137` style issue correctly called real-but-not-functional. |
| S3 README usefulness | **3** | Headline failure up front; directive table; period sweep with the non-monotonic result explained rather than hidden; "what would close 125 MHz" with cost (one idle cycle per burst). Also simulated the `RESET_SYNC=1` parameterisation that is actually synthesised, which the prompt did not ask for but the ross cell flagged as a gap. |
| S4 efficiency | **2** | 67 turns, $3.14, 46 min wall, 37 Vivado/xsim shell launches, 9 full implementation runs. Thorough, but ~1.5× the cost and ~3× the wall time of ross/dma for the same gates. |
| S5 recovery | **3** | Hit and precisely diagnosed the lint `-file` space bug ("silently skips the report and corrupts the following synth_design"), added a guard; xsim `void'` fix minimal and justified; Icarus 11 limitation stated. |

**Total: 14/15, all gates pass (G4 via honest explanation).**

### Notes
- Shared confound: space in the worktree path. This agent's `[list]` wrapping is the cleanest of the workarounds seen.
- Cost/turn/tool data: `results/plain/dma/summary-20261008-210558.md`.
