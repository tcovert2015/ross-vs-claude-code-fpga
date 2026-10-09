# fpga-scope on the Arrow AXC3000 — board demo (#12)

An `fpga-scope` instance instrumenting a **real HyperRAM controller** on the Arrow **AXC3000**
devkit (Agilex 3 `A3CY100BM16AE7S`). The scope watches the HyperBus bring-up nets (`cs_n`, `rwds`,
the controller/front-end FSM states, the Avalon handshake) during a live transaction, triggers on
the `cs_n` falling edge (transaction start), and drains a run-length-compressed capture over the
existing JTAG-to-Avalon control plane — **zero extra board pins**.

## Provenance

The base design is the proven HyperRAM bandwidth build at `../../../hyperram/fpga/axc3000/`
(bw.qpf/qsf, top.sv, the `bw_sys` Qsys system = IOPLL + reset + **JTAG-to-Avalon master**, and the
GPIO-cell HyperBus I/O layer). `top_scope.sv` here is that repo's `top.sv` with one addition — an
`fpga-scope` instance as a **third JTAG-Avalon slave** — and `scope_bw.qsf` references the HyperRAM
base *in place* (the Qsys `.qip` use `$::quartus(qip_path)`-relative paths). The HyperRAM datapath
is untouched.

## Architecture

```
bw_sys (Qsys): IOPLL + reset + JTAG-to-Avalon master   ── one byte-addressed Avalon master ──┐
                                                                                             │
   top_scope.sv address decode on m_address:                                                 │
     [10]=1  0x400  ── fpga-scope CSR (XPORT="CSR", native bus) ──► u_scope  ◄── probe ── ────┤
     [8]=1   0x100  ── hyperbus_capture (existing 1024-deep debug ILA)                        │
     else    0x000  ── hyperram_bw_test CSR                                                   │
                                                                                             │
   probe[31:0] = registered tap of the HyperBus controller nets (see probes.json):           │
     cs_n, ck_en, dq_oe, rwds_oe/o/i, rd_arm, rst_n, fe_state[1:0], ctrl_state[3:0],          │
     av_read/write/wait/rvalid, ctrl_seg[5:0], dq_o_A[7:0]                                     │
```

Demo config: `PROBE_W=32`, `DEPTH_LOG2=12` (4096 words), `RLE_EN=1`, `XPORT="CSR"`. The scope core
runs in the `clk` domain (CK ≈ 175 MHz) — no `clk2x` crossing, so probes are sampled directly.

## Build (headless, docker Quartus-Pro 26.1)

`set_global_assignment` paths are literal (the `.qsf` reader does not expand Tcl vars). Mount the
projects parent as `/workspace` so the HyperRAM base and the scope RTL are both visible:

```bash
QPRO() { docker run --rm -i --user $(id -u):$(id -g) -e HOME=/tmp \
  -v /home/tcovert/projects:/workspace \
  -v /dev/null:/usr/lib/x86_64-linux-gnu/libudev.so.1 \
  -w /workspace/fpga-scope/fpga/axc3000 alterafpga/quartus-pro:26.1-agilex3 "$@"; }

QPRO quartus_sh --flow compile scope_bw -c scope_bw    # ~20 min; -> output_files/scope_bw.sof
```

The `bw_sys` Qsys system is already generated in the HyperRAM tree, so no `qsys-generate` is needed.
Result: **timing-clean** ("Timing requirements were met") at the 175 MHz build clocks.

## Program + capture (USB Blaster III over usbipd/WSL2)

The board attaches to WSL with `usbipd.exe attach --wsl --busid <id>` (run once per boot from
Windows, or from WSL via the interop). Board access holds the shared lock and uses a **root
`--privileged`** container with `/dev/bus/usb` mounted:

