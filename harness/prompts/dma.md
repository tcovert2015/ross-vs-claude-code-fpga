# Task: port the PCIe scatter-gather DMA engine to AMD Vivado (Artix-7)

You are working in `designs/dma/`, a snapshot of
https://github.com/fpga-professional-association/dma (commit f8851d2). It is a
scatter-gather DMA engine in SystemVerilog (`rtl/top/pcie_dma_top.sv`) with a
selectable system bus (`SYS_IF = "AVALON" | "AXI4" | "AHB"`), currently built
with Quartus (`quartus/`) and simulated with Icarus (`scripts/run_sim.sh`, 6
configurations x 3 seeds).

AMD Vivado 2025.2 is installed at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`
(xsim included). Work only inside `designs/dma/`.

## Deliverables

1. **Vivado flow** — `vivado/build.tcl` + `vivado/pcie_dma.xdc`, part
   `xc7a100tcsg324-1`, top `pcie_dma_top` with `SYS_IF="AXI4"` and
   `RESET_SYNC=1`, `clk` at **125 MHz** (8.0 ns) matching `quartus/pcie_dma.sdc`,
   out-of-context (the Quartus project uses virtual pins for the same reason).
   Runs: RTL lint (`synth_design -lint`), synth, opt/place/route, and writes
   `utilization`, `timing_summary`, `drc` reports to `vivado/reports/`.
2. **xsim regression** — `scripts/run_xsim.{bat,ps1,tcl or sh}` that runs
   `tb_pcie_dma` in xsim for the **AXI4** and **AXI4+STALLS** configurations
   (`+define+USE_AXI`, `+define+STALLS`) with seeds 1 2 3, same pass criteria as
   `scripts/run_sim.sh`. Save logs to `sim/build/xsim_<cfg>_seed<n>.log`.
3. **Results** — `vivado/README.md`: how to run, lint findings (count by
   severity, top items, your assessment of which are real), LUT/FF/BRAM
   utilization, WNS/TNS/WHS at 125 MHz, the achievable Fmax (report the slack
   and say what period would close), and any RTL changes you made
   (vendor-neutral, justified; do not silently alter core RTL).

## Rules

- Execute everything; do not describe commands you did not run. Every number
  in the README must come from a committed report or log.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, WNS,
  utilization, lint counts, and anything left undone.
