## Judge verdict: plain-lattice / i3c  (PR #25, branch `plain-lattice/i3c` @ 747caf7)

Lattice leg, plain arm (no plugin, no MCP). Judged from committed artifacts only; flow and Questa regression re-run from a clean checkout (`results/judge/plain-lattice-i3c/`).

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe syn/lattice/build.tcl`: exit 0 (Synplify Pro → map → PAR → STA ×2); every report reproduced. The agent's `build.ps1` Tee wrapper hung for 8 min under the judge's nested `cmd` redirect (Synplify never launched); `build.tcl` itself is what the gate checks and it is fine. |
| G2 warnings reported truthfully | **PASS** | README: Synplify 34 warnings / 0 errors, map 22; `.srr` re-run has 34 `@W` and no `@E` |
| G3 synth + impl reports committed | **PASS** | `synthesis.srr`, `map.mrp`, `par.par`, `pad.pad`, `timing.twr`, `timing_core.twr`, `build_console.log` |
| G4 timing met at 125 MHz **or honest, specific explanation** | **PASS (not met as constrained)** | Full constraints: 27 setup / 130 hold failing endpoints, worst −5.338 ns (`irq`), 74.97 MHz; all Avalon chip-pin paths, mechanism quantified (4.098 ns clock insertion + 4.665 ns output pad + 1.0 ns budget). Second STA pass on the same routed netlist with pin paths cut: +1.082 / +0.084 ns, **144.55 MHz**. Placeholder budgets kept, not loosened. |
| G5 Questa regression | **PASS, runner defect** | Simulation re-run: `RESULT: 29 passed, 0 failed`, `ALL TESTS PASSED`. But `sim/run_questa.ps1` printed `REGRESSION FAILED` and exited 1 when launched with `powershell -File` **as its own header and README instruct**: Windows PowerShell 5.1's `Tee-Object` writes the log as UTF-16, so the script's `-match 'ALL TESTS PASSED'` on the mixed-encoding file fails. Under `pwsh` 7 (what the agent actually used) it exits 0. The lattice/i3c cell avoided exactly this with `-Encoding ascii`. |
| G6 no silent core-RTL change | **PASS** | one change, `i3c_target_top.sv`: shim behind `I3C_IO_MODULE` macro defaulting to `i3c_io_altera`; default path checked in Questa (29/29, run by hand, not logged — README says so) |
| G7 README numbers match reports | **PASS** | 27/130, −5.338 / −0.714, 144.55 MHz, 914 LUT4 / 331 regs / 0 EBR / 73 PIO, 34 + 22 warnings, 29/29 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **2** | Inferred tri-state shim with `BB` evidence; `.pdc` `PULLMODE=NONE` on SDA/SCL (correct I3C catch); project-flow `build.tcl` with the core-only second STA pass. Minus one for the Questa runner that reports failure under the shell its README names, and for the Tee wrapper's console-dependence. |
| S2 warning triage | **3** | All 34 Synplify warnings by ID with file:line; `CG1340` false positives identified; Radiant front-end "undriven net" on the shim explained with the `.srr` evidence (1 `BB`, 37 `IB`). |
| S3 README usefulness | **3** | Two-view timing table, quantified pin mechanism, utilization with the FIFO→distributed-RAM note, pad report, board next-steps. |
| S4 efficiency | **3** | 36 turns, $2.42, **10.8 min** — cheapest and fastest of the Lattice i3c pair. |
| S5 recovery | **3** | Icarus 11 failure handled with a Questa cross-check; front-end warning diagnosed rather than patched. |

**Total: 14/15, all gates pass (G4 via honest explanation; G5 with a runner defect).**

### Notes
- Numerically identical to lattice/i3c (same constraints, same 914/331/0, same −5.338/−0.714, same 144.55 MHz) at 20 % less cost and 12 % less wall time.
- Cost/turn/tool data: `results/plain-lattice/i3c/summary-20261009-163947.md`.
