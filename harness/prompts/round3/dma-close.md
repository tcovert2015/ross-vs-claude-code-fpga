# Task: close 125 MHz for the PCIe DMA engine on Artix-7 and prove nothing else changed

You are working in `designs/dma/`, a snapshot of
https://github.com/fpga-professional-association/dma (commit f8851d2): a scatter-gather DMA
engine in SystemVerilog with `SYS_IF = "AVALON" | "AXI4" | "AHB"`, Quartus project in `quartus/`,
Icarus regression `scripts/run_sim.sh` (6 configurations × 3 seeds), SymbiYosys proofs in `formal/`.

Four previous ports of this design to `xc7a100tcsg324-1` (Vivado 2025.2, out-of-context,
`SYS_IF="AXI4"`, `RESET_SYNC=1`) all failed the 8.0 ns clock: WNS between −1.04 and −0.46 ns on a
12–13-level register-to-register path in `rtl/core/dma_data_mover.sv` (write-side burst sizing:
`beats_to_boundary(w_addr)` → `min3(…)` → compare against the FIFO level → write-FSM enables).
Directive sweeps recovered at most 0.6 ns. Nobody changed the RTL.

AMD Vivado 2025.2 is at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat` (xsim included). Icarus
Verilog 12 is available under WSL (`wsl -d Ubuntu-24.04`; the Windows Icarus 11 cannot parse
`dma_pkg.sv`). Check whether `sby`/`yosys` are available in WSL. Work only inside `designs/dma/`.

## Deliverables

1. **RTL change** that closes 125 MHz with **default** Vivado directives (no Explore, no retiming):
   vendor-neutral, in `rtl/`, with the cycle-level behaviour change (if any) described precisely
   in `docs/` and in the commit message. The register map, descriptor format and bus protocols
   must not change. All three `SYS_IF` variants must still build and simulate.
2. **Vivado flow** — `vivado/build.tcl` + `vivado/pcie_dma.xdc`: lint, synth, opt/place/route,
   reports under `vivado/reports/`, plus a seed/period sweep that shows the margin is real
   (at least three placer seeds at 8.0 ns, or a bisection down to the closing period with two
   seeds each). Boundary timing must be modelled with explicit, justified I/O budgets; if you
   cut boundary hold, say exactly why and what the integrator must do.
3. **Equivalence proof**, all committed with logs:
   - `scripts/run_sim.sh` under WSL Icarus 12: **all 6 configurations × 3 seeds** pass on the
     changed RTL;
   - `scripts/run_xsim.{tcl,ps1}`: AXI4 and AXI4+STALLS, seeds 1 2 3, and the `RESET_SYNC_EN`
     variants, pass in xsim;
   - `formal/*.sby` re-run if SymbiYosys is available; if not, say so and state which
     properties would be affected by your change;
   - a before/after comparison of per-descriptor completion cycle counts for one seed, from the
     testbench, so the throughput cost of your change is a measured number.
4. **Results** — `vivado/README.md`: the change and why it is safe, WNS/TNS/WHS at 8.0 ns per
   seed, the sweep, utilization before/after, lint delta, every cited Vivado behaviour with the
   user guide section it comes from.

## Rules

- Execute everything; do not describe commands you did not run. Every number in the README
  must come from a committed report or log.
- Commit on the current branch with clear messages. Do not push.
- Scripts must exit non-zero when a stage or a test fails. They will be run from a clean checkout.
- Finish with a short summary: pass/fail per deliverable, WNS per seed, measured throughput
  cost, what is left undone.
