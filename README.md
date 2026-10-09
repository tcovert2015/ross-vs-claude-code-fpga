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

## Status

See the GitHub issues: one per (arm, design) cell, plus a comparison issue.
