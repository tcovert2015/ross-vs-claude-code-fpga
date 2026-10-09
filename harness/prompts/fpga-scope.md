# Task: port fpga-scope (embedded logic analyzer) to AMD Vivado (Artix-7)

You are working in `designs/fpga-scope/`, a snapshot of
https://github.com/fpga-professional-association/fpga-scope (commit 614ad20). It
is a vendor-neutral SystemVerilog embedded logic analyzer (`rtl/scope_top.sv`)
with an AXI4-Lite CSR front-end (`rtl/if/scope_axil.sv`, used when
`XPORT="CSR"`). It has been built on Agilex 3 with Quartus (`fpga/`) and verified
with Verilator testbenches (`sim/run.sh`).

AMD Vivado 2025.2 is installed at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`
(xsim included). Work only inside `designs/fpga-scope/`.

## Deliverables

1. **AXI4-Lite top for Vivado** — `fpga/xilinx/scope_axil_top.sv`: instantiates
   `scope_top` with `XPORT="CSR"` and `scope_axil`, exposing a standard AXI4-Lite
   slave port group (`s_axi_*` naming, so Vivado IP Integrator can infer the
   interface) plus `probe`, `trig_ext_i/o`, `armed`, `triggered`. Parameters
   `PROBE_W` and `DEPTH_LOG2` must pass through.
2. **Vivado flow** — `fpga/xilinx/build.tcl` + `fpga/xilinx/scope.xdc`, part
   `xc7a100tcsg324-1`, top `scope_axil_top`, `clk` at **100 MHz**, out-of-context.
   Runs: RTL lint (`synth_design -lint`), synth, opt/place/route, and writes
   `utilization`, `timing_summary`, `drc` reports to `fpga/xilinx/reports/<cfg>/`.
   Script takes `PROBE_W` and `DEPTH_LOG2` as arguments and must be run for the
   three configurations in the README's Agilex 3 table:
   (32, 8), (32, 12), (32, 15).
3. **xsim regression** — `sim/run_xsim.{bat,ps1,tcl or sh}` that runs at least
   `tb_smoke`, `tb_csr`, and `tb_csr_if` (the CSR / AXI4-Lite matrix) in xsim.
   These do not need the Python golden vectors. Each prints `TB_RESULT: PASS`.
   Save logs to `sim/xsim_<tb>.log`. If a testbench uses Verilator-only
   constructs, make the minimal portable fix and document it.
4. **Results** — `fpga/xilinx/README.md`: how to run, lint findings (count by
   severity, top items, your assessment), a utilization table mirroring the
   README's "Logic usage" table but for Artix-7 (LUT / FF / BRAM18+36 / buffer
   bits) for the three configs, WNS/TNS at 100 MHz for each, and any RTL
   changes you made (vendor-neutral, justified). The capture buffer must map to
   block RAM, not distributed RAM; state what it mapped to.

## Rules

- Execute everything; do not describe commands you did not run. Every number
  in the README must come from a committed report or log.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, utilization per
  config, WNS, lint counts, and anything left undone.
