# Task: port the PCIe scatter-gather DMA engine to Lattice Radiant (Certus-NX)

You are working in `designs/dma/`, a snapshot of
https://github.com/fpga-professional-association/dma (commit f8851d2). It is a
scatter-gather DMA engine in SystemVerilog (`rtl/top/pcie_dma_top.sv`) with a
selectable system bus (`SYS_IF = "AVALON" | "AXI4" | "AHB"`), currently built
with Quartus (`quartus/`) and simulated with Icarus (`scripts/run_sim.sh`, 6
configurations x 3 seeds).

Lattice Radiant is installed on this machine (find the install under `C:\lscc\radiant\<version>`;
the Tcl console is `bin\nt64\radiantc.exe` / `pnmainc.exe`). Synplify Pro and the bundled
QuestaSim are licensed (`LM_LICENSE_FILE` is set). Work only inside `designs/dma/`.

## Deliverables

1. **Radiant flow** — `lattice/build.tcl` + `lattice/pcie_dma.sdc` (and `.pdc` if
   needed), part **`LFD2NX-40-8BG256C`**, top `pcie_dma_top` with `SYS_IF="AXI4"` and
   `RESET_SYNC=1`, `clk` at **125 MHz** (8.0 ns) matching `quartus/pcie_dma.sdc`,
   Synplify Pro. No pinout is required (the Quartus project uses virtual pins for the
   same reason); if Radiant insists on pin locations, assign them in the `.pdc` and say
   so. Runs synthesis, map, PAR, and static timing analysis, and leaves the synthesis
   log, map report, PAR report and timing report under `lattice/reports/`.
2. **Questa regression** — `scripts/run_questa.{bat,ps1,tcl or sh}` that runs
   `tb_pcie_dma` in the QuestaSim bundled with Radiant for the **AXI4** and
   **AXI4+STALLS** configurations (`+define+USE_AXI`, `+define+STALLS`) with seeds
   1 2 3, same pass criteria as `scripts/run_sim.sh`. Save logs to
   `sim/build/questa_<cfg>_seed<n>.log`.
3. **Results** — `lattice/README.md`: how to run, synthesis/map warnings (count by
   severity, top items, your assessment of which are real), LUT4/register/EBR
   utilization, worst setup and hold slack at 125 MHz, the achievable Fmax (report the
   slack and say what period would close), and any RTL changes you made
   (vendor-neutral, justified; do not silently alter core RTL).

## Rules

- Execute everything; do not describe commands you did not run. Every number in the
  README must come from a committed report or log.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, worst slack / Fmax,
  utilization, warning counts, and anything left undone.
