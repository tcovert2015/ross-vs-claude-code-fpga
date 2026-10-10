# Methodology

This document records exactly how the benchmark was run and judged, so that the results can be reproduced,
re-scored, or disputed line by line. Everything stated here can be checked against the committed transcripts
(`results/<arm>/<design>/transcript-*.jsonl`), the run logs (`results/run_all.log`, `results/judge/*/judge.log`)
and the verdict files (`results/judge/verdict-*.md`).

## 1. Question

Does giving a coding agent a vendor's AI kit (an MCP server that drives the vendor tool, a documentation search
server, and a set of skills) change the quality, cost, or speed of real FPGA porting work, compared with the same
agent given nothing but a shell?

Two kits were tested: **AMD Ross** (Vivado MCP server 2026.9.1, `amd-doc-search` 0.11.6, Ross skills plugin
2026.9.1 at commit `2cdc9ee`, 67 skills) and **Lattice Prompt v1.0.1** (`lattice-radiant-mcp` server 1.11.0,
`lattice-radiant-skills` plugin with two skills).

## 2. Units of work

A **cell** is one (arm, design) pair run once. A **design** is a pinned snapshot of an open SystemVerilog project
from the FPGA Professional Association:

| Design | Upstream commit | Size | Original flow | Task (Vivado leg) | Task (Radiant leg) |
|---|---|---|---|---|---|
| i3c | `4cbdc90` | 16 RTL files, 29-check TB | Quartus (Cyclone 10 GX), Icarus | Xilinx IO shim, OOC synth/impl at 125 MHz on `xc7a100tcsg324-1`, TB in xsim, README | Lattice IO shim, synth/map/PAR/STA at 125 MHz on `LFD2NX-40-8BG256C`, TB in Questa, README |
| dma | `f8851d2` | 12 RTL files, 1 TB × 6 configs × 3 seeds, 9 formal proofs | Quartus, Icarus, SymbiYosys | `SYS_IF="AXI4"`, `RESET_SYNC=1`, OOC at 125 MHz, AXI4 ± STALLS × 3 seeds in xsim, README | same on Certus-NX in Questa |
| fpga-scope | `614ad20` | 15 RTL files, 16 TBs + golden-vector model | Quartus (Agilex 3), Verilator | AXI4-Lite top, 3-config sweep at 100 MHz, 3 TBs in xsim, README | same on Certus-NX in Questa |

The exact task text is `harness/prompts/<design>.md` (Vivado) and `harness/prompts/lattice/<design>.md`
(Radiant). Both legs use the same deliverable structure: a scripted flow that writes named reports, a scripted
regression that writes logs, a README in which every number must come from a committed artifact, and a rule
against silent core-RTL changes. The prompts were written by the judge model before any cell ran and were not
changed afterwards.

## 3. Arms

| Arm | Plugin (`--plugin-dir`) | MCP (`--mcp-config`, with `--strict-mcp-config`) | Extra prompt |
|---|---|---|---|
| `plain` | none; `--disable-slash-commands` | `mcp-none.json` (empty) | none |
| `ross` | Ross plugin | `mcp-ross.json`: `vivado-mcp` (stdio bridge to the local daemon), `amd-doc-search` (HTTP) | system prompt: "The AMD Ross agent skills and the Vivado MCP server (vivado_* tools) and amd-doc-search MCP are available in this session. Use them for Vivado work where they apply." |
| `ross-nudged` | Ross plugin | same | system prompt forbidding shell launches of `vivado.bat`/`x*.bat` and requiring the MCP and the four named skills; plus `harness/prompts/_nudge.md` appended to the task |
| `plain-lattice` | none; `--disable-slash-commands` | `mcp-none.json` | none |
| `lattice` | Lattice skills plugin | `mcp-lattice.json`: `lattice-radiant-mcp` (python `-m radiant_mcp`, `RADIANT_EXE` set in its environment) | system prompt: "The Lattice Prompt skills (lattice-radiant-automation, lattice-radiant-webdocs) and the lattice-radiant-mcp MCP server are available in this session. Use them for Radiant work where they apply." |

