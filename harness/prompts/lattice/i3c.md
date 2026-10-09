# Task: port the I3C Target to Lattice Radiant (Certus-NX)

You are working in `designs/i3c/`, a snapshot of
https://github.com/fpga-professional-association/i3c (commit 4cbdc90). It is a
MIPI I3C Basic v1.2 Target in vendor-neutral SystemVerilog, currently built with
Quartus for Cyclone 10 GX (see `syn/altera/`) and simulated with Icarus
(`sim/run.sh`, 29/29 PASS).

Lattice Radiant is installed on this machine (find the install under `C:\lscc\radiant\<version>`;
the Tcl console is `bin\nt64\radiantc.exe` / `pnmainc.exe`). Synplify Pro and the bundled
QuestaSim are licensed (`LM_LICENSE_FILE` is set). Work only inside `designs/i3c/`.

## Deliverables

1. **Lattice IO shim** — `rtl/lattice/i3c_io_lattice.sv`, same port list and drive
   semantics as `rtl/altera/i3c_io_altera.sv` (SDA bidirectional open-drain-capable
   tri-state, SCL input only). Use whatever is idiomatic for Nexus-family devices
   (inferred tri-state or an explicit `BB`/`IB` primitive); explain the choice in a
   header comment.
2. **Radiant flow** — `syn/lattice/build.tcl` (project flow via `prj_*` Tcl or the
   non-project UDB flow, your choice) plus `syn/lattice/i3c_target.sdc` (and `.pdc` if
   you need one), targeting part **`LFD2NX-40-8BG256C`** (Certus-NX), top
   `i3c_target_top`, `clk` constrained at **125 MHz** (8.0 ns) matching the Altera SDC.
   Synthesis tool: Synplify Pro. The script must run, in order: synthesis, map, place
   and route, and static timing analysis, and leave the synthesis log, map report, PAR
   report and timing report under `syn/lattice/reports/`. No pinout is required (treat
   it as an IP core); if Radiant insists on pin locations, assign them in the `.pdc`
   and say so.
3. **Questa regression** — `sim/run_questa.{bat,ps1,tcl or sh}` that compiles the same
   file list as `sim/run.sh` (with the Lattice shim instead of the Altera one) and runs
   `tb_i3c_target` in the QuestaSim bundled with Radiant. All 29 checks must pass. Save
   the log to `sim/questa.log`.
4. **Results** — `syn/lattice/README.md` in the same style as `syn/altera/README.md`:
   how to run, synthesis/map warnings (count by severity and the top items, with your
   assessment of which are real), LUT4/register/EBR/IO utilization, worst setup and hold
   slack and achieved Fmax at the 125 MHz constraint, and any RTL changes you had to
   make (with justification). Do not silently alter core RTL; if a change is needed,
   keep it vendor-neutral and note it.

## Rules

- Execute everything; do not describe commands you did not run. Every number in the
  README must come from a report file committed under `syn/lattice/reports/` or
  `sim/questa.log`.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, worst slack / Fmax,
  utilization, warning counts, and anything left undone.
