# Results

All numbers below come from the per-cell verdicts (`results/judge/verdict-*.md`) and run summaries
(`results/<arm>/<design>/summary-*.md`). Every cell passed all seven hard gates after a clean-checkout re-run.

## Per-cell scores

S1 vendor-specific pieces, S2 lint triage, S3 README, S4 efficiency, S5 recovery; each 0–3.

| Arm | Design | Gates | S1 | S2 | S3 | S4 | S5 | Total /15 | Cost | Turns | Wall min |
|---|---|---|---|---|---|---|---|---|---|---|---|
| plain | i3c | 7/7 | 3 | 3 | 3 | 3 | 3 | **15** | $1.93 | 33 | 14.2 |
| plain | dma | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $3.14 | 67 | 46.0 |
| plain | fpga-scope | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $5.86 | 83 | 52.4 |
| ross | i3c | 7/7 | 2 | 3 | 3 | 2 | 3 | **13** | $2.08 | 45 | 14.7 |
| ross | dma | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $2.15 | 39 | 16.5 |
| ross | fpga-scope | 7/7 | 2 | 3 | 3 | 1 | 2 | **11** | $5.09 | 80 | 59.8 |
| ross-nudged | i3c | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $3.08 | 54 | 10.0 |
| ross-nudged | dma | 7/7 | 3 | 3 | 3 | 1 | 3 | **13** | $5.29 | 100 | 75.3 |
| ross-nudged | fpga-scope | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $5.44 | 99 | 29.3 |
| plain-lattice | i3c | 7/7 | 2 | 3 | 3 | 3 | 3 | **14** | $2.42 | 36 | 10.8 |
| plain-lattice | dma | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $3.65 | 59 | 31.1 |
| plain-lattice | fpga-scope | 7/7 | 2 | 3 | 3 | 3 | 3 | **14** | $2.94 | 54 | 13.1 |
| lattice | i3c | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $3.02 | 48 | 12.2 |
| lattice | dma | 7/7 | 3 | 3 | 3 | 2 | 3 | **14** | $3.43 | 50 | 14.0 |
| lattice | fpga-scope | 7/7 | 2 | 3 | 3 | 2 | 3 | **13** | $2.89 | 49 | 14.6 |

## Aggregates

| Leg | Arm | Total /45 | Cost | Turns | Wall | MCP calls | Doc-search | Skill calls | Shell launches of the vendor tool |
|---|---|---|---|---|---|---|---|---|---|
| Vivado | plain | **43** | $10.93 | 183 | 112.6 min | – | – | – | all |
| Vivado | ross-nudged | 41 | $13.81 | 253 | 114.6 min | 77 | 8 | 9 | 0 |
| Vivado | ross | 38 | $9.32 | 164 | 91.0 min | 0 | 0 | 1 | all |
| Radiant | plain-lattice | **42** | $9.01 | 149 | 55.0 min | – | – | – | all |
| Radiant | lattice | 41 | $9.34 | 147 | 40.8 min | 0 | 0 | 3 | all |

What the aggregates support, and what they do not:

- Within the Vivado leg, plain scored highest and cost least of the three; ross (discovery) cost least in dollars
  and minutes but scored lowest; ross-nudged scored between them at the highest cost. Each ordering rests on
  three unrepeated cells.
- ross-nudged beat ross (discovery) on score (+3) and on wall time for i3c and fpga-scope (10 vs 15 min, 29 vs
  60 min) while losing on dma (75 vs 17 min, including a Vivado crash) and on cost in every design. That is a
  comparison between two configurations of the same kit, not evidence that the kit beats having nothing.
- Within the Radiant leg, the two arms are a tie on everything that matters: identical constraints, identical
  utilization and slack, same gates. The one-point gap is one runner defect versus one agent porting 13 more
  testbenches than asked.
- Qualitative differences that did not move the score: the nudged cells produced documentation citations
  (UG905, UG901, UG903) that no plain cell produced, kept a single Vivado session instead of one launch per step,
  and recovered from a Vivado crash with one tool call. The rubric had no criterion that rewarded these beyond S1
  and S5, which the plain cells also maxed. `harness/judge-v2.md` adds one (C4, documentation grounding).

## Key engineering numbers by design

| Design | Target | plain | ross | ross-nudged | plain-lattice | lattice |
|---|---|---|---|---|---|---|
| i3c | 125 MHz | WNS +1.147, 496 LUT / 341 FF, 29/29 | WNS +0.786, 496 / 341, 29/29 | WNS +0.969, 497 / 341, 29/29 | core +1.082 (144.6 MHz), pins −5.338, 914 LUT4 / 331 regs, 29/29 | identical to plain-lattice |
| dma | 125 MHz | WNS −1.035 (closes 9.25 ns), 1345 LUT / 825 FF, 9/9 | WNS −1.019 (closes 9.25), 1373 / 825, 6/6 | WNS −0.456 with retiming (closes 9.0), 1333 / 831, 6/6 | **+1.097** (145 MHz), 4880 LUT4 / 816 regs, 12/12 | +1.097, 4880 / 816, 6/6 |
| fpga-scope | 100 MHz × 3 configs | all met after RTL fix (+0.79 / +0.60 / +0.91), BRAM 1/4/33, IPI verified, 4/4 + Verilator 17/17 | met only after relaxing the input budget to 1 ns (+0.19 / +0.29 / +0.36), 4/4 | met after the same RTL fix (+0.73 / +0.29 / +0.58), 4/4 | all met (+2.21 / +2.14 / +1.42), EBR 2/10/67, ports unconstrained, 17/17 | all met (+1.83 / +2.30 / +1.41), 4/4 |

## Index of evidence

- Verdicts: `results/judge/verdict-<arm>-<design>.md`, also posted on issues #1–#6, #14–#16, #19–#24.
- Comparisons: `results/judge/comparison.md`, `results/judge/comparison-round2.md`, posted on issue #7.
- Branches: PRs #8–#13 (round 1), #17, #18, #31 (ross-nudged), #25–#30 (Lattice).
- Clean re-run logs: `results/judge/<arm>-<design>/`.
