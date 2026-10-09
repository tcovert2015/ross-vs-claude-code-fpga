## Judge verdict: plain-lattice / dma  (PR #30, branch `plain-lattice/dma` @ a4037d0)

Lattice leg, plain arm (no plugin, no MCP). Judged from committed artifacts only; flow and the full Questa regression re-run from a clean checkout (`results/judge/plain-lattice-dma/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe lattice/build.tcl`: exit 0 (Synplify Pro → map + map timing → PAR + STA); every report reproduced, worst setup slack +1.097 ns identical |
| G2 warnings reported truthfully | **PASS** | README: Synplify 24 / map 273 / PAR 136, 0 errors; matches the `.srr`/`.mrp`/`.par` files |
| G3 synth + impl reports committed | **PASS** | `synthesis.srr`, `map.mrp`, `par.par`, `timing_map.tw1`, `timing_par.twr`, plus a complete `reports/iodelay/` set for the literal-SDC variant |
| G4 timing met at 125 MHz | **PASS** | +1.097 ns setup / +0.143 ns hold, 0 failing endpoints, Fmax 145.4 MHz (slack-derived, not re-run tighter). Caveat put first in the README as "Decision for you": the Quartus 1 ns I/O budget is expressed as `set_max_delay -datapath_only`; the literal `set_input/output_delay` form fails (−2.056 / −1.048 ns, 206 / 1489 endpoints) because virtual ports see no clock latency. Both builds committed, the literal one selectable with `DMA_SDC=pcie_dma_iodelay.sdc`. |
| G5 Questa regression | **PASS** | re-run: AXI4, AXI4+STALLS, and the same two with `RESET_SYNC_EN` (the synthesised parameter set), seeds 1–3: **12/12 PASS** in 20 s |
| G6 no silent core-RTL change | **PASS** | nothing under `rtl/` or `sim/` modified; Questa 7061 handled with `-suppress`, documented. Two RTL tidy-ups noted in the README and deliberately left alone. |
| G7 README numbers match reports | **PASS** | +1.097 / +0.143, 4880 LUT4 (763 virtual-I/O feed-throughs, 1536 LUTRAM) / 816 regs / 0 EBR, 24 + 273 + 136 warnings, 12/12 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **3** | Virtual-I/O map option as the Quartus virtual-pin equivalent; datapath-only port budgets with the failing literal variant committed as a selectable alternative *with its own full report set*; post-map timing report kept alongside post-route. |
| S2 warning triage | **3** | Per-stage counts with the unselected-bus explanation; spotted that a comment in `reset_sync.sv` is misread by Synplify as a pragma. |
| S3 README usefulness | **3** | Leads with the constraint decision the reader must make, both variants tabulated, the FIFO→EBR RTL change named but not made. |
| S4 efficiency | **2** | 59 turns, $3.65, 31 min wall (API 9 min); the extra time over lattice/dma bought the literal-SDC variant build and six more simulation runs. |
| S5 recovery | **3** | Same Synplify no-IO-buffer and Questa 7061 recoveries as lattice/dma, documented. |

**Total: 14/15, all gates pass.**

### Notes
- Numerically identical to lattice/dma (constraints, utilization, timing, warnings) at 6 % more cost and 2.2× the wall time, with more verification.
- Cost/turn/tool data: `results/plain-lattice/dma/summary-20261009-164247.md`.
