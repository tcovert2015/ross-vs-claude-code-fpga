# Task: port fpga-scope (embedded logic analyzer) to Lattice Radiant (Certus-NX)

You are working in `designs/fpga-scope/`, a snapshot of
https://github.com/fpga-professional-association/fpga-scope (commit 614ad20). It
is a vendor-neutral SystemVerilog embedded logic analyzer (`rtl/scope_top.sv`)
with an AXI4-Lite CSR front-end (`rtl/if/scope_axil.sv`, used when
`XPORT="CSR"`). It has been built on Agilex 3 with Quartus (`fpga/`) and verified
with Verilator testbenches (`sim/run.sh`).

Lattice Radiant 2026.1 is installed at `D:\lscc\radiant\2026.1` (Tcl console:
`bin\nt64\radiantc.exe` / `pnmainc.exe`; QuestaSim Lattice Edition under `questasim\win64`).
Synplify Pro and QuestaSim are licensed (`LM_LICENSE_FILE` is set). Work only inside `designs/fpga-scope/`.

## Deliverables

1. **AXI4-Lite top for Radiant** — `fpga/lattice/scope_axil_top.sv`: instantiates
   `scope_top` with `XPORT="CSR"` and `scope_axil`, exposing a standard AXI4-Lite
   slave port group (`s_axi_*` naming) plus `probe`, `trig_ext_i/o`, `armed`,
   `triggered`. Parameters `PROBE_W` and `DEPTH_LOG2` must pass through.
2. **Radiant flow** — `fpga/lattice/build.tcl` + `fpga/lattice/scope.sdc` (and `.pdc`
   if needed), part **`LFD2NX-40-8BG256C`**, top `scope_axil_top`, `clk` at **100 MHz**,
   Synplify Pro. Runs synthesis, map, PAR, and static timing analysis, and leaves the
   synthesis log, map report, PAR report and timing report under
   `fpga/lattice/reports/<cfg>/`. The script takes `PROBE_W` and `DEPTH_LOG2` as
   arguments and must be run for the three configurations in the README's Agilex 3
   table: (32, 8), (32, 12), (32, 15).
3. **Questa regression** — `sim/run_questa.{bat,ps1,tcl or sh}` that runs at least
   `tb_smoke`, `tb_csr`, and `tb_csr_if` in the QuestaSim bundled with Radiant. Each
   prints `TB_RESULT: PASS`. Save logs to `sim/questa_<tb>.log`. If a testbench uses
   Verilator-only constructs, make the minimal portable fix and document it.
4. **Results** — `fpga/lattice/README.md`: how to run, synthesis/map warnings (count by
   severity, top items, your assessment), a utilization table mirroring the README's
   "Logic usage" table but for Certus-NX (LUT4 / registers / EBR blocks / buffer bits)
   for the three configs, worst setup slack and Fmax at 100 MHz for each, and any RTL
   changes you made (vendor-neutral, justified). The capture buffer must map to EBR
   (block RAM), not distributed/LUT RAM; state what it mapped to from the map report.

## Rules

- Execute everything; do not describe commands you did not run. Every number in the
  README must come from a committed report or log.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, utilization per
  config, worst slack / Fmax, warning counts, and anything left undone.
