## Round 2: the nudged Ross arm and the Lattice leg

Follow-up to the six-cell comparison above. Two questions were open: **does the Ross tooling help when it is actually used**, and **does the same pattern hold for a different vendor's agent kit** (Lattice Prompt v1.0.1: `lattice-radiant-skills` + `lattice-radiant-mcp`, on Radiant 2026.1 / Certus-NX `LFD2NX-40-8BG256C`). Same prompts shape, same model, same budget, same judge procedure (clean-checkout re-run of every committed flow and regression). Per-cell verdicts: #14–#16 (ross-nudged), #19–#24 (lattice / plain-lattice). PRs #17–#18, #25–#30, plus ross-nudged/dma.

### A. Ross arm, nudged: "use the MCP and the skills"

Identical task prompt plus `harness/prompts/_nudge.md` (one `vivado_start`, every step via `vivado_execute`, the matching Ross skills, `amd-doc-search` for documentation; shell launches of `vivado.bat`/`x*.bat` forbidden).

| Design | Arm | Soft | Cost | Turns | Wall | MCP calls | doc-search | Skills | Headline |
|---|---|---|---|---|---|---|---|---|---|
| i3c | plain | 15/15 | $1.93 | 33 | 14 min | – | – | – | WNS +1.147 |
| i3c | ross (discovery) | 13/15 | $2.08 | 45 | 15 min | 0 | 0 | 1 | WNS +0.786 |
| i3c | **ross-nudged** | 14/15 | $3.08 | 54 | **10 min** | 19 | 1 (UG905 cited) | 3 | WNS +0.969; found an `AVL_ASYNC=1` CDC gap nobody else did |
| fpga-scope | plain | 14/15 | $5.86 | 83 | 52 min | – | – | – | RTL timing fix, IPI verified, Verilator 17/17 |
| fpga-scope | ross (discovery) | 11/15 | $5.09 | 80 | 60 min | 0 | 0 | 0 | relaxed input budget to pass; machine-wide taskkills |
| fpga-scope | **ross-nudged** | 14/15 | $5.44 | 99 | **29 min** | 27 | 4 (2 cited) | 3 | same RTL timing fix as plain; MCP session transcript committed |
| dma | plain | 14/15 | $3.14 | 67 | 46 min | – | – | – | |
| dma | ross (discovery) | 14/15 | $2.15 | 39 | 17 min | 0 | 0 | 0 | |
| dma | **ross-nudged** | 13/15 | $5.29 | 100 | 75 min | 31 | 3 | 3 | WNS −0.456 (best 125 MHz result of the four dma cells); recovered from a Vivado crash via `vivado_start` |
| **Totals** | plain | **43/45** | $10.93 | 183 | 112 min | | | | |
| | ross (discovery) | 38/45 | $9.32 | 164 | 91 min | 0 | 0 | 1 | |
| | **ross-nudged** | **41/45** | $13.81 | 253 | 114 min | 77 | 8 | 9 | |

*Revised 2026-10-09: an earlier version of this section said the nudged Ross kit was "worth having"; the totals (plain 43 / $10.93, nudged 41 / $13.81) do not support that, and the wording below was corrected.*

**What the nudge changed.** Tool use went from zero to 19–31 MCP calls per cell with a single Vivado session reused end to end and **zero** shell launches of Vivado (verified in the transcripts). Quality went up versus the discovery arm on i3c (+1) and fpga-scope (+3) and down on dma (−1, efficiency only): 41/45 total against 38/45 for discovery and 43/45 for plain. Wall time fell sharply where the discovery arm had struggled (i3c 10 vs 15 min; fpga-scope 29 vs 60 min) and rose on dma (75 vs 17 min: a Vivado crash, high-effort directives, three periods). Cost rose across the board (+48 % i3c, +7 % fpga-scope, +146 % dma; $13.81 total vs $9.32 discovery and $10.93 plain): skill invocations and MCP round-trips are extra turns.

**What the tools contributed that the plain arm did not have.** `amd-doc-search` produced a UG905 citation that justified the IOBUF-inside-OOC-module decision in the README (i3c), and UG901/UG903 citations for the OOC flow (fpga-scope); the agent also said plainly when the search returned nothing useful. The lint skill's parser produced a machine-readable `lint.csv`. The MCP's value showed most clearly under failure: in the dma cell the first Vivado session died with an access violation inside `phys_opt_design` (recorded by the MCP proxy at 16:53:28), and the agent recovered by calling `vivado_start` again and resuming its sweep, with no process killing.