```bash
PGM() { docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb \
  -v /home/tcovert/projects:/workspace \
  -w /workspace/fpga-scope/fpga/axc3000 alterafpga/quartus-pro:26.1-agilex3 "$@"; }

flock -w 300 /tmp/axc3000-devkit.lock -c 'PGM quartus_pgm -c 1 -m jtag -o "p;output_files/scope_bw.sof"'

# capture: jtagconfig primes jtagd first (system-console alone finds no devices in a fresh container)
flock -w 300 /tmp/axc3000-devkit.lock -c \
  'PGM bash -c "jtagconfig >/dev/null 2>&1; sleep 1; system-console --script=sysconsole/scope_capture.tcl scope_dump.txt 64 64"'

# reconstruct a VCD (+ sigrok) from the drained words (word-domain reorder + rle_decode, host codec)
python3 reconstruct.py scope_dump.txt --vcd ../../docs/captures/axc3000_hyperram_cs.vcd --sr ../../docs/captures/axc3000_hyperram_cs.sr
python3 reconstruct.py scope_dump.txt --vcd ../../docs/captures/axc3000_hyperram_cs_focus.vcd --around 3000
```

`scope_capture.tcl` arms the scope with a **cs_n-falling-edge** trigger (comparator 0, edge_mask
bit0 / edge_pol 0), waits until the core reaches ARMED (FILLING drains the word-domain PRETRIG
backlog first), then pulses `hyperram_bw_test` so `cs_n` actually falls, polls for DONE, and drains
the 4096 RLE words. `reconstruct.py` reuses the `fpgapa_scope` host package (`reorder_window` +
`rle_decode_words` + `write_vcd`/`write_sr`) — the exact DRAIN reconstruction, in the word domain.

## Result (real silicon)

Read back from the device: `SCOPE ID = 0x5C09E001`, `HWCFG = 0x00053020` (PROBE_W=32, DEPTH_LOG2=12,
RLE_EN=1). A capture triggered on the `cs_n` falling edge (`triggered=1, wrapped=1, trig_index=250`,
`ts_at_trig=0xAB5267F07`) and drained 4096 words → `docs/captures/axc3000_hyperram_cs.vcd`. The
focused view (`_focus.vcd`, ±3000 samples around the trigger) shows one HyperBus transaction:
`cs_n` toggling, `ck_en` gating, `dq_oe` asserting through the CA + write phases, and `ctrl_state`
stepping through the controller FSM (17 transitions; 10 distinct states across the full capture).

> Note: with `RLE_EN=1` a mostly-idle `cs_n` compresses to count words, so the full decoded timeline
> is long (idle runs between transactions); the `_focus.vcd` is the demo-friendly window. PRETRIG is
> word-domain under RLE, and a window that opens mid-idle-run drops its leading (unreconstructable)
> count — see docs/DESIGN.md.

## Utilization (demo config, Agilex 3, this build)

| Resource | scope_bw total | of which `u_scope` |
|---|---|---|
| ALMs | 4,388 / 34,000 (13%) | scope core + CSR + trigger + RLE + drain |
| M20K | 15 / 262 (6%) | **9** (8 = 4096×33 capture buffer, 1 = 256×13 window-meta) |
| Timing | met (175 MHz) | — |

The 4096×33-bit capture buffer maps to exactly **8 M20K = 135,168 bits** — the raw BRAM cost with no
bloat (meets the design-doc §9 "≤ ~1.2× raw BRAM" target). See `fpga/util_sweep/` for the scripted
3×3 PROBE_W×DEPTH_LOG2 sweep.

## Files

| File | Role |
|---|---|
| `top_scope.sv` | HyperRAM `top` + the fpga-scope JTAG-Avalon slave (provenance in-file) |
| `scope_bw.qsf` | Quartus project (references the HyperRAM base in place + scope RTL) |
| `probes.json` | 32-bit probe → named-signal map (consumed by the host tool + reconstruct.py) |
| `sysconsole/scope_capture.tcl` | System Console: configure → arm → trigger → drain over JTAG |
| `reconstruct.py` | dump → VCD/sigrok via the fpgapa_scope host reconstruction |
