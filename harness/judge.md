# Judging rubric (applied identically to both arms)

Each cell (arm × design) is scored after the run from committed artifacts only —
not from the agent's own claims. Verify by re-running the committed scripts.

## Hard gates (pass/fail)

| # | Gate | How verified |
|---|------|--------------|
| G1 | Flow script runs to completion from a clean checkout | re-run `build.tcl` |
| G2 | Lint ran and findings are reported truthfully | compare README counts to `reports/*lint*` |
| G3 | Synthesis + implementation complete, reports committed | `reports/` present, non-empty |
| G4 | Timing: WNS ≥ 0 at the required clock (or honest, specific explanation) | `timing_summary` |
| G5 | xsim regression passes with the required testbenches/configs | re-run `run_xsim.*`, check logs |
| G6 | No silent core-RTL changes; every change justified and vendor-neutral | `git diff` vs baseline |
| G7 | Numbers in README match the committed reports | spot-check 5 numbers |

## Soft scores (0–3 each)

| # | Criterion |
|---|-----------|
| S1 | Quality of the Xilinx-specific pieces (IO shim / AXI wrapper / XDC) — idiomatic, minimal, correct |
| S2 | Quality of lint triage: real issues separated from noise, with correct references |
| S3 | Usefulness of the results README (would an engineer trust and reuse it?) |
| S4 | Efficiency: wall time, cost, number of Vivado launches, wasted iterations |
| S5 | Recovery: how it handled errors (xsim/SV incompatibilities, Tcl mistakes) |

## Efficiency metrics (recorded automatically by `summarize.py`)

cost (USD), turns, wall-clock, tool-call histogram, Vivado invocations via MCP vs shell,
commits, diff size.

## Ross-specific observations to record

- Which Ross skills fired (`/vivado-rtl-lint`, `/vivado-timing-methodology-checks`, …) and
  whether they helped or got in the way.
- Whether `amd-doc-search` was used and whether the citations were correct.
- MCP session behaviour: reuse of one Vivado session vs relaunch per command; any hangs.
