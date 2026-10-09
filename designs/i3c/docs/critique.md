# Completeness Critique — Requirements & Architecture

# Completeness & Risk Review — I3C SDR+IBI Target (requirements + architecture/formal plan)

Scope note: no RTL exists yet (`/home/tcovert/projects/i3c_endpoint_formally_verified/rtl/` and `/formal/` are empty/planned), so this is a review of the two documents only. Findings are ordered by severity within each requested category. I am being deliberately skeptical: several "covered" items have latent holes that will produce a non-conformant or unsound result if shipped as-is.

---

## 1. Formal-plan soundness & bus-contention safety (the #1 risk area)

### HIGH — F-1: The abstract bus model cannot observe push-pull contention, which is exactly where contention happens
The harness model (Appendix 1, §1.1 formal note) is `sda_bus = target_drive_low ? 1'b0 : other_drivers`. This is an **open-drain-only / wired-AND** model: it represents the Target pulling Low, never the Target *driving High*. But the Target drives push-pull during read data, read/IBI T-bits, MDB and STOP-handoff (BUS spec §0.2). The single biggest correctness risk on an open-drain bus — Target driving High while another agent drives Low (or vice-versa) — is **invisible** to this model. S2 ("never High in OD") and S9 ("contention freedom") are therefore vacuously/partially true: S9 as written (`!(target_drive_low && controller_drive_high_pp)`) checks the wrong polarity (controller doesn't actively drive High on an OD bus; the *pull-up* does), and never checks Target-High-vs-other-Low.
**Fix:** Model each driver as an explicit `(oe, o)` pair with a real resolution function and a contention monitor: `assert !(tgt_oe && ctl_oe && (tgt_o != ctl_o))`. Restate S9 as that disagreement check across *all* phases (OD and PP), and add the controller env-model's `(ctl_oe, ctl_o)`. Without this, OQ-36's "harness soundness" question is unanswered and the whole §4.A safety section is weaker than it looks.

### HIGH — F-2: No single-owner / one-hot property on the internal SDA drive mux
Five blocks can assert SDA: `i3c_bit_engine`, `i3c_daa`, `i3c_framer` (T-bit), `i3c_protocol_fsm` (ACK), `i3c_ibi`. There is **no property that at most one source drives at a time**. An internal mux conflict (two sources asserting `sda_oe`/`sda_o` in the same cycle) is a classic source of contention and X-propagation that none of S1–S9 catch.
**Fix:** Centralize drive in one mux and prove `$onehot0({daa_drive_req, ibi_drive_req, framer_tbit_req, fsm_ack_req, bitengine_req})`, plus `sda_oe == selected_source.oe`. Add to Slice 2 exit criteria.

### HIGH — F-3: START/STOP/Sr detection is not gated against the Target's own SDA activity
The frontend (§1.2) detects START/STOP as "SDA edge while SCL high," and BUS-STOPSR-01 says detectors are "live in every state." But during Target-driven push-pull read/IBI, the Target owns SDA. The T-bit "park-High then release" deliberately creates an SDA transition while SCL is High (that is how the Controller's abort-Sr is detected, RD-ABORT-01). If detection is not qualified, the Target can mistake its *own* release/drive for a START/STOP, and conversely must correctly attribute a real Sr only when it has released. The spec hides the requirement inside the prose qualifier "while the Controller controls SDA," but neither the architecture nor any property makes it explicit.
**Fix:** Qualify START/STOP/Sr detection with `!sda_oe` (Target not driving) or an explicit "bus is controller-controlled / open-drain" phase flag. Add property: `(sda_oe && push_pull) |-> !(start_stb || stop_stb)` except the defined T-bit release window. This is both a behavior gap and a missing safety property.

### MED — F-4: Missing "push-pull drive only when entitled" invariant
S2 forbids High in OD; nothing bounds *when* push-pull drive is legal. A bug that enters push-pull during another Target's Direct segment, before its own ACK, or after an abort would not be caught.
**Fix:** `(sda_oe && push_pull_mode) |-> (read_data_owned && da_match && !aborted && da_valid) || (ibi_payload_phase && ibi_acked) || stop_handoff`. Complements S7/CCC-FORM-01.

### MED — F-5: IBI OD→PP handoff has no contention property
IBI-MDB-01 hands off from Controller-driven ACK-Low to Target push-pull MDB. The defined sequence (drive Low after ACK's SCL-rising, PP on next falling) is contention-safe only if the Target never drives PP-High while the Controller still holds the ACK Low.
**Fix:** `(ibi_ack_slot || ibi_ack_to_mdb_window) |-> !(sda_oe && push_pull && sda_o==1)`.

### MED — F-6: Liveness ("never hang") is not actually proven; the E9 watchdog is unsound as a safety assertion
The plan correctly notes `s_eventually`/`until`/`throughout`/`##[1:$]` are unavailable (no Verific in open-source yosys) and rewrites to bounded-safety + cover. Good — but the consequence is that SAFE-09 / ERR-REC-RESYNC-01 ("never permanently hang") is **not** discharged; only "recovery_event ⇒ idle" and "idle is reachable in some trace" are. Worse, E9's `in_error && stuck_cnt==MAX |-> 1'b0` is **false** without a controller-fairness assumption (a Controller that never issues STOP/HDR-Exit legitimately leaves the Target in error forever); adding the fairness `assume` turns it into a conditional, non-safety property.
**Fix:** State explicitly that true liveness is out of formal scope; keep (a) "recovery_event ⇒ idle" safety, (b) cover witnesses, and (c) the watchdog only as a *cover* (`cover(in_error ##[1:MAX] idle)`), not an assert. Document the fairness assumption as a known gap closed by simulation. Don't claim SAFE-09 is "proven."

### MED — F-7: K-induction budget ignores invariant strengthening and deep counters
Many properties are tagged "K-IND" (S2,S3,S4,S8, A1–A4, C10, I1, I3, I9, R2, R6, V-section). In practice k-induction on FSMs with sticky error/HDR flags returns spurious CEXs from unreachable induction-base states, and counter-bound properties (I9 `payload_cnt<=max`, RD-MRL) need the bound as an auxiliary lemma. None of this effort is budgeted.
**Fix:** Plan for helper invariants / `assume`d reachable-state predicates per block; expect several K-IND items to need depth bumps or BMC fallback. Add this to each slice's risk.

### MED — F-8: Timer-threshold abstraction means the real bus-timing requirements are never formally checked
tAVAL≥1µs, tIDLE≥200µs, tBUF, 60/150µs, 50ms become down-counters; at 100 MHz, tIDLE alone is ~20k cycles and BMC to those depths is infeasible, so the plan shrinks them for proof. That is fine but it means BUS-FREE-01/AVAIL-01/IDLE-01, RD-WD-01, ERR-REC-60US are verified only at *toy* thresholds; the real numbers (OQ-21) are covered only by sim/STA.
**Fix:** Make every threshold a parameter with a formal-small override; prove the *flag-consumption* logic (`ibi_start |-> bus_available`) at any threshold, and separately assert the counter monotonicity/terminal-flag relationship. Explicitly mark the absolute-ns values as sim/STA-only and freeze OQ-21 before RTL.

### LOW — F-9: Assume-guarantee composition can be unsound; contract consistency not enforced
Slice 10 abstracts neighbors "where BMC depth explodes." Every `assume` used in one block (edge cadence, restricted-DA, `!group_match`, single-retry) must be a *proven* `assert` somewhere, or the decomposition is unsound.
**Fix:** Maintain an explicit assume↔assert ledger; add a CI check that each environment `assume` has a matching proven property.

---

## 2. Missing / under-specified Target behaviors

### HIGH — B-1: GETSTATUS ACK-gating contradicts the "always answerable" mandate
The chosen ACK gate is `ack_da = da_valid && accept_en && fifo_can_accept && !pending_error` (§0, ACK-DA-01/OQ-1). But CCC-GETSTATUS-AVAIL-01 (MUST) requires GETSTATUS to be answered to the DA **even while busy/NACKing other CCCs**, and CCC-STAT-02 makes GETSTATUS the *read-to-clear* path for `proto_err`. Gating the directed-address ACK for a GETSTATUS segment on `accept_en`, `fifo_can_accept`, and especially `!pending_error` will (a) wrongly NACK a mandatory GETSTATUS, and (b) make the error self-clearing mechanism unreachable when an error is pending — a deadlock of the recovery story.
**Fix:** The address-ACK for a segment whose latched CCC is GETSTATUS (and the identity GETs/GETCAPS, which are constant and FIFO-independent) must bypass `accept_en`/`fifo_can_accept`/`!pending_error`. Make K7 prove the bypass explicitly: `(match_da && pending_ccc==GETSTATUS && da_valid) |-> ack_drive` regardless of those gates.

### HIGH — B-2: Wildcard CCC default-case behavior is the most important CCC property and is only partially asserted
K6 proves *known-unsupported* Direct codes NACK (table-driven), and C7 proves *named* ignore-class broadcasts don't error. Neither proves the **default case for an unknown code**: an arbitrary Direct code (bit7=1) not in the table must NACK, and an arbitrary Broadcast code (bit7=0) not in the table must be consumed with no register change and no `proto_err`. This is exactly where forward-compat and new CCCs (e.g., MLANE 0x2D/0x9D, and any v1.2+ additions) land.
**Fix:** Add two wildcard properties over a free `ccc_code`: `(direct && match_da && !in_supported_set(ccc_code)) |-> !ack_drive` and `(broadcast && !in_supported_set(ccc_code)) |=> $stable(functional_regs) && !proto_err`. Drive `ccc_code` as a free input, not from the enumerated set.

### MED — B-3: Read T-bit forced-termination vs controller over-read is unhandled
RD-MRL-01 forces T=0 at MRL, and TX_DATA[8]=`last` forces T=0. OQ-29 flags the precedence but no behavior is defined for the Controller continuing to clock *after* a T=0 (genuine last byte). After signaling end-of-data, the Target has released and must not drive further; an over-clocking Controller will read the released (High) line.
**Fix:** Define and assert: after a T=0 read T-bit, `!sda_oe` until Sr/STOP; data path does not advance. Resolve MRL-vs-app-last precedence (MRL wins → T=0).

### MED — B-4: HDR-Exit (4 falls) and TRP (14 transitions) share a counter that counts different things
§1.5 says "shared SDA-*falling-edge* counter" but RST-TRP-01 counts **14 transitions** (both edges) while HDR-EXIT-02 counts **4 falls**. A single counter cannot natively be both without a precise mapping, and getting it wrong either misses a reset or false-triggers one (SAFE-08). RST-TRP-03/R2 only assert "Exit≠Reset trigger," not that the counting basis is correct.
**Fix:** Specify one transition counter; define HDR-Exit = 4 High→Low transitions with SCL held Low + STOP, and TRP = 14 transitions ending SDA-High + Sr + STOP, from the *same* transition stream. Add a property that a 4-fall Exit pattern never advances the TRP-trigger path and vice-versa, keyed off the exact counts.

### MED — B-5: MWL/MRL reset defaults and max are undefined → RD-MRL-01 may be vacuous or wrong
RD-MRL-01 asserts `read_byte_count <= mrl_reg`, but the power-on default, min, and max of MRL/MWL (OQ-32) are unset. If MRL resets to 0, reads are blocked; if it resets to all-ones/unbounded, the bound is meaningless. The "leave unchanged on out-of-range" policy needs concrete limits to be testable.
**Fix:** Freeze reset defaults and max for MWL/MRL/MaxIBIPayload; encode them as params; make C3's range check use them. Decide whether MaxIBIPayload counts the MDB (OQ-30) — this changes I9.

### MED — B-6: Escalation-arm survival across peripheral reset has no CDC/retention property
RST-ESC-03 requires `escalation_armed` to survive a Peripheral reset (always-on domain), but the 2nd-TRP detection happens in the freshly-reset `sys_clk` domain and must cross into the always-on logic that gates whole-reset. No property verifies (a) the arm flag is in a domain not cleared by peripheral reset, or (b) the cross-domain trigger is metastability-safe.
**Fix:** Put `escalation_armed` + `reset_action_reg` in a separate reset domain (already planned, OQ-16) and add: `peripheral_reset |-> $stable(escalation_armed) && $stable(reset_action_reg)`; plus a 2-FF synchronized cross-domain trigger and its assertion.

### MED — B-7: IBI deferral on Private-transaction collision (IBI-DEFER-01) is under-specified for proof
I8 sketches the double-NACK Private-Read and Private-Write-wins cases but the exact tie/inconclusive handling ("re-arm, not success") and the back-off-then-retry path are not pinned to concrete state transitions.
**Fix:** Enumerate the four collision outcomes (addr+RnW combinations) as a truth table and assert each maps to {ACK-write-defer-IBI, double-NACK-defer-IBI, win-IBI, re-arm}. Cover that a deferred IBI re-attempts only after the next Bus-Available.

### LOW — B-8: proto_err set/clear race and partial-GETSTATUS-read clearing
E10/CCC-STAT-02 assert set and clear but not (a) simultaneous new-error + GETSTATUS-read (set must win), nor (b) whether `proto_err` clears if the Controller aborts the GETSTATUS read before the LSB (which carries the bit) is actually transferred.
**Fix:** `(protocol_error_event && getstatus_read_complete) |=> proto_err` (set wins); clear only on completion of the byte that conveyed the bit.

---

## 3. CCC coverage gaps

- **MED — C-1: GETCAP3 Format-2 bit index is genuinely ambiguous (OQ-26).** Prose says bit4=GETCAPS-Format-2, Table 63 labels bit3=GETCAPS-DB / bit4=GETSTATUS-DB. Shipping the wrong bit yields a non-conformant capability byte and controller misbehavior. **Fix:** resolve against the normative MIPI table (not prose) before RTL freeze; encode as a single named param so C12 pins it.
- **LOW — C-2: New/forward CCC codes (MLANE 0x2D, and any v1.2 additions) are only implicitly covered** by the "Reserved/N-marked/0xFF" umbrella. This is fine *iff* B-2's wildcard default-case property is added. Without it, the umbrella is asserted only for the enumerated list.
- **LOW — C-3: GETMXDS NACK with BCR[0]=0 is conformant only if tSCO≤20 ns is actually met (OQ-24/ELE-TIM-02).** If the FPGA path can't meet tSCO≤20 ns, BCR[0] must become 1 and GETMXDS becomes mandatory — flipping the table entry, GETCAP, and several properties. Flagged but treat as a gating pre-condition, not an assumption.
- **Confirmed adequately covered:** ENEC/DISEC, RSTDAA/ENTDAA, SET/GET MWL/MRL, SETDASA/SETAASA/SETNEWDA, GETPID/BCR/DCR, GETSTATUS, GETCAPS, RSTACT, ENTHDRx-tolerate, GETACCCR/PRECR/CRHDLY/SETBRGTGT/SETROUTE/SETXTIME NACK, deprecated 0x86 NACK. The list is unusually complete.

---

## 4. Clocking / CDC and Avalon-MM compliance

### HIGH — D-1: 50 MHz `sys_clk` floor cannot reliably sample the minimum bus pulses; the plan contradicts itself
ELE-TIM-01 requires tolerating tHIGH≥24 ns (pure) and tDIG_H≥32 ns, and §2.1 itself states "min pulse ≥ 3 samples after synchronizer latency" — yet it also offers a 50 MHz floor. At 50 MHz (20 ns), a 24 ns High is ~1.2 samples; after a 2–3 FF synchronizer it can be **missed entirely**, dropping an SCL edge and thus a data bit. Three samples on a 24 ns pulse needs ≥~125 MHz; on 32 ns, ≥~94 MHz. This is a real, formal-invisible correctness risk (the upper-layer proofs use idealized edge strobes and will never see a missed pulse).
**Fix:** Raise the floor to ≥100 MHz (prefer 125–160 MHz) and make it a derived requirement: `sys_clk_period ≤ min(tHIGH_min, tDIG_H_min)/3 − sync_latency`. Add a frontend-level cover that a minimum-width pulse is captured at the chosen rate. Document that this is closed by STA/sim, not formal.

### HIGH — D-2: Avalon-MM V1 fixed-latency `$past` model is invalid for waitrequest/pipelined reads, and there is no in-order/no-overtake scoreboard
`readdatavalid |-> $past(read_accepted, latency)` assumes a *constant* latency, but the agent mixes register reads (could be fixed-latency) with FIFO pops that need `waitrequest` (variable latency). With `waitrequest`/`readdatavalid` you cannot use a fixed `$past`. Also nothing bounds responses ≤ requests or response ordering.
**Fix:** Replace V1 with a counter scoreboard: `outstanding++` on accepted read (`read && !waitrequest`), `outstanding--` on `readdatavalid`; assert `readdatavalid |-> outstanding>0` and `outstanding` never underflows/overflows. If you want fixed `$past`, you must commit to a no-waitrequest fixed-latency-N agent for *all* reads (then FIFO-empty reads must return a status flag, not stall).

### MED — D-3: RX_DATA read is a destructive (pop) side-effect read — Avalon hazard
`RX_DATA` read pops the FIFO. If a read is asserted under `waitrequest` and the master re-presents it, or if the pop fires on address-accept rather than on the response beat, bytes are silently lost (violating R-MWL-04/no-silent-loss intent).
**Fix:** Pop exactly once, on the cycle `readdatavalid` is asserted for that transaction, never on command accept; add property `rx_pop |-> (readdatavalid && addr==RX_DATA)` and a no-double-pop check.

### MED — D-4: Dual-clock FIFO CDC can't be verified with multiclock SVA in open-source yosys
The plan allows a separate Avalon clock with async Gray FIFOs and promises "Gray-pointer CDC assertions," but multiclock assertions require Verific (forbidden per §4.0). True cross-clock SVA is therefore unavailable.
**Fix:** Make Avalon clock = `sys_clk` the *default and verified* configuration. If dual-clock is mandated, verify CDC with single-clock abstractions only: per-domain Gray-counter invariants (`$onehot0(gray ^ $past(gray))` — at most one bit changes), pointer no-overflow, and a black-box FIFO model with `assume`d synchronizer behavior — and document that the crossing itself is closed by `set_false_path`/STA + structural review, not SVA.

### MED — D-5: SDA/SCL travel through *separate* synchronizer chains → relative skew at the sampling instant
Sampling SDA at the detected `scl_rising_stb` can capture SDA from a slightly different time than the value that was stable during SCL-High, because the two 2–3 FF chains have independent metastability resolution. At 24–32 ns stability this is marginal.
**Fix:** Sample SDA into a holding reg one sync-stage deeper and align to the *qualified* SCL edge; or oversample and majority-vote SDA across the SCL-High window. Add a frontend cover for the alignment. This is an STA/architecture fix, not an SVA one.

### LOW — D-6: byteenable handling on W1C/RO register fields has no property
Partial-byte writes to `INT_STATUS` (W1C) or to RO/`RW@init` identity regs could corrupt or spuriously clear bits.
**Fix:** Assert RO/`RW@init` regs are stable under any Avalon write post-init (extend V4 to include partial byteenable), and that W1C only clears bits whose byteenable is set.

### LOW — D-7: `waitrequest` deassert and `readdatavalid` arrival are liveness — cover only
Avalon requires every command eventually complete; that's liveness, unprovable in the subset.
**Fix:** Cover `(read && waitrequest) ##[1:N] !waitrequest` and `read_accepted ##[1:N] readdatavalid`; document as sim-closed.

---

## Top items to resolve before RTL/property freeze
1. Replace the open-drain-only bus model with a true (oe,o) resolution + contention monitor (F-1), and add the one-hot drive-owner property (F-2). Without these, the "#1 correctness risk" is not actually covered.
2. Carve GETSTATUS/identity-GET ACK out of the `accept_en`/FIFO/`pending_error` gate (B-1) — current gating breaks a MUST and the error-recovery path.
3. Gate START/STOP/Sr detection against Target SDA drive (F-3).
4. Re-architect the Avalon read-response proof as a scoreboard and fix the destructive-read hazard (D-2, D-3).
5. Raise `sys_clk` floor to satisfy the 3-sample rule for 24 ns tHIGH (D-1).
6. Add the wildcard CCC default-case properties (B-2) and resolve GETCAP3 bit index (C-1).
7. Stop claiming liveness/"never hang" is proven; demote E9 to cover and document the fairness assumption (F-6).

No files were written. Relevant (planned, not-yet-existing) locations referenced: `/home/tcovert/projects/i3c_endpoint_formally_verified/rtl/`, `/home/tcovert/projects/i3c_endpoint_formally_verified/formal/`.
