# Judging rubric v2 (round 3 onwards)

Round 1/2 used seven pass/fail gates and five 0–3 criteria; six of eighteen cells scored 14 or 15 of 15, so the
scale could not separate "competent" from "expert". v2 keeps the gates, adds two, and replaces the soft scale with
eight 0–5 criteria whose top anchor is defined by evidence that **no round-1/2 cell produced**. A 5 should be rare;
a 40/40 should not happen. The judge re-runs everything from a clean checkout before scoring and never scores from
the agent's summary.

## Hard gates (pass/fail; any fail caps the soft total at 50 %)

| # | Gate | How verified |
|---|---|---|
| G1 | Every committed flow script runs to completion from a clean checkout, **first try, as documented** | `judge_rerun.ps1` with the README's own command lines |
| G2 | Lint/synthesis findings reported truthfully | counts in README vs the report files |
| G3 | Reports for every claimed run are committed; scratch (checkpoints, project dirs) is not | `git ls-files` |
| G4 | The task's timing target is met, or the shortfall is explained with the critical path and a demonstrated closing point | `timing_summary` + sweep reports |
| G5 | Every claimed regression passes on re-run | re-run with the committed runner |
| G6 | Core-RTL changes are vendor-neutral, justified, and **proven equivalent** by the means the task names | diff vs baseline + re-run of the named proofs |
| G7 | Every number in the README traces to a committed artifact | spot-check ten numbers, including the inconvenient ones |
| G8 | Scripts fail loudly: non-zero exit on a failed stage or failed test | judge breaks one thing (deletes a source file / flips a check) and re-runs; a green exit is a fail |
| G9 | No cross-cell interference: no machine-wide process kills, no shared-state writes outside the worktree | transcript grep for `taskkill /IM`, `Stop-Process -Name`, writes outside the worktree |

## Soft criteria (0–5 each, max 40)

Anchors: **0** absent or wrong; **1** attempted, materially flawed; **2** adequate, routine; **3** good, what a
competent engineer ships; **4** strong, with one piece of evidence beyond the brief; **5** expert, with the
specific evidence named below, and nothing the judge can fault.

| # | Criterion | What a 5 requires (and no round-1/2 cell did) |
|---|---|---|
| C1 | Vendor-specific engineering (constraints, primitives, flow scripts, board/IP integration) | boundary timing is modelled with real numbers, not placeholders, and the OOC assumptions are **validated in-context** (or the design is built in-context); IP/board integration verified by the vendor tool itself (e.g. `validate_bd_design`, a bitstream) |
| C2 | Verification depth | any RTL change proven equivalent by **two independent means** (e.g. two simulators across all configurations, or simulation plus a formal re-run); regression breadth beyond the brief where the synthesised configuration differs from the simulated one |
| C3 | Timing analysis rigour | critical path named with logic levels and the fix that would close it; Fmax demonstrated by runs, not slack arithmetic, with the non-monotonic risk addressed (multiple seeds or a bisection); hold on boundaries handled explicitly, not false-pathed away silently |
| C4 | Documentation grounding | every tool- or device-specific claim that matters cites the user guide section it comes from, and the judge finds each citation **correct on inspection**; wrong or decorative citations score 0 for this criterion |
| C5 | Reporting and honesty | decision-ready README: headline up front, what was not done, what the reader must decide; failed trials kept as evidence; no number without an artifact |
| C6 | Efficiency | cost and wall time within the best third of all cells on the same task **and** no wasted runs (abandoned builds, relaunches, hung tools); a crash recovered in one step does not count against |
| C7 | Robustness of deliverables | scripts run under both `powershell` 5.1 and `pwsh` 7 (or `bash`) from any directory; encodings and exit codes correct; no dependence on the agent's session state (sourced-only scripts that were never run standalone score at most 3) |
| C8 | Process hygiene | one tool session reused and closed at the end; scratch ignored; no stray processes; commits small and descriptive; no force-adds of generated files without saying why |

## Tool-arm observations (recorded, not scored)

MCP calls, doc-search calls (and whether each returned something used), skill invocations (and whether each changed
anything observable), session reuse, hangs, crashes and how they were recovered.

## Judge procedure additions in v2

1. Re-run with the README's command lines verbatim, in the shell the README names.
2. Break one thing (delete a listed source file) and re-run: the script must exit non-zero (G8).
3. Fetch every cited document section and check the claim against it (C4).
4. For any RTL change: run the baseline regression on the changed RTL in a second simulator (C2, G6).
5. Record wall time and cost of the judge's own re-run as the "reproduction cost" of the cell.
