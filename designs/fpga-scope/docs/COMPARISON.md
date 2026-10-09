# fpga-scope vs. vendor embedded logic analyzers

How the fpga-scope core compares to the incumbent in-FPGA logic analyzers: Intel/Altera
**SignalTap**, AMD/Xilinx **ILA** (formerly ChipScope), Lattice **Reveal**, and Gowin **GAO**.
The pitch is not "more features than a mature vendor GUI" — it is **one spec'd, verified,
open core that works on every FPGA and every flow, including the ones that have nothing today**
(Yosys+nextpnr). Claims below are marked ✅ shipped / 🟡 partial / 🔜 planned (v1.x/v2) /
❌ out of scope, honestly.

## Capabilities matrix

| Capability | fpga-scope | SignalTap (Intel) | ILA / ChipScope (AMD) | Reveal (Lattice) | Gowin GAO |
|---|---|---|---|---|---|
| **Vendor-neutral** (one core, any FPGA) | ✅ | ❌ Intel only | ❌ AMD only | ❌ Lattice only | ❌ Gowin only |
| **Flow-neutral** (works outside the vendor tool) | ✅ any synth incl. **Yosys+nextpnr** | ❌ Quartus | ❌ Vivado | ❌ Radiant/Diamond | ❌ Gowin IDE |
| **Open source / forkable** | ✅ Apache-2.0 SV | ❌ closed | ❌ closed | ❌ closed | ❌ closed |
| **Formally verified core** | ✅ 4 SBY properties in CI | ❌ | ❌ | ❌ | ❌ |
| Insertion: instantiate in RTL | ✅ one module, wire `probe` | ✅ (also GUI) | ✅ (also GUI) | ✅ (also GUI) | ✅ |
| Insertion: tap nets post-synth by name (no RTL edit) | 🔜 v2 netlist flow | ✅ node finder | ✅ `MARK_DEBUG` | ✅ Inserter | ✅ |
| Runtime-reconfigurable trigger (no rebuild) | ✅ via CSR | ✅ | ✅ | ✅ | ✅ |
| Comparator/value/mask trigger | ✅ 4 units | ✅ | ✅ match units | ✅ trigger units | ✅ |
| Per-bit edge trigger | ✅ rising/falling | ✅ | ✅ | ✅ | ✅ |
| Sequential / state trigger | 🟡 4-stage sequencer + occurrence counts | ✅ state-based | ✅ trigger FSM language | ✅ sequential TE | 🟡 |
| Pre/post-trigger position | ✅ any split | ✅ | ✅ | ✅ | ✅ |
| Segmented / multi-window capture | ✅ N windows per arm | ✅ segments | ✅ capture control | 🟡 | 🟡 |
| Storage qualification (store only qualified cycles) | 🔜 v2 | ✅ | ✅ | ✅ | 🟡 |
| Compression | ✅ optional RLE | ❌ | ❌ | ❌ | ❌ |
| Timestamps | ✅ 48-bit | 🟡 | 🟡 | 🟡 | 🟡 |
| Cross-instance / cross-core trigger | ✅ `trig_ext_i/o` | 🟡 | ✅ trigger in/out | 🟡 | 🟡 |
| Multiple independent probe groups | 🔜 v2 (single group v1) | ✅ many cores | ✅ many ILAs | ✅ | ✅ |
| Decimation / sample-rate control | 🔜 v1.1 CSR | ✅ | 🟡 | 🟡 | 🟡 |
| Transport: JTAG (vendor cable) | 🔜 v2 | ✅ | ✅ | ✅ | ✅ |
| Transport: **UART** (any $2 dongle) | ✅ built in | ❌ | ❌ | ❌ | ❌ |
| Transport: on-chip bus (Avalon-MM / AXI-Lite) | ✅ | ❌ | 🟡 (AXIS-FIFO tricks) | ❌ | ❌ |
| Transport: raw byte stream (bring your own link) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Waveform viewer | ✅ **open**: GTKWave / Surfer / PulseView | 🟡 proprietary GUI (+VCD export) | 🟡 Vivado GUI (+VCD/CSV) | 🟡 Reveal Analyzer | 🟡 GAO GUI |
| Output format | ✅ VCD (IEEE 1364) + sigrok `.sr` | proprietary + VCD | proprietary + VCD/CSV | proprietary | proprietary |
| Scriptable / CI-friendly host | ✅ `pip install`, CLI, text | 🟡 Tcl | 🟡 Tcl/XSDB | 🟡 | 🟡 |
| Live streaming capture | 🔜 v2 | 🟡 | 🟡 | ❌ | ❌ |

## Where fpga-scope wins today

- **It runs where the others can't.** Yosys+nextpnr, mixed-vendor shops, and anyone who wants
  the same instrument on an iCE40, an ECP5, an Agilex 3, and a Spartan gets *one* core with one
  host tool and one waveform workflow. The vendor tools are each a walled garden.
- **No JTAG cable required.** A UART over a $2 USB dongle drains a capture; a CSR window lets a
  soft-core or an existing Avalon/AXI fabric read it out. You are not tied to a vendor programmer.
- **Open, spec'd, verified.** A frozen `INTERFACES.md`, self-checking Verilator testbenches, and
  four SBY formal proofs (trigger sample never lost; write pointer frozen in DONE; RLE never
  expands; drain never pops an empty FIFO) all run in CI. You can read, fork, and trust the core.
- **Open output formats.** VCD and sigrok `.sr` open in tools you already have; nothing is locked
  in a proprietary waveform database.
- **RLE compression** stretches a fixed BRAM buffer over far more real time on slow-changing
  buses — a feature none of the vendor ILAs offer.

## Where the vendor tools still win (tracked as capability-gap issues)

Mature vendor GUIs lead on convenience and a few capabilities fpga-scope defers to v2. These are
filed as enhancement issues so the gap is explicit, not hidden:

- **JTAG transport** ([#15](https://github.com/fpga-professional-association/fpga-scope/issues/15)) —
  the vendors drain over the JTAG cable you already have; fpga-scope v1 is UART/CSR (the single
  most-requested parity item, especially with a USB-Blaster on hand).
- **Post-synth net tapping** ([#16](https://github.com/fpga-professional-association/fpga-scope/issues/16)) —
  insert by net name without editing RTL (SignalTap node finder, Vivado `MARK_DEBUG`).
- **Storage qualification** ([#17](https://github.com/fpga-professional-association/fpga-scope/issues/17)) —
  store only cycles that meet a condition; fpga-scope v1 offers RLE but not conditional storage.
- **Advanced trigger state machine** ([#18](https://github.com/fpga-professional-association/fpga-scope/issues/18)) —
  Vivado's trigger-FSM language / SignalTap state-based triggering are richer than the 4-stage sequencer.
- **Multiple independent probe groups** ([#19](https://github.com/fpga-professional-association/fpga-scope/issues/19)),
  **decimation** ([#20](https://github.com/fpga-professional-association/fpga-scope/issues/20)), and
  **live streaming** ([#21](https://github.com/fpga-professional-association/fpga-scope/issues/21)) — deferred to v1.1/v2.
- **Integrated GUI setup + waveform** — the vendor tools bundle capture setup and a viewer;
  fpga-scope uses a CLI + external open-source viewers by design.