**Caveat.** This arm was told to use the tools. It measures the tools, not the plugin's ability to get itself used. n = 1 per cell still.

### B. Lattice leg: Lattice Prompt vs plain, three designs on Certus-NX

| Design | Arm | Soft | Cost | Turns | Wall | MCP calls | Skills | Headline |
|---|---|---|---|---|---|---|---|---|
| i3c | **lattice** | 14/15 | $3.02 | 48 | 12.2 min | 0 | 1 | core 144.6 MHz; chip-pin paths fail with placeholder budgets; Questa 29/29 |
| i3c | plain-lattice | 14/15 | $2.42 | 36 | 10.8 min | – | – | identical numbers; Questa runner false-FAILs under PowerShell 5.1 |
| dma | **lattice** | 14/15 | $3.43 | 50 | 14.0 min | 0 | 1 | closes 125 MHz (+1.097 ns), virtual I/O, no RTL change; Questa 6/6 |
| dma | plain-lattice | 14/15 | $3.65 | 59 | 31.1 min | – | – | identical numbers; literal-SDC variant committed; Questa 12/12 |
| fpga-scope | **lattice** | 13/15 | $2.89 | 49 | 14.6 min | 0 | 1 | 3/3 configs meet 100 MHz, buffer in EBR; only `clk` constrained |
| fpga-scope | plain-lattice | 14/15 | $2.94 | 54 | 13.1 min | – | – | identical numbers; whole 17-testbench suite ported, 17/17 |
| **Total** | **lattice** | **41/45** | $9.34 | 147 | 41 min | 0 | 3 | |
| **Total** | **plain-lattice** | **42/45** | $9.01 | 149 | 55 min | – | – | |

**The Lattice kit was not used either.** In all three `lattice` cells the agent invoked `lattice-radiant-automation` exactly once; that skill's first instruction is to load the `lattice-radiant-mcp` tools via ToolSearch, and in all three cells the agent did not. **Zero MCP calls** across the leg; `lattice-radiant-webdocs` never invoked. Every Radiant and Questa step was a shell call to `radiantc`/`vsim`, exactly as in the plain arm, and the results are numerically identical pair by pair (same constraints, same utilization, same slack to the picosecond, same warning counts). The one-point difference in the total is one arm porting more testbenches and the other leaving a runner with an encoding bug; neither is attributable to the kit. An extra cost of the kit: the first lattice/dma attempt ended after 3 minutes when the agent launched Radiant in the background and called `ScheduleWakeup` to wait for it, which ends a headless session (now disallowed for every arm).

**Cross-vendor result worth keeping.** The DMA engine fails 125 MHz on Artix-7 -1 in every Vivado cell (−1.02 to −1.04 ns, 12–13 logic levels in the burst sizing) and **closes it on Certus-NX -8 with +1.097 ns** in both Lattice cells, with the same RTL and the FIFO in distributed RAM on both. The i3c core lands at 144.6 MHz reg-to-reg on Certus-NX versus 125 MHz + 1.1 ns on Artix-7; fpga-scope's capture buffer maps to EBR / BRAM cleanly on both.

### C. Updated verdict

1. **Both vendor agent kits fail the discovery test.** Given the plugin, the MCP server, and a system prompt pointing at them, Opus used the Ross tooling in 0 of 3 cells and the Lattice tooling in 0 of 3 cells (one no-op skill call each). Whatever these kits are worth, the default installation does not get them used on realistic porting work.
2. **When forced, the Ross arm beat its own discovery result (41 vs 38) but not plain (43)**, at the highest cost of the three ($13.81) and the same total wall time as plain. Its documentation citations, single reused session and one-call crash recovery are real and did not translate into score. On this evidence a kit that is used is better than a kit that is ignored; it is not shown to be better than no kit.
3. **The Lattice kit's value when forced is untested**; a `lattice-nudged` arm is the obvious next cell.
4. The plain agent remains a strong baseline on both vendors: 43/45 on Vivado, 42/45 on Radiant, with every clean-checkout re-run reproducing its committed numbers.

### Harness notes for anyone rerunning
- `ScheduleWakeup` must be disallowed in headless cells (done).
- Kill a cell by its own pwsh pid, never the queue runner's tree (lost a cell that way).
- The Questa node-locked license refuses a second concurrent seat: judge re-runs must be serialised (one spurious failure, confirmed clean alone).
- The Lattice MCP's `configure_radiant` returned nothing; `RADIANT_EXE` in the server environment works.
