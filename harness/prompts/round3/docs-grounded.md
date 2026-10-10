# Task: ten engineering questions, answered from the vendor documentation, with citations

This task has no RTL. It measures whether the agent grounds tool- and device-specific claims in the
authoritative documentation rather than memory, because wrong-but-confident details are the
costliest failure mode in a port. Every answer will be checked against the cited document.

Write your answers to `docs/round3-answers.md` in this repository (create the directory). For each
question give: the answer, the **exact citation** (document number and title, version/date, and the
section, table or figure name — e.g. "UG903 (v2025.2) Using Constraints, ch. 5 'Timing Exceptions',
`set_max_delay -datapath_only`"), and one sentence on how you verified it. If a question cannot be
answered from documentation you can reach, say so; a wrong citation scores lower than an honest gap.

Tools: whatever is in your session. Vivado 2025.2 is installed at `C:\AMDDesignTools\2025.2`
(its `docs/` and `doc-search` are fair game); the Internet is fair game.

## Questions (AMD Artix-7 / Vivado 2025.2)

1. For `xc7a100tcsg324-1`: the number of 36 Kb block RAMs, DSP48E1 slices, and the number of
   user I/O in the CSG324 package, with the datasheet/package table that states them.
2. The maximum DSP48E1 clock frequency for Artix-7 speed grade -1, and the datasheet table.
3. The polarity of the `T` input of the 7-series `IOBUF` primitive, and the libraries guide
   entry that defines it.
4. What `HD.CLK_SRC` does in an out-of-context run, which document introduces it, and what the
   timing analysis assumes about a clock port when it is **not** set.
5. The precise semantics of `set_max_delay -datapath_only` (what is excluded, and its effect on
   hold analysis), with the section of the constraints guide.
6. What the `synth_design -lint` rule `ASSIGN-10` reports, and where the lint rules are documented.
7. The condition under which Vivado synthesis converts an inferred tri-state to logic in an
   out-of-context run (message `Synth 8-5799`), with the synthesis guide section on I/O buffer
   insertion in OOC mode.
8. Whether xsim supports `$urandom` called inside a `void'()` cast, and where the supported
   SystemVerilog subset is documented.
9. The Arty A7-100T board: the FPGA pin of the 100 MHz system clock and its I/O standard, with
   the board reference manual section or the Digilent master XDC line.
10. The DRC rules `NSTD-1` and `UCIO-1`: what each checks, their default severities, and the
    documented way to downgrade them for an IP-level build.

## Rules

- Each citation must be specific enough that a reader can open the document and find the
  passage in under a minute.
- Do not cite a document you did not open. State how you reached each document (local install
  path, search tool, URL).
- Commit `docs/round3-answers.md` on the current branch. Do not push.
- Finish with a short summary: how many questions answered with a verified citation, how many
  with an unverified one, how many unanswered.