Common to every cell (`harness/run_arm.ps1`):

```
claude -p "<task text><issue note>" --model opus --output-format stream-json --verbose
       --permission-mode bypassPermissions --max-turns 400 --max-budget-usd 40
       --no-chrome --strict-mcp-config --disallowedTools ScheduleWakeup --setting-sources project
```

`--model opus` resolved to `claude-opus-5-5` (recorded in each transcript's init record). `--setting-sources
project` excludes the user's own plugins, hooks and MCP servers, so the plain arms were genuinely plain (their
init records list 27 tools, no MCP servers, no skills). The `ScheduleWakeup` exclusion was added after the first
lattice/dma attempt ended its session by calling it (see §8); the round-1 and ross-nudged cells ran without the
flag but none of them called the tool.

The issue note appended to every task names the GitHub issue, the branch, the worktree root and the working
directory. Nothing else differs between arms.

## 3a. Models

**Models.** Every agent cell ran on `claude-opus-5-5` (Claude Opus 5.5) via Claude Code 2.1.283; no subagents and no
second model appear in any cell's billing record (`modelUsage` lists exactly one model in all 15 transcripts). The prompts,
the harness, and all judging were done by `claude-fable-5-1` (Claude Fable 5.1) in an interactive Claude Code session.
No other model was involved at any stage.

## 4. Isolation and environment

- One machine: AMD Ryzen 7 8700F (8 cores / 16 threads), 32 GB, Windows 11 Home. Vivado 2025.2 build 6299465;
  Radiant 2026.1.1.229.0 with Synplify Pro X-2025.09LR-SP1 and QuestaSim Lattice Edition 2025.2; Claude Code
  2.1.283; Icarus 11.0 on Windows, Icarus 12.0 and Verilator 5.020 in WSL Ubuntu 24.04.
- Each cell runs in its own git worktree `wt/<arm>-<design>` on branch `<arm>/<design>`, created from the same
  baseline commit (`2bff727` for round 1; later rounds from `main`, which differs from the baseline only in
  harness files and results, never in `designs/`).
- Cells were launched detached by `harness/run_all.ps1` with bounded parallelism. Concurrency: round 1 ran four
  cells at once (the i3c and dma pairs, then the fpga-scope pair as slots freed); ross-nudged ran three at once;
  the Lattice leg ran three at once, overlapping with the tail of ross-nudged/dma and with judge re-runs. Start and
  end times are in `results/run_all.log`. Wall times therefore include contention and are comparable within a
  leg, less so across legs.
- The worktree path contains a space (`D:\AMD Ross Test\…`). Vivado 2025.2 mishandles such paths in
  `synth_design -lint -file`, `read_verilog` and `read_xdc`; every Vivado cell hit this and worked around it.
  It is a confound shared equally by all Vivado arms.
- The Vivado MCP daemon is shared (one process on `localhost:18090`); each cell gets its own Vivado session.
  The Lattice MCP is one process per cell. Questa's licence is node-locked and refuses a second concurrent seat.

## 5. What is recorded

Per cell: the full `stream-json` transcript (every message, tool call, tool result and the final `result`
record with `total_cost_usd`, `num_turns`, `duration_ms`), `meta-*.json` (arm, design, branch, start time),
`stderr-*.log`, and `summary-*.md` produced by `harness/summarize.py`.

Metric definitions:

- **Cost**: `total_cost_usd` from the `result` record that `claude -p --output-format stream-json` emits at the end of a
  session. Claude Code computes it itself from the token counts it also records (`modelUsage[<model>]`: uncached input,
  cache-creation input, cache-read input, output including thinking tokens) priced at the model's public API list price
  (`costBasis: "list"`, `provider: "firstParty"`). The sessions authenticated through a subscription, not an API key
  (`apiKeySource: "none"` in every init record), so these dollars were not invoiced; they are what the same tokens would
  have cost on the API. The figure covers the agent only: not the judge's sessions, not the vendor tools' compute.
  Example, plain/i3c: 56 uncached input + 93,105 cache-creation + 2,009,344 cache-read + 39,333 output tokens (13,338 of
  them thinking) → $1.93. Cache reads dominate the token count because every turn re-reads the growing context; output
  tokens dominate the cost. Anyone can recompute a cell's cost from its token counts and the published price list.
- **Turns**: `num_turns` from the result record.
- **Wall time**: the cell process's lifetime, from `claude` start to exit, including every tool's execution time.
- **Tool-call histogram**: count of `tool_use` blocks by tool name.
- **Vivado via MCP / via shell**: `summarize.py` counts MCP tool names, and counts `Bash`/`PowerShell` commands
  whose text matches `vivado|xsim|xvlog|xelab`. The shell count over-reports (it matches `grep vivado.log`, script
  edits, etc.); the verdicts quote counts re-verified from the transcripts, where a "shell launch" means a
  command that invokes `vivado.bat`, `vivado -mode`, `xvlog.bat`, `xelab.bat` or `xsim.bat`.
- **MCP / doc-search / skill counts** in the verdicts are exact counts of `tool_use` blocks.

## 6. Judging

The judge (Claude Fable 5.1, the same model family as the agents) scored each cell from committed artifacts
only, after a clean-checkout re-run. The procedure for every cell:

1. Read the agent's final message, then the committed README, flow script(s), constraints, vendor-specific RTL,
   regression runner, and the diff of `rtl/` and `sim/` against the baseline.
2. Spot-check README numbers against the committed reports: the timing summary row (WNS, TNS, failing
   endpoints, WHS), utilization rows (LUT, FF, BRAM/EBR, IO), lint/warning counts, regression pass counts, and any
   sweep tables. The verdict lists what was checked.
3. Create a fresh worktree of the branch (`harness/judge_rerun.ps1`), run the committed flow and regression with
   the command lines in `harness/judge/<design>[-<arm>].cmds` (taken from the cell's own README where possible),
   and compare the regenerated reports with the committed ones.
4. Verify specific claims in the transcript where the README asserts something the artifacts cannot show (e.g.
   "Verilator 17/17 under WSL", "no shell launches of Vivado", "Icarus could not parse the package").
5. Score the gates and the five soft criteria against `harness/judge.md`, write the verdict with the evidence
   for every score, post it to the cell's issue, and commit it under `results/judge/`.

Scoring was not blind: the judge knew the arm while scoring. To limit the effect, every soft score is accompanied
in the verdict by the evidence it rests on, and the same deduction was applied for the same defect across arms
(examples: an unbuffered SCL and an undemonstrated tri-state argument cost ross/i3c one S1 point; a relaxed timing
budget cost ross/fpga-scope one S1 point; a runner that false-fails under the shell its README names cost
plain-lattice/i3c one S1 point; an empty port SDC cost both Lattice fpga-scope cells one S1 point).

Gate G4 ("timing met, or an honest, specific explanation") passes a cell that misses timing if the README names
the critical path, quantifies the miss, and does not hide it. All four dma Vivado cells passed G4 this way; the
rubric does not reward closing timing over explaining why it cannot be closed, which is a known limitation
addressed in `harness/judge-v2.md`.

Observed limits of the rubric: S2 (lint triage) and S3 (README usefulness) scored 3 in all 15 cells, so they
carried no information; S1, S4 and S5 produced every difference. Six of 15 cells scored 14 or 15 of 15.

## 7. Judge re-runs that needed a second pass

Three re-runs failed for reasons unrelated to the branch under test. Each was repeated and the cause recorded:

| Cell | First-pass failure | Cause | Resolution |
|---|---|---|---|
| plain/fpga-scope | (32,15) build died in `report_drc` | the ross/fpga-scope agent ran `taskkill /F /IM vivado.exe` at 22:16:06, killing every Vivado on the machine | re-ran that config alone: identical reports |
| plain-lattice/i3c | runner printed `REGRESSION FAILED` | the runner's `Tee-Object` writes UTF-16 under Windows PowerShell 5.1, which the README names; its own pass check cannot read the file; under `pwsh` 7 it passes | scored as a runner defect (−1 S1); the simulation itself passed 29/29 both ways |
| plain-lattice/fpga-scope | `tb_prim_ram` failed | Questa licence checkout refused while another judge re-run held the seat | re-ran alone: 17/17 |

A fourth re-run (plain-lattice/i3c, first attempt) hung for eight minutes inside the agent's `build.ps1` Tee
wrapper when launched under the judge's nested `cmd` redirect; the judge switched to running `radiantc` on the
committed `build.tcl` directly, which is what the gate checks, and noted the wrapper's console dependence.

## 8. Harness incidents and their effect on cells

- **Round 1 first attempt (2026-10-08 20:55)** was launched from a foreground tool call with a 10-minute timeout
  and was killed within a minute; discarded and archived under `results/aborted-20261008-2055/`. No scored cell
  descends from it.
- **lattice/dma first attempt (2026-10-09 16:39)** ended after 3 minutes when the agent launched Radiant in the
  background and called `ScheduleWakeup`, which ends a headless session. Archived under
  `results/aborted-lattice-dma-schedulewakeup/`; the tool was then disallowed for all arms and the cell was
  relaunched from the baseline. The relaunched cell is the one scored.
- **lattice/i3c and lattice/dma first launches (2026-10-09 16:37)** started without the Lattice skills plugin
  because the harness passed an empty `--plugin-dir`; they were killed within three minutes (together with
  plain-lattice/i3c, which was a child of the same runner process), their worktrees and results deleted, the
  harness fixed (`-DryRun` now prints the resolved arguments), and all three relaunched. No artifacts from the
  aborted launches were kept or scored.
- **ross-nudged/dma** lost its Vivado session to an access violation inside `phys_opt_design` at 16:53:28
  (recorded in the MCP proxy log). The agent recovered inside the cell; the cell is scored as run.

## 9. Threats to validity

- **n = 1 per cell.** No cell was repeated. Adjacent arms differ by one or two points on several designs, which is
  within what a single re-run could change. Totals across three designs are more stable than any one cell, but
  the ordering plain > ross-nudged > ross (43 / 41 / 38) rests on three cells each.
- **Same model family for agent, planner and judge.** The prompts were written and the scoring done by Fable
  5.1; agents were Opus 5.5. Prompts could favour what the planner expects; the verdicts expose the evidence so
  that a human can re-score.
- **The nudge is a confound in itself.** `ross-nudged` received a longer, more prescriptive prompt. Some of its
  behaviour (three skill invocations per cell, a committed session transcript) follows from the instruction, not
  from the kit.
- **One machine, concurrent cells.** Wall time is noisy. Cost and turns are not affected by contention.
- **Tool-schema deferral.** Claude Code presents MCP tools to the model by name only until the model calls
  `ToolSearch` for them. This is a property of the client, not of either kit, and it is probably the main reason
  the discovery arms never used the kits. Another client, or a future version of this one, could change that
  result without any change to the kits.
- **The path with a space** cost every Vivado cell turns and is not representative of a normal checkout.
- **Soft rubric saturation** (see §6).

## 10. Data availability

Everything is in this repository: transcripts, summaries, run logs, judge re-run logs, verdicts, comparisons, the
agents' branches (as PRs against `main`), and the harness. The Vivado and Radiant installs, the MCP server
binaries and the licences are the only things not included.
