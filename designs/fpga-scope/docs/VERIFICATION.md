# Verification

Every check is self-checking and runs in CI (`.github/workflows/ci.yml`). The RTL is proven three
ways: simulation testbenches (Verilator, `-Wall`, zero waivers in the design), SymbiYosys formal
properties, and a Python co-simulation that drives the *real* RTL through the *real* host codec.

## Simulation testbenches (`bash sim/run.sh`)

| Testbench | Proves | Issue |
|---|---|---|
| `tb_smoke` | harness / CI plumbing | #2 |
| `tb_prim_ram` | 1r1w RAM read-during-write "old data" policy | #3 |
| `tb_prim_fifo_sync` | sync FIFO fill/drain/boundary + scoreboard soak | #3 |
| `tb_prim_fifo_async` | async FIFO CDC (3:1 / 1:3 / ~1:1), ≥100k transfers/leg | #3 |
| `tb_capture_basic` | `scope_core` capture bit-exact vs `scope_ref.py` (PROBE_W 32 & 512) | #4 |
| `tb_csr` | CSR register matrix, cfg_err lockout, BUF_DATA drain | #5 |
| `tb_trigger_cmp` | comparator truth table (level/edge), cycle-exact vs model | #6 |
| `tb_trigger_seq` | sequencer configs, occurrence counts, latency/alignment | #6 |
| `tb_pretrig` | PRETRIG sweep + host time-order reconstruction | #7 |
| `tb_windows` | multi-window slicing, metadata, disarm, cfg_err bound | #7 |
| `tb_drain_cdc` | `scope_top` end-to-end over the byte stream, xclk≠clk, NAK/resync, byte-exact drain under back-pressure | #8 |
| `tb_uart` | bit-level UART (LSB-first) + big-endian CRC16 | #8 |
| `tb_csr_if` | CSR matrix + BUF_DATA pop via Avalon-MM & AXI4-Lite | #11 |
| `tb_rle` | RLE encoder word stream byte-exact vs golden model, bypass, expansion bound | #9 |
| `tb_ext_trig` | **dual-instance**: A comparator-fires → B via `trig_ext`, both capture independently (no singleton state) | #13 |

Plus a `scope_top` elaboration/lint matrix: PROBE_W ∈ {8,512} × XPORT ∈ {UART,STREAM} × RLE_EN ∈ {0,1}.

## Formal (SymbiYosys, `cd formal && sby -f <name>.sby`)

| Property | Statement | Module |
|---|---|---|
| (a) | the trigger sample is never lost (stored the cycle `trig && sample_valid`) | `scope_core` |
| (b) | the write pointer does not advance in DONE | `scope_core` |
| (c) | the RLE encoder never expands: `words ≤ samples + 1` | `scope_rle` |
| (d) | the drain never pops an empty/unrequested FIFO; the cmd/rsp FIFOs cannot overflow | `scope_top` |

## Host + co-simulation (`pytest host/tests`)

29 tests: frame codec vs `scope_ref.py` golden bytes (so a host match == a silicon match), reorder
math, RLE decode, VCD + sigrok writers, and a **Verilator co-simulation** where the Python host
drives the real `scope_top` over a pipe and asserts the drained/decoded capture **byte-for-byte
against `scope_ref` for the same seed** — across pretrig, wrapped, RLE, runtime-bypass, **decimation**
(spacing == DECIM+1), and **storage qualification** (only qualifying samples) configs.

## Soak (`bash sim/soak.sh`, nightly)

N seeded random configs (seed, PRETRIG, trigger sample, RLE on/off, decimation) through the co-sim,
each checked end-to-end against `scope_ref`. Reproducible (RNG seed is an argument).

## Hardware

A real capture on the Arrow AXC3000 (Agilex 3): an fpga-scope instance triggered on a live HyperRAM
`cs_n` falling edge and drained the transaction over JTAG-Avalon — `docs/captures/`, `fpga/axc3000/`.
