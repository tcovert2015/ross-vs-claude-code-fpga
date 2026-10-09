# fpga-scope — Vendor-Neutral Embedded Logic Analyzer

A drop-in, instantiate-in-RTL logic analyzer that replaces SignalTap / ChipScope-ILA / Reveal
for **any FPGA and any flow**, including Yosys+nextpnr users who currently have nothing.
Capture into BRAM in the probe's clock domain, trigger on comparator/edge/sequence conditions,
drain over a byte-stream transport (UART built in; CSR window for Avalon-MM/AXI-Lite; anything
else via the exposed stream), view in GTKWave/Surfer/PulseView via a Python host tool. This is
the productized form of the [hyperram](https://github.com/fpga-professional-association/hyperram)
repo's `hyperram_bw_test` instrumentation pattern. Clean-room SystemVerilog, no vendor
primitives, Apache-2.0.

Design document: [docs/PLAN.md](docs/PLAN.md) ·
Interface contract: [docs/INTERFACES.md](docs/INTERFACES.md) ·
Architecture: [docs/DESIGN.md](docs/DESIGN.md) ·
Tracker: [issue #1](https://github.com/fpga-professional-association/fpga-scope/issues/1)

## Features

**Capture** — single probe group up to 512 bits, BRAM depth 2^N (N = 8..15), sampled every
probe-clock edge · pre/post-trigger circular capture · N capture windows per arm (segmented) ·
48-bit timestamp · optional run-length compression.

**Trigger** — 4 comparator units (mask/value + per-bit rising/falling edge) with AND/OR combine ·
4-stage sequencer with occurrence counters · `force_trig` "just show me the bus" button ·
cross-instance triggering (`trig_ext_i/o`) · all runtime-reconfigurable over CSR, no rebuild.

**Readout** — one framed byte-stream codec over any transport: built-in **UART** (pins to a $2
USB dongle), a **CSR** window with thin **Avalon-MM** and **AXI4-Lite** front-ends (drops into
Platform Designer / Vivado block designs), or a raw byte stream. The `fpgapa-scope` Python host
exports **VCD** (GTKWave / Surfer) and **sigrok `.sr`** (PulseView), and is verified against a
**Verilator co-simulation of the real RTL**.

**Quality** — clean-room SystemVerilog, no vendor primitives, one clock-domain crossing, capture
path never stalls on the transport · self-checking Verilator testbenches + four SBY formal proofs
in CI · works instantiated twice in one design (per-instance `ID_VALUE`).

## Why not just use the vendor ILA?

SignalTap, ChipScope/ILA, and Reveal are each excellent — inside one vendor's walled garden.
fpga-scope is **one open, spec'd, formally-verified core that works on every FPGA and every flow,
including Yosys+nextpnr, which has no ILA at all**, drains without a JTAG cable (UART or on-chip
bus), and writes open waveform formats. Full capability matrix, honestly marked (✅ shipped /
🟡 partial / 🔜 planned), and the gaps where the vendor GUIs still lead: **[docs/COMPARISON.md](docs/COMPARISON.md)**.

## Logic usage

`scope_top` is cheap, and the **logic doesn't scale with capture depth** — only the BRAM does.
Standalone on Agilex 3 (`PROBE_W=32`, `RLE_EN=1`, `XPORT="UART"`), full synth + fit:

| PROBE_W | Depth (2ᴺ) | ALMs | M20K | buffer bits |
|---|---|---|---|---|
| 32 | 256 (N=8)    | 1,746 / 34,000 (5%) | 6 / 262 (2%)  | 8,448 |
| 32 | 4096 (N=12)  | 1,819 / 34,000 (5%) | 13 / 262 (5%) | 135,168 |
| 32 | 32768 (N=15) | 1,964 / 34,000 (6%) | 69 / 262 (26%) | 1,081,344 |

The capture buffer maps to exactly its raw BRAM cost (`DEPTH × STORE_W` bits) — no bloat. In the
#12 board build (`XPORT="CSR"`, no transport FIFOs) the whole scope is **9 M20K at 4096×33**. Full
PROBE_W×DEPTH sweep + reproducible scripts (Quartus / Vivado / nextpnr): [fpga/util_sweep/](fpga/util_sweep/).

## Hardware bring-up (M9) — done

An fpga-scope instance runs on the **Arrow AXC3000** (Agilex 3 `A3CY100BM16AE7S`), instrumenting a
**real HyperRAM controller** ([hyperram](https://github.com/fpga-professional-association/hyperram))
as a third JTAG-Avalon slave (`XPORT="CSR"`, zero extra pins). It triggered on a live HyperBus
`cs_n` falling edge and captured a real transaction — `cs_n` asserting, `ck_en` gating the clock,
`dq_oe` driving the CA + write bytes, and the controller FSM stepping through its states — drained
to [`docs/captures/axc3000_hyperram_cs_focus.vcd`](docs/captures/axc3000_hyperram_cs_focus.vcd).

Build + program + capture walkthrough: **[fpga/axc3000/README.md](fpga/axc3000/README.md)**. The
full + focused VCDs, a sigrok `.sr`, a GTKWave `.gtkw` view, and the raw dump are in
[docs/captures/](docs/captures/) — open with `gtkwave docs/captures/axc3000_hyperram_cs_focus.vcd
docs/captures/axc3000_hyperram.gtkw`.

Utilization (demo config PROBE_W=32, DEPTH_LOG2=12, RLE_EN=1, Agilex 3, timing-clean at 175 MHz):
**4,388 ALMs (13%)**, **15 M20K (6%)** — of which the scope's 4096×33 capture buffer is exactly
**8 M20K = 135,168 bits**, the raw BRAM cost with no bloat. Scripted PROBE_W×DEPTH_LOG2 sweep:
[fpga/util_sweep/](fpga/util_sweep/).

## Verify

All testbenches are self-checking (`$fatal` on mismatch, `TB_RESULT: PASS`/`FAIL` contract) and
run under stock Verilator ≥ 5.0 (`--binary --timing -Wall`):

```sh
bash sim/run.sh
```

The script exits non-zero if any testbench fails; CI runs the same script on every push, plus the
four SymbiYosys formal proofs and the Python host + co-simulation suite. Full breakdown — every
testbench, formal property, and what each proves: **[docs/VERIFICATION.md](docs/VERIFICATION.md)**.
A nightly random-config soak (`bash sim/soak.sh`) runs seeded configs through the co-sim against
the golden model.

## Quickstart

**1. Instantiate** `scope_top` in your design and wire `probe` to the signals you want to watch:

```systemverilog
scope_top #(
    .PROBE_W(32), .DEPTH_LOG2(12), .RLE_EN(1), .XPORT("UART"), .UART_DIV(16)
) u_scope (
    .clk(clk), .rst(rst), .probe(my_signals),         // capture domain
    .xclk(clk), .xrst(rst),                            // transport domain (may differ)
    .uart_rx(uart_rx), .uart_tx(uart_tx),              // to a $2 USB-UART dongle
    .trig_ext_i(1'b0), /* …status/tie-offs… */
);
```

Add the RTL from `rtl/` (`scope_pkg.sv`, `rtl/prim/*`, `scope_core/csr/trigger/rle/drain/top`,
`rtl/xport/scope_uart.sv`). For a bus-attached readout instead of UART, use `XPORT="CSR"` with the
`rtl/if/scope_avalon.sv` or `scope_axil.sv` front-end (see [fpga/axc3000/](fpga/axc3000/) for a
worked JTAG-Avalon example).

**2. Install the host** and capture:

```sh
pip install -e host                # the fpgapa-scope package (stdlib; add [serial] for UART)
fpgapa-scope --port /dev/ttyUSB0 --baud 3000000 ping
fpgapa-scope --port /dev/ttyUSB0 config --pretrig 256 --windows 1
fpgapa-scope --port /dev/ttyUSB0 --probe-w 32 arm --wait \
    --out capture.vcd --sr capture.sr --probes probes.json
```

**3. View** `capture.vcd` in GTKWave / Surfer, or `capture.sr` in PulseView. See
[host/README.md](host/README.md) for the trigger/config CLI and the library API.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
