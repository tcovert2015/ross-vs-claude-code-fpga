# Task: put fpga-scope on a real board — Arty A7-100T, bitstream, in-context timing

You are working in `designs/fpga-scope/`, a snapshot of
https://github.com/fpga-professional-association/fpga-scope (commit 614ad20): a vendor-neutral
embedded logic analyzer with an AXI4-Lite CSR front-end. Three previous ports built an
out-of-context AXI4-Lite wrapper for `xc7a100tcsg324-1` and met 100 MHz, but every one of them
timed the AXI ports with placeholder budgets or not at all, and only one checked that IP
Integrator can infer the interface.

AMD Vivado 2025.2 is at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`. Target board:
**Digilent Arty A7-100T** (`xc7a100tcsg324-1`, 100 MHz oscillator on the board clock pin). No
hardware is attached; the deliverable stops at a bitstream and the in-context reports. Work only
inside `designs/fpga-scope/`.

## Deliverables

1. **Wrapper** — `fpga/xilinx/scope_axil_top.sv` (`s_axi_*` AXI4-Lite slave, `PROBE_W`,
   `DEPTH_LOG2` pass-through) plus whatever shim IP Integrator needs to reference it as an RTL
   module; prove inference with `validate_bd_design` output committed.
2. **Block design** — `fpga/xilinx/bd.tcl` (recreatable with `source`): clocking wizard from the
   board's 100 MHz input to the scope clock, processor-system-reset, AXI SmartConnect or
   Interconnect, a **JTAG-to-AXI Master** so the scope can be driven from the Hardware Manager,
   the scope at a documented address, probes wired to the four slide switches, four buttons and
   the RGB LEDs' PWM counters (add a small free-running pattern generator so there is something
   worth capturing), `armed`/`triggered` on two LEDs, `trig_ext_i` on a button.
3. **Board constraints** — `fpga/xilinx/arty_a7_100t.xdc`: pin locations and I/O standards
   **derived from the board's reference manual or master XDC**, cited; the clock constraint; and
   input/output constraints for every used pin.
4. **Flow** — `fpga/xilinx/build.tcl`: project or non-project, runs synth, implementation,
   `report_timing_summary`, `report_utilization`, `report_drc`, `report_methodology`,
   `report_power`, and `write_bitstream`; reports under `fpga/xilinx/reports/`; the `.bit`
   committed (or its md5 and size if it exceeds 50 MB). Timing must be met in-context with
   **no** false paths on the AXI side.
5. **Validation of the earlier out-of-context assumptions** — compare the in-context slack on
   the register-to-register and AXI port paths against the OOC numbers from the previous ports
   (quoted in their `fpga/xilinx/README.md` files on branches `plain/fpga-scope`,
   `ross-nudged/fpga-scope`); state which OOC budget was realistic and which was not, with
   numbers.
6. **Regression** — `sim/run_xsim.{tcl,ps1}`: `tb_smoke`, `tb_csr`, `tb_csr_if`, plus a
   testbench of the block design's AXI path (a behavioural AXI4-Lite master driving the scope
   through the interconnect in simulation, or the JTAG-to-AXI master's simulation model).
7. **Results** — `fpga/xilinx/README.md`: address map, pinout table with citations, timing and
   utilization in-context, power estimate, the OOC-vs-in-context comparison, how to drive the
   scope from the Hardware Manager Tcl console (commands included, untested on hardware and
   labelled as such).

## Rules

- Execute everything; do not describe commands you did not run. Every number in the README
  must come from a committed report or log.
- Commit on the current branch with clear messages. Do not push.
- Scripts must exit non-zero when a stage or a test fails. They will be run from a clean checkout.
- Finish with a short summary: pass/fail per deliverable, WNS in-context, utilization, power,
  what is left undone.
