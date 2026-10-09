# AMD Ross vs plain Claude Code — FPGA porting benchmark

An A/B test of **AMD Ross™ Agentic AI Assistant** (the Vivado MCP server +
`amd-doc-search` MCP + the Ross agent-skills plugin) against **plain Claude Code**
on realistic FPGA work: porting three open SystemVerilog designs from the
[FPGA Professional Association](https://github.com/fpga-professional-association)
(all Intel/Quartus-flow today) to **AMD Vivado 2025.2 / Artix-7**.

Same prompts, same model, same budget, same starting commit. Only the tooling differs.

| | `ross` arm | `plain` arm |
|---|---|---|
| Client | Claude Code 2.1.283, headless (`claude -p`) | same |
| Model | Opus (implementation) | same |
| MCP servers | `vivado-mcp` 2026.9.1 (local, stdio bridge), `amd-doc-search` 0.11.6 (remote HTTP) | none (`--strict-mcp-config`) |
| Skills | `amd-ross-agentic-ai-assistant` plugin 2026.9.1 via `--plugin-dir` | none (`--disable-slash-commands`) |
| Vivado access | via MCP tools (`vivado_start`, `vivado_execute`, …) | shells out to `vivado.bat` itself |
| Planning / issues / judging | Fable 5.1 | — |

## Designs

| Design | Upstream | Pinned | What the port involves |
|---|---|---|---|
| `designs/i3c` | [i3c](https://github.com/fpga-professional-association/i3c) | `4cbdc90` | Replace Altera tri-state IO shim with a Xilinx one; OOC synth/impl at 125 MHz; run the 29-check Icarus TB in xsim |
| `designs/fpga-scope` | [fpga-scope](https://github.com/fpga-professional-association/fpga-scope) | `614ad20` | AXI4-Lite wrapper top; 3-config utilization sweep at 100 MHz; run Verilator TBs in xsim |
| `designs/dma` | [dma](https://github.com/fpga-professional-association/dma) | `f8851d2` | `SYS_IF="AXI4"` build at 125 MHz; AXI4 ± back-pressure TB sweep in xsim |

The task text is in `harness/prompts/<design>.md` and is identical for both arms.
Hard gates and soft scores are in `harness/judge.md`.

## Layout

```
designs/<design>/      pinned upstream snapshot (baseline for both arms)
harness/
  prompts/<design>.md  the task (GitHub issue body)
  run_arm.ps1          run one cell: (arm, design) in its own worktree + branch <arm>/<design>
  summarize.py         cost / turns / tool-call histogram / git stats from the transcript
  mcp-ross.json        MCP config for the ross arm; mcp-none.json for plain
  judge.md             rubric
results/<arm>/<design>/   transcript-*.jsonl, summary-*.md, meta-*.json
```

## Running a cell

Prerequisites: Vivado 2025.2 at `C:\AMDDesignTools\2025.2`, the Vivado MCP server
at `~/tools/vivado-mcp-server.exe`, a clone of
[Xilinx/ross-ai-assistant](https://github.com/Xilinx/ross-ai-assistant) at
`D:\AMD Ross Test\ross-ai-assistant`.

```powershell
.\harness\run_arm.ps1 -Arm ross  -Design i3c
.\harness\run_arm.ps1 -Arm plain -Design i3c
```

Each run creates `..\wt\<arm>-<design>` as a worktree on branch `<arm>/<design>`
from `main`, runs Claude headlessly with `--permission-mode bypassPermissions` and
a `$40` budget cap, and writes the transcript and a summary to `results/`.
The agent commits on its branch; results are compared via PRs against `main`.

## Status — round 2 complete (2026-10-09)

Round 2 added a **nudged Ross arm** (explicitly told to use the MCP and skills: 41/45, $13.81; MCP used 77 times,
quality up, cost up) and a **Lattice leg** (Lattice Prompt skills + MCP vs plain, Radiant 2026.1 / Certus-NX:
41/45 vs 42/45, kit never used, numbers identical). Write-up: [`results/judge/comparison-round2.md`](results/judge/comparison-round2.md)
(issue #7). Cells: issues #14–#16 (ross-nudged), #19–#24 (lattice, plain-lattice); PRs #17, #18, #31, #25–#30.
Arms `ross-nudged`, `lattice`, `plain-lattice` in `harness/run_arm.ps1`; Lattice prompts in `harness/prompts/lattice/`.

## Round 1 — complete (2026-10-08)

All six cells ran, were judged from committed artifacts, and were re-run from clean checkouts.
**Plain Claude Code 43/45, Ross 38/45; all 21 hard gates passed by both arms.** The Ross arm never
called the Vivado MCP server or `amd-doc-search` in any cell. Full comparison and caveats:
[`results/judge/comparison.md`](results/judge/comparison.md) (also on issue #7).

| Cell | Verdict | PR | Soft score | Cost | Wall |
|---|---|---|---|---|---|
| plain/i3c | #2 | #8 | 15/15 | $1.93 | 14 min |
| ross/i3c | #1 | #9 | 13/15 | $2.08 | 15 min |
| ross/dma | #5 | #10 | 14/15 | $2.15 | 17 min |
| plain/dma | #6 | #11 | 14/15 | $3.14 | 46 min |
| plain/fpga-scope | #4 | #12 | 14/15 | $5.86 | 52 min |
| ross/fpga-scope | #3 | #13 | 11/15 | $5.09 | 60 min |

Per-cell verdicts: `results/judge/verdict-<arm>-<design>.md`. Clean-checkout re-runs:
`harness/judge_rerun.ps1 -Arm <arm> -Design <design> -CmdFile harness/judge/<design>[-<arm>].cmds`
(logs in `results/judge/<arm>-<design>/`). Queue runner for the cells: `harness/run_all.ps1`.
