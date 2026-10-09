# Task: port the I3C Target to AMD Vivado (Artix-7)

You are working in `designs/i3c/`, a snapshot of
https://github.com/fpga-professional-association/i3c (commit 4cbdc90). It is a
MIPI I3C Basic v1.2 Target in vendor-neutral SystemVerilog, currently built with
Quartus for Cyclone 10 GX (see `syn/altera/`) and simulated with Icarus
(`sim/run.sh`, 29/29 PASS).

AMD Vivado 2025.2 is installed at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`
(xsim included). Work only inside `designs/i3c/`.

## Deliverables

1. **Xilinx IO shim** — `rtl/xilinx/i3c_io_xilinx.sv`, same port list and drive
   semantics as `rtl/altera/i3c_io_altera.sv` (SDA bidirectional open-drain-capable
   tri-state, SCL input only). Use whatever is idiomatic for 7-series (inferred
   tri-state or `IOBUF`); explain the choice in a header comment.
2. **Vivado flow** — `syn/xilinx/build.tcl` (non-project or project mode, your
   choice) plus `syn/xilinx/i3c_target.xdc`, targeting part
   `xc7a100tcsg324-1`, top `i3c_target_top`, `clk` constrained at **125 MHz**
   (8.0 ns) matching the Altera SDC. The script must run, in order:
   RTL lint (`synth_design -lint`), synthesis, implementation (opt/place/route),
   and write `utilization`, `timing_summary`, and `drc` reports under
   `syn/xilinx/reports/`. Run out-of-context (`-mode out_of_context`) since this
   is an IP core, not a pinned top.
3. **xsim regression** — `sim/run_xsim.{bat,ps1,tcl or sh}` that compiles the
   same file list as `sim/run.sh` (with the Xilinx shim instead of the Altera
   one) and runs `tb_i3c_target` in xsim. All 29 checks must pass. Save the log
   to `sim/xsim.log`.
4. **Results** — `syn/xilinx/README.md` in the same style as
   `syn/altera/README.md`: how to run, lint findings (count by severity and the
   top items, with your assessment of which are real), LUT/FF/BRAM/IO
   utilization, WNS/TNS/WHS at 125 MHz, and any RTL changes you had to make
   (with justification). Do not silently alter core RTL; if a change is needed,
   keep it vendor-neutral and note it.

## Rules

- Execute everything; do not describe commands you did not run. Every number
  in the README must come from a report file committed under `syn/xilinx/reports/`
  or `sim/xsim.log`.
- Commit your work on the current branch with clear messages. Do not push.
- Finish by printing a short summary: pass/fail per deliverable, WNS, utilization,
  lint counts, and anything left undone.
