# fpga-scope v1.0.0

A vendor-neutral **embedded logic analyzer** — a drop-in, instantiate-in-RTL ILA for **any FPGA and
any flow** (including Yosys+nextpnr, which has no vendor ILA). Clean-room SystemVerilog, no vendor
primitives, Apache-2.0.

## Features

- **Capture** — probe up to 512 bits, BRAM depth 2⁸…2¹⁵, sampled every probe-clock edge; pre/post-
  trigger circular capture; N segmented capture windows per arm; 48-bit timestamp; run-length
  compression; **decimation** (sample-rate control) and **storage qualification** (store only
  cycles meeting a condition).
- **Trigger** — 4 comparator units (mask/value + per-bit rising/falling edge) with AND/OR combine,
  a 4-stage sequencer with occurrence counters, `force_trig`, and cross-instance triggering
  (`trig_ext_i/o`). All runtime-reconfigurable over CSR — no rebuild.
- **Readout** — one framed byte-stream codec over any transport: built-in **UART**, a **CSR** window
  with **Avalon-MM** / **AXI4-Lite** front-ends, or a raw stream. The `fpgapa-scope` Python host
  exports **VCD** (GTKWave/Surfer) and **sigrok `.sr`** (PulseView).

## Verified

- **15 Verilator testbenches** + a PROBE_W × XPORT × RLE_EN elaboration/lint matrix (`-Wall`, zero
  design waivers).
- **4 SymbiYosys formal properties**: trigger sample never lost; write pointer frozen in DONE; RLE
  never expands (`words ≤ samples+1`); drain never pops an empty FIFO.
- **Python host + Verilator co-simulation of the real RTL**: 29 tests, byte-exact against the
  `scope_ref.py` golden model across pretrig / wrapped / RLE / runtime-bypass / decimation /
  qualification configs; a **dual-instance** cross-trigger testbench; a nightly **random-config
  soak**.
- **Real silicon**: a capture on the Arrow **AXC3000** (Agilex 3) instrumenting a **live HyperRAM
  controller** over JTAG-Avalon — triggered on a HyperBus `cs_n` falling edge, drained 4096 RLE
  words; `cs_n` 32 transitions, controller FSM through 10 states (`docs/captures/`).

Full breakdown: [docs/VERIFICATION.md](VERIFICATION.md).

## Measured numbers

| | Result |
|---|---|
| Standalone `scope_top` (Agilex 3) | ~1.7–2.0k ALMs (**flat across depth**); capture buffer = exactly its raw BRAM cost (`DEPTH×STORE_W` bits, e.g. 8 M20K at 4096×33) |
| Board demo (scope + hyperram) | 4,388 ALMs (13%), 15 M20K (6%), **timing-clean at 175 MHz** |
| UART transport | bit-level verified (`tb_uart`, LSB-first + BE-CRC) and end-to-end over the byte stream (`tb_drain_cdc`) |
| Real capture | cs_n falling-edge trigger, 4096-word RLE drain over JTAG-Avalon |

Utilization meets the design-doc §9 target (≤ ~1.2× raw BRAM + small logic) — the buffer is 1.0×.

## Follow-ups (v1.1 / v2)

JTAG transport (#15), post-synth net tapping (#16), advanced trigger FSM (#18), multiple probe
groups (#19), live streaming (#21). (Decimation #20 and storage qualification #17 shipped in 1.0.)
