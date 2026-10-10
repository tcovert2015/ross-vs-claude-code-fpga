# FPGA vendor AI tooling benchmark

Do vendor AI kits help an agent port FPGA designs?

A controlled benchmark of **AMD Ross** (the Vivado MCP server, `amd-doc-search`, and the Ross skills plugin)
and **Lattice Prompt** (the Radiant MCP server and the Lattice skills plugin) against **plain Claude Code**,
on real porting work: taking three open SystemVerilog designs from the
[FPGA Professional Association](https://github.com/fpga-professional-association) to AMD Vivado 2025.2 (Artix-7)
and Lattice Radiant 2026.1 (Certus-NX).

Same prompts, same model, same budget, same starting commit. Only the tooling differs.
Every result below was reproduced from a clean checkout by the judge before it was scored.

## Results in one table

| Leg | Arm | What the agent had | Score | Cost | Wall time | Vendor tools used |
|---|---|---|---|---|---|---|
| Vivado | **plain** | nothing | **43 / 45** | $10.93 | 112 min | — |
| Vivado | ross-nudged | Ross kit + an instruction to use it | 41 / 45 | $13.81 | 114 min | 77 MCP calls, 8 doc-searches, 9 skill calls |
| Vivado | ross | Ross kit, left to discover it | 38 / 45 | $9.32 | 91 min | 0 MCP calls, 1 skill call |
| Radiant | **plain-lattice** | nothing | **42 / 45** | $9.01 | 55 min | — |
| Radiant | lattice | Lattice kit, left to discover it | 41 / 45 | $9.34 | 41 min | 0 MCP calls, 3 skill calls |

Score = sum of five 0–3 soft criteria across three designs (max 45). Every cell passed all seven hard gates.

## The three findings

**1. Neither kit got itself used.** Given the plugin, a connected MCP server and a system-prompt line pointing at
them, the agent used the Ross tools in 0 of 3 cells and the Lattice tools in 0 of 3. In every one of those six
cells it shelled out to `vivado.bat` / `radiantc.exe` exactly as the plain arm did, and the Lattice pairs came out
numerically identical, slack to the picosecond. Why, from the transcripts:

- *The MCP tool schemas are deferred.* Claude Code lists the MCP tool **names** in the session but withholds their
  parameter schemas until the model calls `ToolSearch` for them. The three nudged cells all begin with
  `ToolSearch select:mcp__vivado-mcp__vivado_start,…`; the six discovery cells never call `ToolSearch` at all.
  A tool the model cannot see the signature of competes badly with `Bash`, whose signature it knows.
- *The skills do not route to the MCP.* The Ross `vivado-rtl-lint` skill does not mention the MCP or
  `vivado_execute` anywhere. The Lattice automation skill does say "call `ToolSearch` with `+lattice-radiant-mcp`
  at the start of every session", and the agent invoked that skill in all three cells and still did not do it,
  because the skill text arrives after the agent already has a working shell-based plan.
- *The shell path is good enough.* `vivado -mode batch -source build.tcl` is a pattern the model knows cold, and
  it produced passing results. There was no failure forcing a search for a better tool.

**2. Told to use it, the Ross arm improved on its own discovery result but did not beat plain.** The nudged arm scored 41 against the discovery arm's 38 and against plain's 43; it cost 26 % more than plain ($13.81 vs $10.93) and took the same total wall time (115 vs 113 min: much faster on i3c and fpga-scope, much slower on dma). What the kit added was qualitative and did not move the score: UG905/UG901/UG903 citations from `amd-doc-search` that no plain cell produced, one Vivado session reused end to end instead of a launch per step, and a one-call recovery from a genuine Vivado crash (access violation inside `phys_opt_design`, recorded by the MCP proxy) where the discovery arm had resorted to machine-wide `taskkill`. With one run per cell, the 41-vs-43 gap is within noise; the 38-vs-43 gap and the zero tool use are not.

**3. Having nothing was never worse than having a kit.** Plain scored highest on both vendors (43 on Vivado, 42 on Radiant) at the lowest or near-lowest cost. The Lattice kit's value when forced is untested; a `lattice-nudged` arm is the obvious next cell.

A cross-vendor result worth keeping: the DMA engine fails 125 MHz on Artix-7 -1 in every Vivado cell
(best −0.456 ns with retiming) and closes it on Certus-NX -8 with +1.097 ns, same RTL.

Per-cell score matrix and aggregates: [`docs/RESULTS.md`](docs/RESULTS.md). Full procedure, environment, incidents and
threats to validity: [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). Narrative write-ups with per-cell evidence: [`results/judge/comparison.md`](results/judge/comparison.md) (round 1) and
[`results/judge/comparison-round2.md`](results/judge/comparison-round2.md); both are posted on issue #7.

## Methodology (summary; the full version is [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md))

### Designs and tasks

| Design | Upstream | Pinned | The port |
|---|---|---|---|
| `designs/i3c` | [i3c](https://github.com/fpga-professional-association/i3c) | `4cbdc90` | vendor IO shim; synth/impl at 125 MHz; run the 29-check testbench in the vendor simulator |
| `designs/fpga-scope` | [fpga-scope](https://github.com/fpga-professional-association/fpga-scope) | `614ad20` | AXI4-Lite wrapper top; three-config utilization sweep at 100 MHz; port the CSR testbenches |
| `designs/dma` | [dma](https://github.com/fpga-professional-association/dma) | `f8851d2` | `SYS_IF="AXI4"` build at 125 MHz; AXI4 ± back-pressure regression, 3 seeds |

Task text: `harness/prompts/<design>.md` (Vivado) and `harness/prompts/lattice/<design>.md` (Radiant). Each asks
for a scripted flow, committed reports, a scripted regression, and a README in which every number traces to a
committed report.

### Arms

| Arm | Client | Plugin | MCP servers | Prompt |
|---|---|---|---|---|
| `plain` | Claude Code, headless, `--disable-slash-commands` | none | none | task only |
| `ross` | same | Ross plugin (67 skills) via `--plugin-dir` | `vivado-mcp` 2026.9.1, `amd-doc-search` | task + one system-prompt line saying the tools exist |
| `ross-nudged` | same | same | same | task + [`_nudge.md`](harness/prompts/_nudge.md): one `vivado_start`, every step via `vivado_execute`, the matching skills, doc-search; shell launches of Vivado forbidden |
| `plain-lattice` | same as plain | none | none | Radiant task only |
| `lattice` | same | Lattice skills plugin | `lattice-radiant-mcp` 1.11.0 | Radiant task + one system-prompt line |

Every cell: Claude Opus, `--permission-mode bypassPermissions`, $40 cap, 400-turn cap, `ScheduleWakeup`
disallowed (a headless session ends when the turn ends), its own git worktree on branch `<arm>/<design>` from the
same baseline commit. Fable 5.1 wrote the prompts, ran the harness, and judged.

### Judging

The rubric is [`harness/judge.md`](harness/judge.md). Seven hard gates (flow re-runs from a clean checkout, lint
reported truthfully, reports committed, timing met *or honestly and specifically explained*, regression passes,
no silent core-RTL change, README numbers match the reports) and five soft criteria scored 0–3 (quality of the
vendor-specific pieces, lint triage, README usefulness, efficiency, recovery from errors).

The judge never trusts the agent's summary. For every cell it checks out the branch into a fresh worktree, runs the
committed flow and regression scripts (`harness/judge_rerun.ps1` with `harness/judge/<design>[-<arm>].cmds`),
and diffs the regenerated reports against the committed ones. Three cells needed a second judge pass for
environmental reasons (another cell killing Vivado machine-wide, a node-locked Questa seat held by a concurrent
re-run, a runner that false-fails under PowerShell 5.1); each is documented in its verdict. Verdicts are posted
as comments on the per-cell issues and kept in `results/judge/verdict-<arm>-<design>.md`.

### What is recorded per cell

`results/<arm>/<design>/`: the full `stream-json` transcript, a summary (cost, turns, wall time, tool-call
histogram, MCP vs shell Vivado launches, commits, diff size), and the run metadata. `results/judge/<arm>-<design>/`:
the clean re-run logs.

## Caveats

- **n = 1 per cell.** Several pairs differ by one point. Treat ordering between adjacent arms as suggestive.
- **Shared machine.** Up to four Vivado/Radiant jobs plus judge re-runs ran concurrently; wall times include
  contention. One agent's machine-wide process kills are the only cross-cell interference found.
- **Path with a space.** The worktrees live under `D:\AMD Ross Test\…`, which breaks `synth_design -lint -file`
  and several `read_*` commands in Vivado 2025.2. Every Vivado cell hit it and recovered; both arms paid the tax.
- **Judge and planner are the same model family as the agents.** Scores are backed by the evidence tables in
  each verdict so they can be re-derived.
- **The soft rubric saturates.** Six of eighteen cells scored 14 or 15 out of 15. Round 3 (below) raises the ceiling.

## Round 3: harder tasks, a rubric with headroom

The round-1/2 tasks were ports that a competent engineer finishes in an afternoon, and the 0–3 scale cannot
separate "good" from "expert". Round 3 adds tasks where the vendor tooling should matter and a 0–5 rubric whose
top anchors require things no cell has done yet (in-context validation of out-of-context assumptions, formal or
cross-simulator equivalence after an RTL change, correct and verifiable documentation citations, a bitstream for a
real board). See [`harness/judge-v2.md`](harness/judge-v2.md) and `harness/prompts/round3/`.

| Task | Base design | What it demands beyond a port |
|---|---|---|
| `dma-close` | dma | close 125 MHz on Artix-7 -1 with a vendor-neutral RTL change, prove equivalence (all three bus configs in two simulators, formal re-run where available) |
| `i3c-async` | i3c | build `AVL_ASYNC=1` with a real second clock: CDC constraints, `report_cdc` clean, dual-clock regression |
| `scope-board` | fpga-scope | in-context design for Arty A7-100T: block design with AXI interconnect and JTAG-to-AXI master, pinout, bitstream, in-context port timing |
| `docs-grounded` | any | ten device/tool questions with verifiable answers and required citations to the exact user-guide section |

## Reproducing

Prerequisites: Vivado 2025.2 at `C:\AMDDesignTools\2025.2`, Radiant 2026.1 at `D:\lscc\radiant\2026.1`, the Vivado
MCP server at `~/tools/vivado-mcp-server.exe`, the Ross plugin cloned at `D:\AMD Ross Test\ross-ai-assistant`,
the Lattice Prompt plugins installed at user scope, Claude Code 2.1.283.

```powershell
# one cell
.\harness\run_arm.ps1 -Arm plain -Design i3c
# print the exact claude invocation without running it
.\harness\run_arm.ps1 -Arm lattice -Design dma -DryRun
# several cells, detached, bounded parallelism
pwsh -File harness\run_all.ps1 -Cells ross-nudged:i3c,ross-nudged:dma -MaxParallel 2
# judge a finished cell from a clean checkout
pwsh -File harness\judge_rerun.ps1 -Arm ross-nudged -Design i3c -CmdFile harness\judge\i3c-ross-nudged.cmds
```

Cells run detached (`Start-Process`) because a tool call that outlives its 10-minute window would kill them.
Paths are quoted everywhere because the repo path contains a space.

## Layout

```
designs/<design>/           pinned upstream snapshot (baseline for every arm)
harness/
  prompts/<design>.md       Vivado tasks        prompts/lattice/<design>.md   Radiant tasks
  prompts/_nudge.md         the ross-nudged addendum
  prompts/round3/           harder tasks        judge-v2.md                   0–5 rubric for round 3
  run_arm.ps1               one cell            run_all.ps1                   detached queue runner
  judge.md                  rubric              judge_rerun.ps1 + judge/      clean-checkout re-runs
  mcp-ross.json  mcp-lattice.json  mcp-none.json
results/
  <arm>/<design>/           transcript, summary, metadata
  judge/                    verdicts, comparisons, re-run logs
```

## Index

- Comparison and verdict: issue #7
- Vivado leg: issues #1–#6 (`ross` odd, `plain` even), PRs #8–#13
- Nudged Ross arm: issues #14–#16, PRs #17, #18, #31
- Lattice leg: issues #19–#24, PRs #25–#30

Designs are © their upstream authors under their own licenses (see each `designs/<design>/LICENSE`).
The harness and results are provided as-is for reproduction and discussion.
