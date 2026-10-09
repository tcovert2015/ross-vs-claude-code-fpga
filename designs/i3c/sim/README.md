# Simulation Testbench

Behavioral testbench for the integrated `i3c_target_top`, run with **Icarus Verilog**
(chosen for native 4-state tri-state / pull-up on the open-drain SDA bus).

```
sim/run.sh          # compile (iverilog -g2012) + run; prints PASS/FAIL tally
```

`tb_i3c_target.sv` drives the design two ways:
- **Avalon-MM master** tasks (`avl_wr`/`avl_rd`) — the application side.
- **Bit-level I3C controller BFM** — START/Sr/STOP, `drive_bit`/`read_bit`,
  `send_byte_ack`/`send_byte_tbit`/`read_byte_tbit`, on a `tri1` open-drain bus with
  pull-up (Target drives via `i3c_io_altera`, BFM drives via tri-state). SCL/SDA are
  held `PH=8` sys_clk cycles per half-bit so the Target's 2-FF synchronizers settle.

This covers what formal cannot: real end-to-end transactions, oversampled bus timing,
and full-sequence liveness.

## Current results — 29/29 PASS

**The integrated stack works end-to-end:**
- Avalon path: PID/BCR/DCR identity, **GETCAPS** (0x0200), CTRL R/W, DYN_ADDR,
  TX-FIFO push/level, **flush_tx**.
- **I3C bus proof-of-life:** Target ACKs broadcast `0x7E+W` on the real open-drain bus.
- **Full ENTDAA:** 7E+W ACK, 7E+R ACK, 64-bit payload, assigned **DA latches as 0x08**,
  target ACKs the address.
- **Private write:** addressed write, data byte `0x5C` lands in the RX FIFO, read back
  over Avalon.
- **Private read:** DA+R ACK, target byte `0xC3` returned bit-aligned, and the read
  terminates cleanly so the Controller can form a STOP/Sr.
- **GETSTATUS:** 7E+W ACK, DA+R ACK, single-byte status response.

The three earlier read-path failures were **testbench-stimulus accuracy** in the BFM's
read-termination handshake (the first read sample landed one bit late and the imperfect
read-end left the bus mid-frame). Refining the BFM read-termination tasks — alongside the
RTL read fixes (FINDING-SIM-4 `tx_first`, FINDING-SIM-5 `read_done_q`) — brought the
private-read and GETSTATUS scenarios to PASS (**29/29**).

## Bugs this testbench found and we FIXED (formal re-verified + Quartus re-confirmed)
1. **GETCAPS/RESET read returned 0** — 4-bit `app_*_idx` aliased indices 16/17 to 0.
   Widened to 5-bit (regfile + avalon_mm + top) + added CAPS/RESET read decode.
2. **FINDING-SIM-1 — driven slots released while synced-SCL still High → false STOP.**
   Fixed with a front-end **release tail** (`OE_TAIL`): bus-condition detection stays
   gated a few cycles after `sda_oe` deasserts, so the Target's own line-release is never
   mistaken for a STOP. (Unblocked all of ENTDAA + private R/W.)
3. **FINDING-SIM-3 — DAA assigned-address byte misframed.** The shared bit engine's
   9-bit framing wasn't reset after the 64-bit continuous payload (64 mod 9 ≠ 0). Added
   `bit_resync` (DAA pulses it entering the address-receive state) → DA now latches
   correctly.
4. **FINDING-SIM-2 — flush_tx/flush_rx unwired.** Added a synchronous `clear` to
   `i3c_fifo` and wired the flush pulses.

In total, simulation found **8 integration bugs** the per-module formal proofs could not
see; **all 8 are fixed and re-verified** (the four highlighted above plus FINDING-SIM-4
`tx_first`, FINDING-SIM-5 `read_done_q`, FINDING-SIM-6 live-`rnw` CCC-ACK, and
FINDING-SIM-7 multi-byte GET response reload at `ninth_fell`). Full write-ups in
[`../docs/findings.md`](../docs/findings.md). Every fix was re-verified: full formal suite
still ALL GREEN, Quartus build still clean; internal timing meets 125 MHz (Fmax ≈ 244 MHz). See ../syn/altera/README.md for the I/O-path caveat.

## Debug aid
Set `dbg_en=1` (e.g. just before a scenario) to print per-edge internal state
(START/STOP strobes, bit_cnt, rx_byte, match_7e, ack_oe, sda_oe, daa_active).
A VCD is written to `sim/tb_i3c_target.vcd`.

## Toolchain note
Build with the project toolchain (`source tools/env.sh` → OSS CAD Suite **iverilog v14**),
which `sim/run.sh` uses. The RTL compiles cleanly under it (an explicit `state_e'(...)`
cast was added in `i3c_protocol_fsm` so the enum-from-ternary assignment is accepted by
strict iverilog as well as yosys and Quartus). A captured run is in
[`../reports/sim_run.log`](../reports/sim_run.log).
