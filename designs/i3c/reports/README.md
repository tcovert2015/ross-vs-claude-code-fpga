# Build / Verification Evidence

Captured logs from actually running the three verification flows on this RTL. All are
**regenerable** — re-run the commands and you get the same results (that's the point of
the open-source flow). Committed here so the evidence is in-repo, not just on disk.

| File | Flow | Command that produced it |
|---|---|---|
| `formal_run.log` | SymbiYosys formal suite (ALL GREEN, 41 tasks) | `source tools/env.sh && cd formal && ./run.sh` |
| `sim_run.log` | Icarus simulation (29/29 PASS) | `source tools/env.sh && ./sim/run.sh` |
| `quartus/build_console.log` | Quartus synth + fit + STA console | `./syn/altera/build.sh all` |
| `quartus/i3c_target.syn.summary` | Synthesis summary | (Quartus) |
| `quartus/i3c_target.fit.summary` | Fitter summary — **528 ALMs, 348 regs, 2 RAM blocks** | (Quartus) |
| `quartus/i3c_target.sta.summary` | STA summary (full SDC) | (Quartus) |
| `quartus/i3c_target.sta.head.rpt` | STA report header (multi-corner tables) | (Quartus) |
| `quartus/timing_split.txt` | **STA by path class** — reg-to-reg+input **+2.15 ns MET**; avs_waitrequest **−1.81 ns** (readdata now registered; waitrequest is required-combinational, pad-buffer-limited standalone, OOC) | (derived) |
| `quartus/i3c_target.flow.rpt` | Full compile-flow report | (Quartus) |

> Timing: the **internal logic meets 125 MHz** (reg-to-reg + input paths, +2.15 ns). The
> only negative-slack paths are the *combinational* Avalon **output** pins through the
> FPGA output-pad buffer — an out-of-context artifact (an Avalon-MM agent is an on-chip IP
> boundary; `waitrequest` is required-combinational). See `../syn/altera/README.md`.

The full Quartus report set and a GUI-openable project (`i3c_target.qpf`) live in the
staged build dir `C:\i3c_quartus\` (created by `syn/altera/build.sh`); open
`C:\i3c_quartus\i3c_target.qpf` in the Quartus GUI to browse the Compilation Report.
The project files themselves are version-controlled in `syn/altera/`.
