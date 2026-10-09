# scope_top utilization sweep (issue #12)

Reproducible resource numbers for `scope_top` across **PROBE_W ∈ {32, 128, 512} × DEPTH_LOG2 ∈
{8, 12, 15}** (RLE_EN=1, so STORE_W = PROBE_W+1), on three flows. The point of the design-doc §9
target: the capture buffer should cost **≤ ~1.2× the raw BRAM** (DEPTH × STORE_W bits) plus small
control logic.

| Flow | Tool | Part | Script | Status here |
|---|---|---|---|---|
| Quartus | Quartus-Pro 26.1 | Agilex 3 `A3CY100BM16AE7S` | `quartus_sweep.sh` | **runnable** (docker image present) |
| Vivado | Vivado | any 7-series/UltraScale (synth-only OK) | `vivado_sweep.tcl`* | documented; Vivado not installed here |
| Yosys+nextpnr | OSS CAD Suite | ECP5 (`--45k`; note if 512×2¹⁵ overflows) | `ecp5_sweep.sh`* | documented; run where the part fits |

\* The Vivado/nextpnr scripts mirror `quartus_sweep.sh`: elaborate `rtl/scope_top.sv` (+ prims, +
`scope_pkg`) with the two parameters overridden per config, run synth (+ place for nextpnr), and
scrape LUT/FF/BRAM. Only the Quartus flow is exercised in this environment; the demo build's
full-fit anchor (PROBE_W=32, DEPTH_LOG2=12: 8 M20K = 4096×33 = exactly the raw buffer) is in
`../axc3000/README.md`.

Run:
```bash
bash fpga/util_sweep/quartus_sweep.sh                 # full 3x3 -> utilization_quartus.md
PWS="32" DLS="8 12 15" bash fpga/util_sweep/quartus_sweep.sh   # one width, all depths
```
