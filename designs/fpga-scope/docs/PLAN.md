# fpgapa-scope — Vendor-Neutral Embedded Logic Analyzer

**Rank 1/10 · Effort L · Depends on: fpgapa-prim (async FIFO, sync FIFO, regslice, ff_sync)**

## 1. Mission & value

A drop-in, instantiate-in-RTL logic analyzer that replaces SignalTap / ChipScope-ILA / Reveal for any FPGA and any flow, including Yosys+nextpnr users who currently have *nothing*. Capture into BRAM in the probe's clock domain, trigger on comparator/edge/sequence conditions, drain over a byte-stream transport (UART built in; CSR window for Avalon-MM/AXI-Lite; anything else via the exposed stream), view in GTKWave/Surfer/PulseView via a Python host tool. This is the productized form of the `hyperram` repo's `hyperram_bw_test` instrumentation pattern and the flagship of the Instrumented FPGA story.

Prior art & gap: LiteScope is locked to the LiteX/Migen ecosystem; vendor ILAs are closed and flow-locked. No standalone, spec'd, verified SV core exists.

## 2. Scope

**v1.0 in:** single probe group up to 512 bits; BRAM depth 2^N (N=8..15); pre/post-trigger circular capture; 4 comparator units (mask/value + edge) with AND/OR combine; 4-stage trigger sequencer with occurrence counters; N capture windows per arm; optional RLE; UART transport (fixed baud param) + CSR transport; Python host (`pip install fpgapa-scope`) with VCD + sigrok export; timestamp counter.
**v1.0 out (v2+):** multiple independent probe groups, JTAG transport, Ethernet transport, netlist-insertion flow, compression beyond RLE, live streaming mode.

## 3. Deliverables

```
rtl/scope_pkg.sv            types, PROBE_W/DEPTH/… param structs, frame opcodes
rtl/scope_core.sv           capture RAM ctrl + circular buffer + window logic
rtl/scope_trigger.sv        4 comparators + combine + sequencer
rtl/scope_rle.sv            optional run-length encoder (+ bypass)
rtl/scope_csr.sv            register file (native CSR bus)
rtl/scope_drain.sv          buffer → framed byte stream (readout path)
rtl/scope_top.sv            = trigger+core+rle+csr+drain, byte-stream ports
rtl/if/scope_avalon.sv      Avalon-MM CSR front-end        rtl/if/scope_axil.sv
rtl/xport/scope_uart.sv     UART transport (tx/rx, framing, CRC)
sim/model/scope_ref.py→.mem golden trigger/RLE reference vector generator
sim/tb_*.sv  sim/run.sh     self-checking TBs (list in §7)
host/fpgapa_scope/          Python: CLI, frame codec, probes.json, VCD/sigrok writers
docs/  fpga/<board>/        per CONVENTIONS; demo = scope watching hyperram bring-up signals
```

## 4. Interfaces

**Parameters (scope_top):** `PROBE_W` (1..512), `DEPTH_LOG2` (8..15), `NUM_CMP=4`, `SEQ_STAGES=4`, `RLE_EN` (0/1), `TS_W=48`, `XPORT` ("UART"|"CSR"|"STREAM"), `UART_DIV` (clk/baud), `ID_VALUE` (32-bit user tag).

**Ports (scope_top):**
| Port | Dir | Width | Notes |
|---|---|---|---|
| `clk`, `rst` | in | 1 | probe/capture domain |
| `probe` | in | PROBE_W | sampled every `clk`; register externally if timing needs it |
| `trig_ext_i` / `trig_ext_o` | in/out | 1 | cross-instance triggering |
| `xclk`, `xrst` | in | 1 | transport domain (may equal clk) |
| `rx_data/valid/ready`, `tx_data/valid/ready` | — | 8 | byte stream to UART pins or user link |
| `uart_rx`, `uart_tx` | in/out | 1 | only when XPORT="UART" |
| `armed`, `triggered` | out | 1 | LEDs/status |

