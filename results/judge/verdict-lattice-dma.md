## Judge verdict: lattice / dma  (PR #27, branch `lattice/dma` @ 951b5bb)

Lattice leg, tooling arm (Lattice Prompt skills plugin + `lattice-radiant-mcp` available). Second attempt: the first run ended after 3 minutes when the agent called `ScheduleWakeup` to wait for a background Radiant build (archived in `results/aborted-lattice-dma-schedulewakeup/`); that tool is now disallowed for every arm. Judged from committed artifacts only; flow and Questa regression re-run from a clean checkout (`results/judge/lattice-dma/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe lattice/build.tcl`: exit 0 (Synplify Pro → map → PAR → STA), every report reproduced |
| G2 warnings reported truthfully | **PASS** | README: Synplify 24 warnings / 0 errors, map 273, PAR 136; `.srr` has 24 `@W`, `.mrp` 273 and `.par` 136 `WARNING` lines |
| G3 synth + impl reports committed | **PASS** | `synthesis.srr`, `map.mrp`, `par.par`, `timing.twr`, `build_console.log`, plus the failed-variant `timing_io_delay_variant.twr` kept as evidence |
| G4 timing met at 125 MHz | **PASS** | worst setup **+1.097 ns**, worst hold **+0.143 ns**, 0 failing endpoints, 100 % constraint coverage; Fmax ≈ 145 MHz from the 8 ns run (README says it is derived, not confirmed by a tighter run). Caveat, stated up front in the README: the literal Quartus-style `set_input/output_delay` port fails (−2.056 ns, 1489 hold violations; report committed) because virtual pins are timed against an ideal clock while flops see ~4.1 ns insertion delay, so the 1 ns budget is expressed as `set_max_delay -datapath_only` and port hold is not checked. |
| G5 Questa regression | **PASS** | re-run: AXI4 and AXI4+STALLS, seeds 1–3, **6/6 PASS** |
| G6 no silent core-RTL change | **PASS** | nothing under `rtl/` or `sim/` modified. Questa's always_ff single-driver complaint about the testbench's backdoor memory writes handled with `-suppress 7061` and explained, instead of editing the testbench. |
| G7 README numbers match reports | **PASS** | +1.097 / +0.143, 4880 LUT4 (763 feed-through, 1536 distributed RAM) / 816 regs / 0 EBR, 24 + 273 + 136 warnings, 6/6 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **3** | Found the Radiant equivalent of Quartus virtual pins (`map_set_virtual_io_all_ports`) after discovering that disabling I/O insertion in Synplify makes map fail; `HDL_PARAM` for `SYS_IF`/`RESET_SYNC`; `.pdc` repeats the `rst_n` false path because Synplify does not forward it; datapath-only port budgets with the failing literal variant committed as evidence. `build.tcl` exits non-zero on a missing report. |
| S2 warning triage | **3** | 24 / 273 / 136 warnings broken down by ID; the 272 unused-port messages correctly tied to the unselected Avalon/AHB inputs. |
| S3 README usefulness | **3** | Headline caveat first; I/O timing model explained with the mechanism; notes the `RESET_SYNC=0`-simulated vs `RESET_SYNC=1`-synthesised gap and the absent clock-uncertainty equivalent. |
| S4 efficiency | **2** | 50 turns, $3.43, 14.0 min wall, 11 shell invocations of radiantc/Questa. |
| S5 recovery | **3** | Recovered from the Synplify no-IO-buffer failure, the literal-SDC timing failure and the Questa 7061 error with documented, minimal changes. |

**Total: 14/15, all gates pass.**

### Lattice-tooling observations
- **lattice-radiant-mcp: 0 calls.** Never loaded, despite `lattice-radiant-automation` instructing it at session start. **Skills: 1** (`lattice-radiant-automation`, no observable effect). `lattice-radiant-webdocs`: never invoked.
- Noteworthy cross-vendor result: this DMA engine **closes 125 MHz on Certus-NX -8** (+1.097 ns) where every Artix-7 -1 cell failed it (−1.02 to −1.04 ns). Different fabric, different FIFO mapping (distributed RAM here), same RTL.

### Notes
- Cost/turn/tool data: `results/lattice/dma/summary-20261009-164359.md`.
