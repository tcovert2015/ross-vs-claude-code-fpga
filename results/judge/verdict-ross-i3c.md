## Judge verdict: ross / i3c  (PR #9, branch `ross/i3c` @ 48ee4d6)

Judged from committed artifacts only; flow and xsim re-run from a clean checkout (`harness/judge_rerun.ps1`, logs in `results/judge/ross-i3c/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `build.tcl` re-run: exit 0 in 180 s, `BUILD DONE`, timing_split reproduced |
| G2 lint reported truthfully | **PASS** | README says 52 warnings (32 ASSIGN-10 + 20 ASSIGN-6); `lint.rpt` re-run identical |
| G3 synth + impl reports committed | **PASS** | utilization, timing_summary, drc, route_status, timing_split (no methodology report) |
| G4 WNS ≥ 0 at 125 MHz | **PASS** | WNS +0.786 ns, TNS 0. Hold fails on 93 input-port endpoints (WHS −0.984, THS −73.8); README attributes it specifically to `HD.CLK_SRC` clock insertion (1.816 ns) vs the 0.3 ns placeholder input delay, and says it was not tuned away |
| G5 xsim regression | **PASS** | re-run: `RESULT: 29 passed, 0 failed`, `ALL TESTS PASSED`, exit 0 |
| G6 no silent core-RTL change | **PASS** | one change, `i3c_target_top.sv`: pad cell behind `I3C_IO_MODULE` macro defaulting to `i3c_io_altera`; justified; default behaviour unchanged. Agent additionally re-ran the untouched Icarus regression under WSL (Icarus 12): 29/29 — verified in the transcript |
| G7 README numbers match reports | **PASS** | spot-checked WNS/WHS/93 endpoints, 496 LUT / 341 FF / 0 BRAM / 1 IOB, lint 52, 29/29 — all match; re-run reproduced every number to the digit |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Xilinx pieces | **2** | `IOBUF` on SDA, SCL left as a plain wire (1 bonded IOB; defensible, lets the integrator choose). `read_xdc -mode out_of_context` used correctly; `HD.CLK_SRC` added with a clear rationale. The inferred-tri-state rejection is argued from principle, not demonstrated as plain/i3c did. No `phys_opt_design`. |
| S2 lint triage | **3** | Same 52 findings, grouped by module; separates possible functional gaps (`txf_overflow`, dropped status outputs, no-effect control bits) from by-design items, with file:line refs. |
| S3 README usefulness | **3** | Per-path-class timing table, honest hold discussion, `check_timing` summary, DRC table, board next-steps. Documents the precise Vivado 2025.2 failure mode ("lint mode leaks into the next synth_design") which is genuinely useful. |
| S4 efficiency | **2** | 45 turns, $2.08, 14.7 min wall, 12 Vivado/xsim shell launches, 2 commits. More turns than plain for the same deliverable; some spent on a CRLF detour running `sim/run.sh` under WSL. |
| S5 recovery | **3** | Diagnosed the space-in-path bug precisely (lint report not written, lint mode persists), added a guard in `build.tcl`. Worked around Icarus 11 by using Icarus 12 in WSL, then fixed the CRLF problem. |

**Total: 13/15, all gates pass.**

### Ross-specific observations
- **Vivado MCP server: 0 calls.** `vivado_start`/`vivado_execute` were available and connected (43 tools in the init record) and the system prompt pointed at them; the agent shelled out to `vivado.bat` for every launch, exactly like the plain arm.
- **amd-doc-search: 0 calls.**
- **Skills: 1** — `/ross-ai-assistant:vivado-rtl-lint` invoked once before the lint stage. No observable difference in the lint command or report structure versus the plain arm (same `synth_design -lint -file`, same 52 findings, same triage categories).
- MCP session behaviour: n/a (never used). No hangs.

### Notes
- Timing differs from plain/i3c (+0.786 vs +1.147 ns WNS; 93 vs 42 hold endpoints) on identical RTL because this XDC adds `HD.CLK_SRC` (routed clock tree, real insertion delay) and the flow omits `phys_opt_design`. Both are legitimate choices; the plain arm tried `HD.CLK_SRC` and rejected it, this arm kept it and said why.
- Same shared space-in-path confound as every other cell.
- Cost/turn/tool data: `results/ross/i3c/summary-20261008-210558.md`.
