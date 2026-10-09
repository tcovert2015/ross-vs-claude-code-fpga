# Design Decisions & v1 Freeze (incorporating completeness critique)

This is the binding contract for RTL + formal properties. It resolves the open questions
with engineering defaults where possible and folds in the critique fixes
(`docs/critique.md`). Items needing a *product* decision are listed in §6.

## 1. Critique fixes adopted (these change the architecture)

- **F-1 — Real bus model.** The formal harness models every driver as an explicit
  `(oe, o)` pair resolved by a wired bus with pull-up, plus a **contention monitor**:
  `assert !(tgt_oe && ctl_oe && tgt_o != ctl_o)` in *all* phases (OD and PP).
  (`formal/i3c_bus_model.sv`.)
- **F-2 — Single-owner SDA mux.** All internal SDA drivers feed one mux
  (`i3c_sda_mux`). Integration proves `$onehot0(src_oe)` (at most one owner) and the
  mux proves resolution correctness in isolation.
- **F-3 — Bus-condition detection gated by `!sda_oe`.** START/STOP/Sr are only
  recognized while the Target is *not* driving SDA, so the Target never mistakes its
  own push-pull / T-bit activity for a bus condition. Property:
  `(sda_oe) |-> !(start_stb || stop_stb || rstart_stb)`.
- **B-1 — GETSTATUS / identity-GET ACK bypass.** The directed-address ACK for a
  segment whose latched CCC is GETSTATUS (and the constant identity GETs / GETCAPS)
  bypasses `accept_en` / `fifo_can_accept` / `!pending_error`. Otherwise a mandatory
  CCC is wrongly NACKed and the read-to-clear error path deadlocks.
- **B-2 — Wildcard CCC default case.** Properties drive `ccc_code` as a *free* input:
  unknown Direct (bit7=1) → NACK; unknown Broadcast (bit7=0) → consume, no reg change,
  no `proto_err`.
- **B-4 — One transition counter** for HDR-Exit (4 SDA H→L transitions, SCL held Low,
  then STOP) vs Target-Reset-Pattern (14 transitions, ends SDA-High, then Sr+STOP),
  derived from the *same* transition stream; property that 4-pattern never advances the
  TRP path and vice-versa.
- **D-1 — `sys_clk` floor.** Derived requirement
  `sys_clk_period <= min(tHIGH_min=24ns, tDIG_H_min=32ns)/3 - sync_latency`.
  **Floor = 100 MHz, target 125–160 MHz.** Closed by STA/sim (idealized-edge proofs
  cannot see a missed pulse). A frontend `cover` checks a min-width pulse is captured.
- **D-2 — Avalon read scoreboard.** Replace the fixed-latency `$past` model with an
  outstanding-transaction counter: `outstanding++` on `read && !waitrequest`,
  `outstanding--` on `readdatavalid`; assert `readdatavalid |-> outstanding>0`, no
  under/overflow.
- **D-3 — Non-destructive RX read.** RX_DATA FIFO pops *only* on the `readdatavalid`
  beat (`rx_pop |-> readdatavalid && addr==RX_DATA`), never on command accept; no
  double-pop.
- **F-6 — Liveness honesty.** True "never hang" is **out of formal scope** (no
  `s_eventually` without Verific). We prove (a) `recovery_event |=> idle` (safety),
  (b) `cover` that idle is reachable after each error, (c) a bounded watchdog only as a
  `cover` (`cover(in_error ##[1:MAX] idle)`), never as an assert. The controller
  fairness assumption (controller eventually issues STOP/HDR-Exit) is documented and
  closed by simulation.
- **F-9 — Assume↔assert ledger.** Every environment `assume` used to abstract a
  neighbor must be a *proven* `assert` elsewhere; tracked in `docs/assume_ledger.md`
  (CI-checkable).

## 2. v1 configuration profile (frozen)

| Parameter | Value | Notes |
|---|---|---|
| Role (BCR[7:6]) | `2'b00` Target | not controller-capable |
| BCR | `8'h07` | adv=0, virt=0, offline=0, IBI-payload=1, IBI-capable=1, maxspeed=0 |
| DCR | `8'h00` | Generic device |
| Broadcast address | `7'h7E` | |
| Restricted DA set | {7E,7F,7C,7A,76,6E,5E,3E} | `i3c_pkg::is_restricted_addr` |
| DAA payload | `{PID[47:0],BCR[7:0],DCR[7:0]}` MSB-first, 64 bits | continuous, no delimiters |
| DA assignment | ENTDAA (mandatory); SETDASA/SETAASA via `STATIC_ADDR_EN`; SETNEWDA | |
| Group addressing | none (GETCAP2[5:4]=0); matcher = {7E, DA} | group props vacuous in v1 |
| HDR | none, but **HDR-Exit + Target-Reset-Pattern detectors mandatory** | |
| Clock | single oversampling `sys_clk` ≥100 MHz; Target never drives SCL | |
| Avalon clock | default = `sys_clk` (no CDC); async-FIFO option documented, STA-closed | |
| Timers | parameterized counters; formal uses small overrides; real ns are sim/STA | |
| Target Reset | peripheral (default) + escalation→whole; reset-action/arm in always-on domain | |

## 3. SDA drive model (normative)

`sda_oe=1, sda_o=0` → drive Low. `sda_oe=0` → release (pull-up → High).
ACK = drive Low. Passive NACK = release. Open-drain phases: only drive Low or release
(never `sda_oe && sda_o==1`). Push-pull phases (read data, T-bit, IBI MDB/payload):
may drive 0 or 1. `scl_oe ≡ 0` (Target never drives SCL).

## 4. Module list & build slices
See `docs/architecture.md` §1 and §5. Foundation order: Slice 0 (identity + SDA mux +
IO wrapper + never-drive-SCL) → Slice 1 (bus front-end) → … → Slice 10 (integration).

## 5. Formal conventions
- Open-source yosys subset only (see `formal-flow-setup` memory / `docs/architecture.md` §4.0).
- Immediate assertions in clocked blocks; `f_past_valid`; `initial assume(!rst_n)`.
- Each module `foo` has `formal/foo.sby` running tasks `bmc`, `prove`, `cover`.
- Properties live in the RTL under `` `ifdef FORMAL `` or in a bound `*_props.sv`.

## 6. Decisions still requiring product input (do NOT block foundation; parameterized for now)
1. **MIPI Manufacturer ID** (PID[47:33]) — needs a real MIPI-assigned ID; default param `15'h000`.
2. **PartID / InstanceID** (PID[31:0]) and PID Type (random vs vendor-fixed).
3. **MWL/MRL/MaxIBIPayload** reset defaults & maxima, and out-of-range policy (default: leave-unchanged; defaults param'd).
4. **GETCAP3 Format-2 bit index** (prose bit4 vs Table 63 bit3) — resolve against normative MIPI table before RTL freeze; single named param `GETCAP3`.
5. **tSCO ≤ 20 ns?** If the FPGA path can't meet it, BCR[0]→1 and GETMXDS becomes mandatory (flips a CCC). Gating pre-condition, checked at STA.
6. **Whether to ship** TESTPAT / GETCAPS-Format-2 / GETMXDS at all in v1 (default: no; GETMXDS NACK since BCR[0]=0).
7. **Peripheral-reset DA retention** (affects ENTDAA re-participation after reset).
