# fpgapa-scope — host tool

Python host for the [fpga-scope](../README.md) embedded logic analyzer: configure, arm, download,
and export captures to **VCD** (GTKWave / Surfer) and **sigrok `.sr`** (PulseView). One frame
codec speaks to every transport — UART (pyserial), a CSR window, or a co-sim pipe — because the
codec speaks bytes only.

## Install

```sh
pip install -e host            # stdlib only
pip install -e 'host[serial]'  # add pyserial for the UART transport
```

## CLI

```sh
# liveness + identity
fpgapa-scope --port /dev/ttyUSB0 --baud 3000000 ping

# configure trigger / capture params (runtime, over CSR — no rebuild)
fpgapa-scope --port /dev/ttyUSB0 config --pretrig 256 --windows 1

# arm, wait for the trigger, download, and write a VCD with named signals
fpgapa-scope --port /dev/ttyUSB0 --probe-w 32 arm --wait \
    --out capture.vcd --probes probes.json

# arm and export straight to sigrok (+ save the raw decoded capture for later re-export)
fpgapa-scope --port /dev/ttyUSB0 --probe-w 32 arm --wait \
    --sr capture.sr --save capture.json --samplerate 48000000

# re-export a saved capture to another format without re-capturing
fpgapa-scope export capture.json --out capture.vcd --sr capture.sr --probes probes.json

# drain over JTAG (the scope_jtag byte bridge, #15) instead of UART — same frames, same decoder
fpgapa-scope --jtag --jtag-base 0x400 --probe-w 32 arm --wait --out capture.vcd --probes probes.json
```

**JTAG transport (`--jtag`, #15):** with an `rtl/if/scope_jtag` byte bridge on a JTAG-to-Avalon
master, the whole framed protocol runs over the JTAG cable — the *same* codec, unchanged. The host
drives a persistent `system-console` REPL (`fpga/axc3000/sysconsole/scope_jtag_repl.tcl`) that pumps
bytes through the bridge's TXDATA/RXDATA/STATUS registers; `fpgapa_scope.jtag.JtagTransport` presents
it as an ordinary byte transport. Hold `/tmp/axc3000-devkit.lock` around board access.

`probes.json` maps probe bit lanes to names (`[msb, lsb]`, inclusive); unmapped bits export as
`probe[k]`:

```json
{ "cs_n": [0, 0], "rwds": [1, 1], "state": [4, 2] }
```

## Library

```python
from fpgapa_scope import Scope, write_vcd
sc = Scope(transport, probe_w=32)     # transport: pyserial Serial / co-sim pipe / BytesTransport
sc.write_csr(fpgapa_scope.csr.PRETRIG, 256)
sc.arm(); sc.force_trig(); sc.wait_done()
cap = sc.drain(pretrig_eff=256)       # -> Capture (reordered, RLE-decoded)
write_vcd("out.vcd", cap.samples, cap.probe_w, trig_pos=cap.trig_pos)
```

## Verification

`pytest host/tests` (run in CI):
- **frame codec** — build/parse round-trip, CRC16-CCITT **cross-checked against `sim/model/scope_ref.py`** (which the RTL is proven against in `tb_uart`/`tb_drain_cdc`, so a match here is a match to silicon), corrupted-CRC → error, resync after garbage, NAK; decode of DRAIN_DATA frames produced by the SV-side `scope_ref.cmd_drain_data`.
- **reorder** — the DESIGN.md issue-#7 worked examples + an end-to-end DRAIN decode placing the trigger sample correctly.
- **RLE decode** — matches `scope_ref.rle_decode` across widths.
- **VCD** — round-trips named + bus signals + the trigger marker through a minimal VCD reader.
- **sigrok `.sr`** — ZIP container structure, `metadata` fields, channel naming, and a byte-exact round-trip of the raw `logic-1-1` payload (libsigrok srzip v2 format).
- **Verilator co-sim** (`test_cosim.py`, auto-skips without verilator) — builds the **real `scope_top`** (`XPORT="STREAM"`) into a binary whose stdin/stdout-isolated pipe fds carry the byte stream, then the host drives it end-to-end: **ping → identify → configure → arm → (TB-internal seeded stimulus) → wait → drain → decode**. The drained buffer, `trig_index`, `wrapped`, and the reordered window are asserted **byte-for-byte against `scope_ref.capture_model` for the same seed**, across pretrig 0/64 and wrapped/non-wrapped cases. This is the design doc's "pytest green against Verilator co-sim" gate.

### Tool load-checks (manual, one-time)

The VCD and `.sr` writers are structurally validated in CI; opening them in a GUI is a manual
step (those tools aren't in CI). Last verified:
- **VCD** → GTKWave / Surfer: _pending a manual open_ (writer follows IEEE 1364 §18).
- **sigrok `.sr`** → PulseView: _pending a manual open_ (writer follows libsigrok `srzip` v2).