**CSR map (32-bit regs, offset ×4):** 0 `ID` (magic 0x5C09E000 \| version) · 1 `HWCFG` (ro: PROBE_W, DEPTH_LOG2, NUM_CMP, RLE) · 2 `CTRL` (arm, disarm, force_trig, soft_rst) · 3 `STATUS` (state[2:0], triggered, wrapped, windows_done[7:0]) · 4 `PRETRIG` (samples to keep before trigger) · 5 `WINDOWS` (captures per arm, 1..255) · 6 `RLE_CTRL` · 7 `TS_LO/8 TS_HI` (ro, freerunning) · 16+4k `CMPk_MASK` lanes ×⌈PROBE_W/32⌉ … then `CMPk_VALUE`, `CMPk_EDGE_MASK`, `CMPk_EDGE_POL` · 64 `TRIG_COMBINE` (per-stage: 4-bit comparator select mask + AND/OR bit) · 65..68 `SEQ_CNTn` (occurrences to advance stage n) · 96 `BUF_CTRL` (drain start) · 97 `BUF_DATA` (ro, pops one word). Full table is INTERFACES.md v1 — freeze it at M2.

**Drain frame format (byte stream):** `0xA5 0x5C | cmd | len16 | payload | crc16-ccitt`. Commands: PING, READ_CSR, WRITE_CSR, DRAIN (returns header {trig_index, wrapped, ts48, rle_flag} then samples). Same codec both transports → one Python decoder.

## 5. Architecture

