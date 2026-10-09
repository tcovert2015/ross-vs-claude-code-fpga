# Altera Synthesis & Timing (Quartus Prime Pro)

The device-agnostic RTL builds for a real Altera device; the only vendor-specific
file is `rtl/altera/i3c_io_altera.sv` (tri-state SDA pad).

## Build
Quartus runs as a Windows process (WSL invokes the `.exe`), so the project is staged
under `C:\i3c_quartus`:
```
syn/altera/build.sh syn    # analysis & synthesis only (fast synthesizability check)
syn/altera/build.sh all    # syn + fitter (P&R) + STA
```
Files: `i3c_target.qsf` (project), `i3c_target.sdc` (timing). Default device is
**Cyclone 10 GX `10CX220YF780E5G`** (also installed: Agilex 3 / Agilex 5 — change
`FAMILY`/`DEVICE` in the QSF). Toolchain found at `C:\altera_pro\25.3`.

## Results (Quartus Prime Pro 25.3, Cyclone 10 GX `10CX220YF780E5G`, final RTL)
| Stage | Result |
|---|---|
| Analysis & Synthesis | **0 errors** |
| Fitter (place & route) | **0 errors** |
| Resources | **528 ALMs, 348 registers, 2 RAM blocks, 84 pins** (post-fit; synthesis estimate ~900 logic cells) |

### Timing — read this carefully

The honest result, split by path class (this is what STA reports once the I/O is fully
constrained — see the SDC and the "I/O constraints" note below):

| Path class | Worst-case setup slack @ 8.0 ns (125 MHz) | Verdict |
|---|---|---|
| **Register-to-register + input** (the actual logic) | **+2.15 ns** | **MET** — pure reg-to-reg Fmax ≈ 244 MHz |
| Hold (all) | +0.02 ns | MET |
| **Combinational Avalon *output* pins** — now just `avs_waitrequest` | **−1.81 ns** | does **not** close standalone (irreducible, see below) |

**The internal logic meets 125 MHz** (the meaningful result for an on-chip IP).

`avs_readdata` is now **registered** (`i3c_avalon_mm`, issue #1 — 2-cycle Avalon read
latency, gated by `readdatavalid`), which moved the launch flop next to the output pad and
closed the old worst path (the RX-FIFO-read → readback-mux → pin path, previously −2.86 ns).
The only remaining negative-slack output is **`avs_waitrequest`**, which **Avalon requires
to be combinational** (the master needs it in the same cycle as the command) — so it
*cannot* be registered. Its port → decode/compare → port path runs through the FPGA pad
buffers (~3.65 ns each) and is ~8.7 ns, i.e. above the 8 ns period **regardless of the I/O
delay budget**.

This is an **out-of-context (OOC) artifact, not a design flaw**: an Avalon-MM agent is an
**on-chip IP boundary**, not chip pins — in a real system (Platform Designer) these ports
connect to the interconnect with **no pad buffers**, so `avs_waitrequest` is just a shallow
decode/compare (~1 ns) and closes easily. Synthesizing the IP *standalone with the Avalon
ports as chip pins* is what exposes the pad-buffer delay.

> **Earlier versions of these docs claimed "timing met @125 MHz" unqualified. That was
> wrong** — it held only because the I/O ports were *unconstrained* (STA wasn't analyzing
> them). With a complete SDC the truthful statement is the table above.

**For a true chip-pin Avalon deployment** (rather than an on-chip IP), close the residual
`avs_waitrequest` path with (1) `set_location_assignment` pin placement + a fast I/O
standard to cut the pad-buffer delay, and (2) `set_output_delay` budgeted to the real
downstream register. (`avs_readdata` is already registered.)

### I/O constraints (`i3c_target.sdc`)
Constrains every domain so STA is meaningful: `create_clock` on `clk`; async SDA/SCL pads
and reset cut with `set_false_path` (metastability closed by the 2–3 FF synchronizers, not
STA); Avalon-MM I/O given `set_input_delay`/`set_output_delay` (placeholder ~1 ns budgets —
set to the real master for sign-off). This reduced unconstrained ports from **35 in / 28
out to 1 in / 1 out** (the remaining two are the tied-off `avl_clk` pin and the `SDA`
inout, which carry no real logic paths in the default `AVL_ASYNC=0` build).

## Notes / next steps for a real board
- Add pin-location assignments (`set_location_assignment`) for SDA/SCL/clk/Avalon to
  the target board before generating a programming file.
- For an open-drain SDA pad, set the pad to the bus IO standard and (if needed) swap the
  inferred tri-state in `i3c_io_altera.sv` for an `ALTIOBUF` instance.
- Cyclone 10 GX is Quartus **Pro**; for MAX 10 / Cyclone IV/V use Quartus Standard/Lite
  (the RTL is identical — only the QSF FAMILY/DEVICE changes).
