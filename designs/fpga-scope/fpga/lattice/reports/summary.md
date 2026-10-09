## Utilization (map report, `reports/<cfg>/map.mrp`)

| PROBE_W | Depth (2ᴺ) | LUT4 | of which logic / ripple / distributed RAM | registers | EBR blocks | of which capture buffer / win-meta | buffer bits |
|---|---|---|---|---|---|---|---|
| 32 | 256 (N=8) | 1,907 / 32,256 | 1355 / 360 / 192 | 1,198 / 32,811 | 2 / 84 | 1 / 1 | 8,448 |
| 32 | 4096 (N=12) | 2,030 / 32,256 | 1442 / 396 / 192 | 1,228 / 32,811 | 10 / 84 | 9 / 1 | 135,168 |
| 32 | 32768 (N=15) | 2,120 / 32,256 | 1514 / 414 / 192 | 1,251 / 32,811 | 67 / 84 | 66 / 1 | 1,081,344 |

Large RAMs (LRAM) used: w32_d8: 0, w32_d12: 0, w32_d15: 0.

## Timing (post-route STA, `reports/<cfg>/timing.twr`, clk = 10.000 ns)

| cfg | worst setup slack | setup slack 85 °C / 0 °C | Fmax (worst corner) | worst hold slack | timing errors (setup 85 / setup 0 / hold) | constraint coverage | comb. loops |
|---|---|---|---|---|---|---|---|
| w32_d8 | 1.828 ns | 1.828 / 1.890 ns | 122.369 MHz (8.172 ns) | 0.144 ns | 0 / 0 / 0 | 85.3807% | none |
| w32_d12 | 2.303 ns | 2.303 / 2.367 ns | 129.921 MHz (7.697 ns) | 0.124 ns | 0 / 0 / 0 | 86.0572% | none |
| w32_d15 | 1.412 ns | 1.412 / 1.456 ns | 116.442 MHz (8.588 ns) | 0.145 ns | 0 / 0 / 0 | 88.3501% | none |

## Warnings

| cfg | Synplify @E | Synplify @W | Synplify @N | map errors / criticals / warnings | PAR errors / warnings | unrouted |
|---|---|---|---|---|---|---|
| w32_d8 | 0 | 11 | 319 | 0 / 0 / 28 | 0 / 14 | 0 |
| w32_d12 | 0 | 13 | 316 | 0 / 0 / 28 | 0 / 14 | 0 |
| w32_d15 | 0 | 16 | 321 | 0 / 0 / 28 | 0 / 14 | 0 |

Synplify @W by message ID:

| cfg | BN132 | BW295 | CL246 | CL260 | FX107 | FX310 |
|---|---|---|---|---|---|---|
| w32_d8 | 0 | 1 | 6 | 1 | 2 | 1 |
| w32_d12 | 3 | 1 | 6 | 0 | 2 | 1 |
| w32_d15 | 6 | 1 | 6 | 0 | 2 | 1 |

Map warnings by message ID: w32_d8: 71003020 ×28; w32_d12: 71003020 ×28; w32_d15: 71003020 ×28.
