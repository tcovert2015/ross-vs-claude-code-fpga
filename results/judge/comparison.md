## Comparison: AMD Ross vs plain Claude Code on three FPGA ports

All six cells ran 2026-10-08 21:06–22:21 on one machine (Ryzen 7 8700F, 32 GB, Vivado 2025.2), four at a time, headless Opus with identical prompts, budget cap and baseline commit. Every cell was judged from committed artifacts and re-run from a clean checkout (`harness/judge_rerun.ps1`). Per-cell verdicts: #1 #2 #3 #4 #5 #6. PRs: #8–#13.

### Scorecard

| Design | Arm | Gates | Soft score | Cost | Turns | Wall | Vivado launches | Headline |
|---|---|---|---|---|---|---|---|---|
| i3c | **plain** | 7/7 | **15/15** | $1.93 | 33 | 14 min | 14 | WNS +1.147 ns, 29/29 xsim; inferred tri-state rejected on netlist evidence |
| i3c | ross | 7/7 | 13/15 | $2.08 | 45 | 15 min | 12 | WNS +0.786 ns, 29/29 xsim; same macro, SCL unbuffered |
| dma | **ross** | 7/7 | 14/15 | **$2.15** | 39 | **17 min** | 29 | WNS −1.019 ns @125 MHz, closes at 9.25 ns; 6/6 xsim |
| dma | plain | 7/7 | 14/15 | $3.14 | 67 | 46 min | 37 | WNS −1.035 ns @125 MHz, closes at 9.25 / 9.75 ns; 9/9 xsim (extra RESET_SYNC config) |
| fpga-scope | **plain** | 7/7 | 14/15 | $5.86 | 83 | 52 min | 37 | 3/3 configs meet 100 MHz with a 2 ns input budget after a vendor-neutral RTL fix (A/B reports kept); IPI inference verified; Verilator 17/17 |
| fpga-scope | ross | 7/7 | 11/15 | $5.09 | 80 | 60 min | 24 | 3/3 configs meet 100 MHz only after relaxing the input budget to 1 ns; IPI not exercised; Verilator not run |
| **Total** | **plain** | 21/21 | **43/45** | $10.93 | 183 | 112 min | | |
| **Total** | **ross** | 21/21 | **38/45** | $9.32 | 164 | 91 min | | |

Soft-score breakdown (S1 Xilinx pieces / S2 lint triage / S3 README / S4 efficiency / S5 recovery):

| Cell | S1 | S2 | S3 | S4 | S5 |
|---|---|---|---|---|---|
| plain/i3c | 3 | 3 | 3 | 3 | 3 |
| ross/i3c | 2 | 3 | 3 | 2 | 3 |
| plain/dma | 3 | 3 | 3 | 2 | 3 |
| ross/dma | 3 | 3 | 3 | 2 | 3 |
| plain/fpga-scope | 3 | 3 | 3 | 2 | 3 |
| ross/fpga-scope | 2 | 3 | 3 | 1 | 2 |

### Verdict

**Plain Claude Code wins 2 designs, ties 1, and scores 43/45 against Ross's 38/45.** Both arms passed every hard gate on every design, every committed number reproduced to the digit from a clean checkout, and the deliverables are structurally near-identical across arms (same macro-based IO-shim selection on i3c, same xsim `void'($urandom)` fix on dma, same declaration-order and `do…while` fixes on fpga-scope). The differences are in judgement, not in tool access:

- **Where plain won, it won by doing the harder thing.** On i3c it ran the inferred-tri-state experiment and kept the netlist probe; on fpga-scope it fixed the real timing problem in vendor-neutral RTL with before/after reports, verified IP Integrator inference by building a block design, and re-ran the repo's Verilator suite in WSL. The Ross arm argued the tri-state from principle, relaxed a constraint to pass timing, skipped IPI, and reported Verilator as unavailable without looking in WSL.
- **Where Ross won (dma), it won on efficiency.** Same gates, same soft score, but a third of the wall time and two-thirds of the cost. The plain arm spent its extra budget on a nine-run sweep that exposed a non-monotonic Fmax result and on simulating the `RESET_SYNC=1` variant that is actually synthesised; useful, but not required.
- **Ross is cheaper overall** ($9.32 vs $10.93, 91 vs 112 min) and plain is more thorough. Neither arm hit the $40 cap or the 400-turn limit; the largest cell was $5.86.

### The central finding: the Ross tooling was never used

Across all three Ross cells, **zero calls** to the Vivado MCP server (`vivado_start`, `vivado_execute`, …) and **zero calls** to `amd-doc-search`, despite both being connected (43 tools in every init record) and the system prompt pointing at them. **One skill invocation** in three cells (`/ross-ai-assistant:vivado-rtl-lint`, in ross/i3c) with no observable effect on the lint command, report or triage versus the plain arm. Every Vivado and xsim launch in every cell went through `vivado.bat`/`xsim.bat` from `Bash` or `PowerShell`.

So this benchmark did **not** measure "MCP-driven Vivado vs shell-driven Vivado". It measured "Opus with 67 extra skills and 16 extra tools in context vs Opus without them", and the arm with the extra context did slightly worse, with more turns on two of three designs. Two plausible reasons, not separable with n=1 per cell: run-to-run variance of the model, and the larger tool/skill surface diluting attention. Either way, the Ross plugin as installed did not pull the agent toward its own tooling on realistic porting work.

Where MCP would have mattered: ross/fpga-scope lost time to hung xsim runs and a parallel Vivado start-up race and resolved both with machine-wide `taskkill` (which also killed one of the judge's re-runs). A single managed Vivado session is exactly what `vivado_start`/`vivado_execute` provide.

### Confounds and caveats

- **n = 1 per cell.** The i3c and dma pairs differ by 2 and 0 points; fpga-scope by 3. A second seed could reorder i3c.
- **Space in the worktree path** (`D:\AMD Ross Test\…`) broke `synth_design -lint -file`, `read_verilog` and `read_xdc` in Vivado 2025.2. Every cell hit it and every cell recovered; both arms paid the same tax. Worth fixing in the harness for a rerun.
- **Shared machine.** Four Vivado/xsim jobs plus judge re-runs ran concurrently; wall-clock numbers include contention. The ross/fpga-scope `taskkill` calls are the only cross-cell interference found.
- **Same model for both arms, Fable 5.1 as judge.** The judge did not see arm labels while reading READMEs but did while scoring; scores are backed by the evidence tables in each verdict so they can be re-derived.

### Recommendations for a rerun

1. Move the repo to a space-free path.
2. Add an explicit instruction in the Ross arm prompt to use `vivado_*` tools (a "nudged" third arm), to measure the tooling itself rather than whether the agent discovers it.
3. Run each cell at least three times.
4. Give each cell its own machine or container; forbid process-wide kills.