```
probe ─►[scope_trigger]──trig──►┐
probe ─►(opt scope_rle)─►[scope_core: DEPTH×(PROBE_W+TS?) simple-dual-port BRAM,
                                  write ptr free-runs while armed, stop_cnt after trig]
                                  │ read port (drain, same clk)
                    [scope_csr]◄──┤            capture domain
   ══════ prim_fifo_async ═══════╪═══════════  transport domain
                    [scope_drain: frames buffer + CSR reads into byte stream]──►[scope_uart | if/*]
```
- **Capture FSM (scope_core):** `IDLE → FILLING (until pretrig satisfied) → ARMED (circular) → TRIGGERED (count post = DEPTH−PRETRIG) → DONE → (windows left? re-arm : IDLE)`. The trigger sample itself is always stored, and its buffer index is latched (`trig_index`).
- **Trigger unit:** comparator k hits when `((probe & mask)==value) && (edge_mask ? (probe̸^probe_d1) & edge selected polarity : 1)`. Stage advance when (combine of selected comparators) true for `SEQ_CNTn` occurrences; final stage fires trigger. All registered; 1-cycle trigger latency is part of the spec (document, don't hide).
- **RLE:** emits `{is_count, data}` words; a count word carries a `DEPTH_LOG2`-bit repeat count; a change or count saturation flushes. Trigger index bookkeeping must translate through RLE (store raw index sideband at trigger time — simplest correct answer).
- **Clock domains:** exactly one CDC — drain/CSR traffic through two `prim_fifo_async` (cmd in, data out). Capture logic never stalls on the transport.

## 6. Protocol facts / load-bearing details

1. Sampling is *every* clk edge of the probe domain; no decimation in v1 (a decimator is a trivial v1.1 CSR).
2. Buffer is power-of-2 and addressed by a free-running pointer; "wrapped" flag = pointer passed DEPTH once since arm. Host reconstructs time order from `trig_index`, `wrapped`, `PRETRIG`.
3. CRC16-CCITT (0x1021, init 0xFFFF) over `cmd..payload`, transmitted big-endian. UART is 8N1, LSB-first (standard), fixed divisor parameter — auto-baud is v2.
4. CSR writes while `state!=IDLE` to trigger/window config are ignored and set a sticky `cfg_err` bit (prevents mid-capture reconfig corruption).
5. `force_trig` must work even if comparators never match — it is the "just show me the bus" button.

## 7. Verification plan

Golden reference: `sim/model/scope_ref.py` replays the same probe stimulus, computes expected trigger cycle, window contents, RLE stream → writes `.mem` the TB compares against.

TBs (each self-checking, `$fatal` on mismatch): `tb_capture_basic` (force trig, full buffer integrity) · `tb_pretrig` (sweep PRETRIG 0/1/25%/50%/DEPTH−1) · `tb_trigger_cmp` (mask/value/edge truth table, all 4 units) · `tb_trigger_seq` (2/3/4-stage sequences + occurrence counters, incl. never-fires timeout) · `tb_windows` (1..8 windows, re-arm gaps) · `tb_rle` (constant, toggling, worst-case alternating = expansion bound check; decode(encode)==raw) · `tb_drain_cdc` (xclk ≠ clk, ratios 3:1 and 1:3, back-pressure on tx_ready) · `tb_uart` (bit-level UART loop, CRC corruption → NAK) · `tb_csr` (both front-ends, cfg_err lockout) · `tb_ext_trig` (two instances cross-triggering).

Formal (SBY): (a) capture FSM never loses the trigger sample: assert `triggered |-> buffer[trig_index]==probe_at_trigger` via 1-sample tracking; (b) write pointer never advances in DONE; (c) RLE output word count ≤ input count+1 per run (no expansion beyond bound); (d) drain never pops an empty FIFO.

## 8. Milestones

- **M0 repo bootstrap** — Build: skeleton from hyperram template, CI, lint config, INTERFACES.md v0. Done: `sim/run.sh` runs an empty pass, CI green.
- **M1 capture core** — Test first: `tb_capture_basic`. Build: `scope_core` + force-trigger via testbench poke. Done: full-depth capture bit-exact vs ref.
- **M2 CSR + freeze** — Test: `tb_csr`. Build: `scope_csr`, native CSR bus, INTERFACES.md v1 frozen. Done: all regs r/w per table, cfg_err behavior proven.
- **M3 trigger engine** — Tests: `tb_trigger_cmp`, `tb_trigger_seq`. Build: `scope_trigger`. Done: truth-table sweep green; formal (a),(b) pass.
- **M4 pre-trigger + windows** — Tests: `tb_pretrig`, `tb_windows`. Done: sweeps green, host-side reorder math documented in DESIGN.md.
- **M5 drain + CDC + UART** — Tests: `tb_drain_cdc`, `tb_uart`. Build: `scope_drain`, `scope_uart`, prim FIFOs. Done: byte-exact frames under back-pressure both directions, CRC-error path proven.
- **M6 RLE** — Test: `tb_rle`. Done: formal (c) + decode-identity green.
- **M7 Python host** — Build: frame codec (shared test vectors with SV via .mem), `arm/config/download`, VCD writer (IEEE 1364 §18 format), sigrok `.sr` writer, probes.json name mapping. Done: pytest suite green against Verilator co-sim (drive tb via stdin/stdout pipe or file vectors).
- **M8 front-ends** — Build: `scope_avalon`, `scope_axil` (thin). Test: reuse `tb_csr` matrix. Done: green.
- **M9 board demo** — Build: `fpga/<board>/` instance watching real signals (recommended: hyperram controller's `cs_n/rwds/state` during bring-up — the perfect dogfood + blog post). Done: captured VCD checked into docs, README performance/utilization table (LUT/FF/BRAM at 3 widths × 3 depths on 3 flows).

## 9. Acceptance criteria (v1.0)

Full CONVENTIONS DoD, plus: capture-to-VCD round trip bit-exact for 10^7 random stimulus samples across 20 random configs; UART drain of a 512×4096 capture completes error-free at 3 Mbaud; utilization ≤ ~1.2× the raw BRAM cost + small logic (publish exact numbers); works instantiated twice in one design (no singleton state).

## 10. Guardrails for AI implementers

- The capture path must **never** stall on the transport: if you find yourself adding `ready` into `scope_core`'s write path, stop — that's the architecture inverted.
- BRAM inference: use `prim_ram_1r1w`; read-during-write policy must be "old data" or read/write phases separated by state — pick one, assert it in TB.
- Do not "optimize" the trigger to be combinational into the write-enable; the 1-cycle registered latency is specified.
- RLE + trigger indexing is the classic bug farm: the trigger index refers to **raw sample count**, carried sideband, not the RLE word index.
- Timestamps are captured in the probe domain and drained through the same FIFO as data — never re-sample time in the transport domain.
- UART is LSB-first; CRC16 is big-endian on the wire. Put both facts in `tb_uart` as the first two assertions.
