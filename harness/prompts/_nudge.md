## Tooling requirement (Ross arm)

This session has the AMD Ross Vivado MCP server and the Ross agent skills. Use them:

- Start **one** Vivado session with `vivado_start` (TCL mode, `working_dir` = your design
  directory) and run every Vivado step through `vivado_execute`: lint (`synth_design -lint`),
  synthesis, `opt_design`/`place_design`/`route_design`, every `report_*`, and the xsim flow
  (from the same session, e.g. `exec xvlog ...`/`xelab`/`xsim`, or a project-mode
  `launch_simulation`). Use `vivado_log_messages` / `vivado_status` / `vivado_history` to
  inspect results. Reuse the session; do not restart it per command.
- **Do not** launch `vivado.bat`, `xvlog.bat`, `xelab.bat` or `xsim.bat` from Bash/PowerShell.
  The committed `build.tcl` / `run_xsim.*` scripts must still be runnable standalone by a
  reviewer (a Tcl script that `vivado -mode batch -source` can run is fine), but *your* runs
  go through the MCP session.
- Invoke the Ross skills at the matching step: `/ross-ai-assistant:vivado-rtl-lint` before
  lint, `/ross-ai-assistant:vivado-timing-methodology-checks` when you look at timing,
  `/ross-ai-assistant:vivado-simulate-rtl` for xsim, and
  `/ross-ai-assistant:vivado-rtl-elaboration-analysis` if elaboration fails.
- Use `amd-doc-search` when you need Vivado/UG documentation (constraints, OOC flow, primitives)
  and cite what it returned in the README where it informed a decision.
