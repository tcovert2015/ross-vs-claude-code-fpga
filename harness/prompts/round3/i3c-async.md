# Task: make the I3C Target's `AVL_ASYNC=1` configuration real on Artix-7

You are working in `designs/i3c/`, a snapshot of
https://github.com/fpga-professional-association/i3c (commit 4cbdc90): a MIPI I3C Basic v1.2 Target
in vendor-neutral SystemVerilog, Quartus flow in `syn/altera/`, Icarus testbench `sim/run.sh`
(29 checks).

The top has an `AVL_ASYNC` parameter meant to clock the Avalon-MM application interface from a
separate `avl_clk`, but the default build ties `avl_clk` to `clk`, `i3c_fifo.sv` documents its
asynchronous variant as not implemented, and a previous port found that `AVL_ASYNC=1` would clock
the bridge across single-clock FIFOs with no CDC. Three previous ports built only `AVL_ASYNC=0`.

AMD Vivado 2025.2 is at `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat` (xsim included). Icarus
Verilog 12 is under WSL (`wsl -d Ubuntu-24.04`). Work only inside `designs/i3c/`.

## Deliverables

1. **RTL** — a working `AVL_ASYNC=1`: a vendor-neutral dual-clock FIFO (or a documented
   alternative) with proper synchronisation for every signal that crosses between `clk` (I3C,
   125 MHz) and `avl_clk` (application, 50 MHz), including resets and the IRQ. `AVL_ASYNC=0`
   must be bit-for-bit unchanged in behaviour (prove it: 29/29 in Icarus and xsim with the
   default build and no RTL diff on that path beyond the parameterisation).
2. **Xilinx IO shim** — `rtl/xilinx/i3c_io_xilinx.sv`, same ports and drive semantics as the
   Altera shim; explain IOBUF vs inferred tri-state in the header **and demonstrate** the
   difference with a committed netlist probe of both variants.
3. **Vivado flow** — `syn/xilinx/build.tcl` + `syn/xilinx/i3c_target.xdc` for `AVL_ASYNC=1`,
   part `xc7a100tcsg324-1`, out-of-context, two clocks with `set_clock_groups`, I/O budgets
   justified, `report_cdc` with **zero Critical and zero unwaived Warning** CDC items, and
   `report_timing_summary`, `report_utilization`, `report_drc`, `report_methodology` under
   `syn/xilinx/reports/`. Timing must be met on both clocks.
4. **Regression** — `sim/run_xsim.{tcl,ps1}` and an updated `sim/run.sh` that run the testbench
   in both the default and the `AVL_ASYNC=1` configuration (the testbench must drive a real
   asynchronous `avl_clk` with a non-integer ratio to `clk`), 29/29 in both configurations in
   both simulators, logs committed.
5. **Results** — `syn/xilinx/README.md`: the CDC design, with each crossing listed and the
   mechanism that closes it; `report_cdc` summary; timing per clock; utilization; lint triage;
   every Vivado-specific claim cited to the user guide section it comes from.

## Rules

- Execute everything; do not describe commands you did not run. Every number in the README
  must come from a committed report or log.
- Commit on the current branch with clear messages. Do not push.
- Scripts must exit non-zero when a stage or a test fails. They will be run from a clean checkout.
- Finish with a short summary: pass/fail per deliverable, CDC item counts, WNS per clock,
  what is left undone.
