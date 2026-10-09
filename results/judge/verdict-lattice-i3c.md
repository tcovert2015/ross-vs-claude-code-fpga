## Judge verdict: lattice / i3c  (PR #26, branch `lattice/i3c` @ cafc363)

Lattice leg, tooling arm (Lattice Prompt skills plugin + `lattice-radiant-mcp` available). Judged from committed artifacts only; flow and Questa regression re-run from a clean checkout (`results/judge/lattice-i3c/`). Gates are the Radiant equivalents of `harness/judge.md`.

### Hard gates

| Gate | Result | Evidence |
|---|---|---|
| G1 flow runs from clean checkout | **PASS** | `radiantc.exe syn/lattice/build.tcl`: exit 0 in 61 s (Synplify Pro → map → PAR → STA ×2); every report reproduced |
| G2 warnings reported truthfully | **PASS** | README: Synplify 34 warnings / 0 errors, map 22 warnings; `.srr` re-run has 34 `@W` lines and no `@E` |
| G3 synth + impl reports committed | **PASS** | `.srr`, `.mrp`, `.par`, `.pad`, `.twr`, `.r2r.twr`, `build_console.log` |
| G4 timing met at 125 MHz **or honest, specific explanation** | **PASS (not met as constrained)** | Full constraints: 27 setup / 130 hold failing endpoints, worst −5.338 ns on `irq`, Fmax 74.97 MHz. README shows every failure is an Avalon chip-pin path (4.1 ns clock insertion + 4.7 ns output pad + 1.0 ns budget > 8 ns before any logic) and adds a second STA pass on the *same routed netlist* with port paths cut: register-to-register +1.082 / +0.084 ns, **144.55 MHz**. Constraints were not loosened. |
| G5 Questa regression | **PASS** | re-run: `RESULT: 29 passed, 0 failed`, `ALL TESTS PASSED` in 3 s |
| G6 no silent core-RTL change | **PASS** | one change, `i3c_target_top.sv`: shim behind `I3C_IO_SHIM` macro defaulting to `i3c_io_altera`; default path checked in Questa (29/29, not logged — README says so) |
| G7 README numbers match reports | **PASS** | 27/130 endpoints, −5.338 / −0.714, 144.55 MHz, 914 LUT4 / 331 regs / 0 EBR / 73 PIO, 34 + 22 warnings, 29/29 — all match and all reproduced |

### Soft scores (0–3)

| | Score | Notes |
|---|---|---|
| S1 Lattice pieces | **3** | Inferred tri-state shim with the evidence that Synplify maps it to exactly one `BB`; `.pdc` that turns off the Nexus default pad pull-down on SDA/SCL (a real I3C-specific catch); project-flow `build.tcl` with a second `timing` pass for the register-to-register view. |
| S2 warning triage | **3** | All 34 Synplify warnings classified by ID with file:line; two `CG1340` index warnings correctly identified as false positives; Radiant's pre-synthesis "undriven net" message on the shim outputs explained as a front-end artifact with the `.srr` evidence. |
| S3 README usefulness | **3** | Two-view timing table with the mechanism quantified, utilization with the FIFO→distributed-RAM note, board next-steps (IO_TYPE, PULLMODE, PLL). |
| S4 efficiency | **2** | 48 turns, $3.02, 12.2 min wall, 16 shell invocations of radiantc/Questa. |
| S5 recovery | **3** | Worked around Icarus 11/12 failures with a Questa cross-check; diagnosed the front-end warning rather than "fixing" RTL for it. |

**Total: 14/15, all gates pass (G4 via honest explanation).**

### Lattice-tooling observations (the point of this arm)
- **lattice-radiant-mcp: 0 calls.** Never loaded via ToolSearch, although `lattice-radiant-automation` explicitly says to do that at session start.
- **Skills: 1** — `lattice-radiant-automation` invoked once; no observable effect on the flow (plain Tcl `prj_*` project script, same as the plain arm). `lattice-radiant-webdocs` never invoked; no documentation lookups.
- Result is **numerically identical** to plain-lattice/i3c (same constraints modulo braces, same 914/331/0, same −5.338/−0.714, same 144.55 MHz, same PULLMODE catch) at 25 % more cost and 13 % more wall time.

### Notes
- Cost/turn/tool data: `results/lattice/i3c/summary-20261009-163947.md`.
