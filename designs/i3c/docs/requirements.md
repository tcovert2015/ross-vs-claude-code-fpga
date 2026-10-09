# MASTER REQUIREMENTS SPECIFICATION — I3C Basic v1.2 SDR + IBI Target (Endpoint)

Device-agnostic SystemVerilog for Altera FPGAs · Avalon-MM application interface · Open-source formal flow (yosys + SymbiYosys + SMT)

Status: contract draft for RTL + formal property development. Scope: I3C Basic v1.2, SDR Mode + In-Band Interrupt (IBI). Excludes HDR data paths, active Hot-Join, secondary/controller role (see "Deferred / Out-of-Scope" at the end).

---

## 0. Conventions, Traceability, and v1 Configuration Profile

### 0.1 Requirement notation
- **ID** — stable, functional-area-prefixed (this document is the canonical ID source). The originating extract ID(s) are listed as `src:` for traceability back to the page-level analysis.
- **Level** — `MUST` (shall), `SHOULD` (should), `MAY` (optional), `INFO` (context/scope-only, non-normative for RTL).
- **FV** — `YES` if a good formal-verification candidate (assertable as an SVA invariant/sequence in the supported subset), `no` otherwise (timing/electrical/structural/policy).
- **Page** — printed page (physical PDF page) as cited in the source extract.

### 0.2 Open-drain / drive model (normative for all properties)
- `sda_oe=1, sda_out=0` = drive Low (active). `sda_oe=0` = release to High-Z (external pull-up / Bus High-Keeper yields High).
- **ACK** = drive SDA Low during the ACK bit. **Passive NACK** = release SDA (`sda_oe=0`).
- Open-drain phases: the Target only ever drives Low or releases; it never actively sources a High in open-drain (BUS-OD-02).
- Push-pull phases (Target read data, T-bit, IBI MDB/payload, STOP-handoff): the Target may drive both 0 and 1.
- The Target **never drives SCL** (`scl_oe ≡ 0`).

### 0.3 v1 Configuration Profile (assumed design decisions — see Open Questions for those still unresolved)
| Parameter | v1 value | Drives |
|---|---|---|
| Device Role (BCR[7:6]) | `2'b00` Target | not controller-capable |
| Advanced Capabilities BCR[5] | `0` | no advanced/HDR features |
| Virtual Target BCR[4] | `0` | no group/virtual |
| Offline Capable BCR[3] | `0` | always responds |
| IBI Payload BCR[2] | build option (1 if MDB used) | IBI MDB datapath |
| IBI Request Capable BCR[1] | `1` (IBI build) | IBI engine enabled |
| Max Data Speed Limit BCR[0] | `0` if tSCO ≤ 20 ns | GETMXDS optional |
| DCR | `0x00` Generic (or registered code) | identity |
| PID[47:33] MfgID | constant strap | identity |
| Static Address | optional/compile-time | SETDASA/SETAASA |
| DA-assignment methods | ENTDAA mandatory; SETDASA/SETAASA optional | DAA |
| Group Addressing | NOT supported (GETCAP2[5:4]=0) | matcher = {7'h7E, single DA} |
| HDR | NOT supported, but HDR-tolerant (mandatory) | exit detector |
| GETSTATUS | supported (mandatory) | Format 1 |
| GETCAPS | supported (mandatory ≥2 bytes) | Format 1 |
| RSTACT / Target Reset | supported (mandatory) | reset FSM |
| Timing Control | NOT supported (GETCAP3[7]=0) | NACK SET/GETXTIME |
| Test Mode (ENTTM) | NOT supported | ignore/NACK |

---

## 1. Identity & Characteristic Registers (BCR / DCR / PID)

**ID-CHAR-01** (MUST, FV: no) — The Target MUST implement and expose BCR and DCR as bus-readable resources (via ENTDAA and GETBCR/GETDCR). A device without BCR/DCR MUST NOT be on an I3C Basic Bus. *p.34/38 (phys 70/74).* `src: R-CHAR-01, R-CHAR-02`

**ID-CHAR-02** (MUST, FV: no) — Single-role v1 Target has exactly one BCR/DCR pair, associated with its one Dynamic Address (no per-virtual-target banks; BCR[4]=0). *p.38 (phys 74).* `src: R-CHAR-03`

**ID-ROLE-01** (MUST, FV: no) — Active Target MUST fulfill all Target-role responsibilities (Table 4). Conforms to the **SDR-Only Target** row: HDR Target-capable=N, HDR Tolerant=Y. *p.34–35 (phys 70–71).* `src: R-ROLE-01, R-ROLE-03`

**ID-ROLE-02** (MUST, FV: YES) — The Target MUST NOT manage SDA arbitration, MUST NOT assign or self-assign any Dynamic Address, MUST NOT hold memory for other devices' addresses. The Dynamic Address register changes ONLY via an accepted controller assignment CCC, never self-generated.
> `assert: (dyn_addr != $past(dyn_addr)) |-> $past(da_assignment_ccc_accepted)`
*p.35 Table 4.* `src: R-ROLE-02`

**ID-BCR-01** (MUST, FV: YES) — BCR is read-only/stable from the bus (never bus-writable). Application may set straps at init only.
> `assert: bcr == $past(bcr)` (post-reset, no init-write)
*p.39 (phys 75).* `src: R-BCR-01`

**ID-BCR-02** (MUST, FV: YES) — BCR bit fields conform to Table 7: [7:6]=Role, [5]=Advanced Cap, [4]=Virtual Target, [3]=Offline Cap, [2]=IBI Payload, [1]=IBI Request Capable, [0]=Max Data Speed Limit. Role encodings `2'b10`/`2'b11` MUST NOT be used.
> `assert: bcr[7:6] != 2'b10 && bcr[7:6] != 2'b11`
*p.39 Table 7.* `src: R-BCR-02`

**ID-BCR-03** (MUST, FV: YES) — `bcr[7:6]==2'b00` (I3C Basic Target). *p.39.* `src: R-BCR-03`
> `assert: bcr[7:6] == 2'b00`

**ID-BCR-04** (MUST, FV: YES) — `bcr[1]` matches actual IBI capability; if `bcr[1]==0` the Target MUST never initiate an IBI (no IBI arbitration, never drives SDA for IBI). *p.39.* `src: R-BCR-04, R-IBI-05(annexF)`
> `assert: bcr[1]==0 |-> !ibi_request_active && !ibi_drives_sda`

**ID-BCR-05** (MUST, FV: YES) — `bcr[2]` matches IBI MDB behavior: if 1, exactly one Mandatory Data Byte follows an accepted IBI (continuation via T-bit); if 0, no payload bytes follow. *p.39.* `src: R-BCR-05, R-MDB-BCR2`
> `assert: ibi_accepted && bcr[2] |-> first_ibi_tx_byte_is_mdb;  ibi_accepted && !bcr[2] |-> no_ibi_payload_bytes`

**ID-BCR-06** (MUST, FV: YES) — `bcr[3]==0` for v1 (always responds); no power-down/offline path that drops responses to an addressed transaction. *p.39.* `src: R-BCR-06`

**ID-BCR-07** (MUST, FV: YES) — `bcr[5]==0` and `bcr[4]==0` for v1 (no advanced/virtual). *p.39.* `src: R-BCR-07`
> `assert: bcr[5]==0 && bcr[4]==0`

**ID-BCR-08** (MUST, FV: no) — `bcr[0]` matches whether a Max Data Speed Limit is enforced; if 1, GETMXDS MUST be supported. Set `bcr[0]=1` whenever tSCO > 20 ns. *p.39 + p.122 (phys 158).* `src: R-BCR-08, R-GETMXDS-02, R-TIM-02`

**ID-DCR-01** (MUST, FV: YES) — DCR is read-only/stable, exposed via ENTDAA and GETDCR; encodes Device ID per Table 8/Table 55 (default `0x00` Generic Device). *p.40 (phys 76), p.198 (phys 234).* `src: R-DCR-01, R-DCR-02, R-DCR-01(§5), R-DCR-02(§5)`
> `assert: dcr == $past(dcr); getdcr_resp_valid |-> resp_byte==DCR_CONST; entdaa_dcr_phase |-> resp_byte==DCR_CONST`

**ID-PID-01** (MUST, FV: no) — Target supporting ENTDAA MUST have a 48-bit Provisioned ID, uniquely identifiable before DAA. *p.63 (phys 99).* `src: R-PID-01`

**ID-PID-02** (MUST, FV: no) — PID field layout: [47:33]=15-bit MIPI MfgID; [32]=PID Type Selector (1=Random, 0=Vendor-Fixed); [31:0]=Vendor-Fixed Value `{PartID[31:16], InstanceID[15:12], defined[11:0]}` or 32-bit random. *p.63.* `src: R-PID-02`

**ID-PID-03** (MUST, FV: YES) — PID[47:33] (MfgID) is a hard constant; MUST NOT be randomized even in Test Mode. *p.63.* `src: R-PID-03`
> `assert: pid[47:33] == MFG_ID_CONST`

**ID-PID-04** (SHOULD, FV: no) — PID[15:12] Instance ID SHOULD uniquely identify the individual device (straps/fuses/NVM) to avoid DAA collisions. *p.63.* `src: R-PID-04`

**ID-COL-01** (MUST, FV: no) — PID-collision resolution is the Controller's job; the Target's obligation is (a) unique concatenated PID+BCR+DCR and (b) respond to RSTDAA and re-participate in DAA with the SAME PID. *p.67 (phys 103).* `src: R-COL-01`

**ID-CHAR-LVR** (INFO) — LVR applies only to legacy I2C-only devices; the I3C Target implements no LVR. *p.40.* `src: R-CHAR-04`

---

## 2. Bus Condition Detection (START / STOP / Sr, Idle / Activity / Free / Available)

**BUS-EDGE-01** (MUST, FV: YES) — The Target MUST be purely SCL-edge-driven: every bus-facing state transition and SDA-drive change is gated on a detected SCL edge; no logic may depend on measuring absolute SCL-High duration (sole exceptions: real-time watchdogs RD-WD-01, ERR-REC-60US). Tolerate arbitrary SCL duty cycle (short High < 50 ns / tDIG_H_MIXED). *p.58 (phys 94).* `src: R-CLK-02`
> `assert: (sda_oe!=$past(sda_oe) || sda_out!=$past(sda_out) || state!=$past(state)) |-> ($past(scl_rising)||$past(scl_falling))`

**BUS-CLK-01** (MUST, FV: no) — Accommodate SCL up to 12.5 MHz sustained (12.9 MHz burst). Internal sample/oversample clock MUST capture ≥32 ns half-periods and ≥32 ns tDIG_H exit-pattern edges (suggest ≥50–100 MHz, synchronized SDA/SCL). *p.58 / p.178–179 (phys 214–215).* `src: R-CLK-01, R-TIM-01`

**BUS-STOPSR-01** (MUST, FV: YES) — In SDR, the Target MUST tolerate a STOP or Repeated START at any time SCL is High while the Controller controls SDA / SDA is open-drain. A STOP or Sr mid-address or mid-data cancels that address/data; START/STOP detectors are live in every state and reset bit/byte capture and the matching FSM. *p.41 (phys 77).* `src: R-RS-01`
> `assert: ((state==ADDR_PHASE||state==DATA_PHASE) && (stop_detected||rep_start_detected)) |=> capture_cancelled`

**BUS-OD-01** (MUST, FV: no) — SDA/SCL pads MUST be true open-drain and able to pull Low within min tDIG_L using ≥ min IOL (Table 46), winning against the High-Keeper/pull-up. (IO-pad/electrical obligation.) *p.59 (phys 95).* `src: R-BUS-01`

**BUS-OD-02** (MUST, FV: YES) — In any open-drain phase the Target only drives Low or releases; it NEVER actively drives a High in OD. *p.59–60 (phys 95–96).* `src: R-BUS-02`
> `assert: open_drain_phase && sda_oe |-> sda_out==1'b0`

**BUS-FREE-01** (MUST, FV: YES) — Bus Free recognized only after a STOP followed by SDA & SCL both High for ≥ tCAS (pure) / tBUF (mixed). Free-gap timer seeded on STOP, reset on any SDA/SCL Low. Target may not drive a START Request before the free gap elapses. *p.60 (phys 96).* `src: R-BUS-03`
> `assert: start_request_drive |-> free_gap_counter >= TFREE_CYCLES`

**BUS-AVAIL-01** (MUST, FV: YES) — A Target START Request (IBI/CRR) is permitted only after a **Bus Available Condition**: Bus Free sustained ≥ tAVAL (≥1 µs; mixed Fm = tBUF−300 ns). IBI START pull-down MUST be gated by `bus_available`. *p.60 / p.176–177 (phys 212–213).* `src: R-BUS-04, R-BUS-01(elec)`
> `assert: ibi_start_drive |-> bus_available`

**BUS-IDLE-01** (MUST, FV: YES) — A device may treat the Bus as Idle only after SDA & SCL both High ≥ tIDLE (≥200 µs). v1 (no active Hot-Join) MUST NOT emit a Hot-Join Request and MUST tolerate idle periods without spurious SDA drive. *p.60.* `src: R-BUS-05`
> `assert: !hot_join_request_drive` (always)

**BUS-ACT-01** (MAY, FV: no) — ENTAS0..3 (Activity States) need not be supported and may be decoded-and-ignored (consume bytes cleanly). If supported, ENTAS0 becomes conditional. *p.61 (phys 97), p.99 (phys 135).* `src: R-ACT-01, R-AS-01, R-AS-02`

**BUS-ACT-02** (MUST, FV: YES) — The Target MUST wake on any bus activity, or on matching 7'h7E + its own DA; it MUST NOT stay asleep through an address that targets it. It MUST maintain full I3C communication capability in all Activity States. *p.61, p.99.* `src: R-ACT-02, R-AS-01`
> `assert: (addr_phase && (rx_addr==7'h7E || rx_addr==dyn_addr)) |-> !target_asleep`

**BUS-ACT-03** (MUST, FV: no) — A Target not supporting ENTASx MUST assume the tCAS max = 50 ms (ENTAS3) worst-case Controller-SCL-latency for its START-Request watchdog. *p.61, p.176–177.* `src: R-ACT-03, R-BUS-02(elec)`

**BUS-ACT-04** (MAY, FV: no) — Target may NACK accesses arriving sooner than a communicated activity interval. *p.61.* `src: R-ACT-04`

**BUS-SAMP-01** (INFO) — In SDR, SDA is sampled on SCL rising and is stable while SCL High; SDA changes only while SCL Low except START/STOP/Sr (contrast with HDR both-edge sampling). *Annex F (phys 490–491).* `src: R-FMT-SDR-SAMPLE`

---

## 3. Address Header & ACK / NACK

**ADR-7E-01** (MUST, FV: YES) — Following any START/Sr at any conforming speed, the Target MUST match 7'h7E (I3C Broadcast) and treat the message as I3C Basic SDR (`is_broadcast` flag → CCC path). *p.41/43/52 (phys 77/79/88).* `src: R-ADDR-01(4.3.2), R-ADDR-04`
> `assert: (addr_bits_complete && captured_addr==7'h7E) |-> msg_is_i3c_sdr && match_7e`

**ADR-DA-01** (MUST, FV: YES) — Once assigned, the Target MUST match its own Dynamic Address (comparator gated by `da_valid`, so DA never matches before assignment). Re-arm address capture on both START and Sr. The DA is used for all subsequent transactions. *p.41/43 (phys 77/79), p.62 (phys 98).* `src: R-ADDR-02(4.3.2), R-ADDR-RECOG-01, R-ADDR-01(4.3.4), R-FMT-04`
> `assert: (addr_bits_complete && da_valid && captured_addr==dyn_addr) |-> match_da && msg_is_i3c_sdr`

**ADR-IGN-01** (MUST, FV: YES) — If the address is neither 7'h7E nor the DA (nor a group addr, N/A in v1), the Target MUST ignore the message, MUST NOT drive the bus (incl. the ACK bit), and await the next Sr/STOP (may passively monitor). *p.41/44 (phys 77/80).* `src: R-ADDR-03, R-FMT-06, R-TOL-I2C`
> `assert: (addr_bits_complete && !match_7e && !match_da) |=> state==IGNORE;  state==IGNORE |-> !sda_oe`

**ADR-CCC-ENTRY-01** (MUST, FV: YES) — A 7'h7E header with RnW=0 (Write) means a CCC frame: after the 7'h7E ACK, the next byte is the Command Code; route to CCC decode. (A private transfer is addressed by the DA, never 7'h7E.) *p.43/82 (phys 79/118).* `src: R-ADDR-05, R-CCC-RECOG-01, R-FMT-01`
> `assert: (match_7e && rnw==0 && addr_ack_done) |=> ccc_frame_active && next_byte_is_command_code`

**ADR-ROLE-01** (MUST, FV: YES) — After DA assignment, operate only as I3C Target; stop acting as an I2C Target on the Static Address (disable static matcher + 50 ns spike filter). *p.42 (phys 78).* `src: R-ROLE-01(4.3.2)`
> `assert: da_valid |-> !i2c_static_addr_match_enabled`

**ACK-7E-01** (MUST, FV: YES) — The Target MUST ACK the 7'h7E broadcast header (drive SDA Low, open-drain, ACK bit while SCL Low), unconditionally for any attached/active Target, independent of whether the upcoming CCC is supported, and even before holding a DA. *p.42/52/85 (phys 78/88/121), Annex Fig 170.* `src: R-ACK-01, R-ACK-7E-01, R-CCC-01, R-CCC-PREDAA-01, R-FMT-01`
> `assert: (state==ACK_BIT && match_7e && scl_low) |-> sda_oe && sda_out==0`

**ACK-DA-01** (MAY→policy, FV: YES) — On a matching DA, the Target MAY ACK (drive Low) or passively NACK (release). The ACK driver is gated by an application/enable signal `accept_en`. **v1 design decision required** (see OQ-1): define whether ACK is always asserted on DA match or gated by an accept/busy signal. *p.43/50 (phys 79/86).* `src: R-ACK-02`
> `assert: (state==ACK_BIT && match_da && !accept_en) |-> !sda_oe;  (state==ACK_BIT && match_da && accept_en && scl_low) |-> sda_oe && sda_out==0`

**ACK-PROC-01** (MUST, FV: no) — After ACKing its address (DA write/read), the Target MUST fully process the SDR message (commit to data phase). *p.43.* `src: R-ACK-03`

**ACK-NACK-01** (SHOULD/MUST, FV: YES) — After NACKing its address, the Target MUST disregard following bits until the next Sr/STOP (joins the IGNORE state). *p.43.* `src: R-ACK-04`
> `assert: (state==ACK_BIT && match_da && !accept_en) |=> state==IGNORE && !sda_oe`

**ACK-OD-01** (MUST, FV: YES) — The ACK/NACK bit is ALWAYS open-drain (drive-0-or-Z), even when the preceding header was push-pull (after an Sr). Never drive SDA High during ACK. *p.50/181–183 (phys 86/217–219).* `src: R-ACK-05, R-ACK-01(elec)`
> `assert: state==ACK_BIT |-> sda_drive_mode==OPEN_DRAIN && !(sda_oe && sda_out==1)`

**ACK-COMPLY-01** (MUST, FV: YES) — On a matching address where the Target cannot comply (feature disabled, illegal/unsupported CCC, internal error), it MUST passively NACK (release SDA in the ACK slot). Conversely it drives ACK only when matched-and-enabled with no pending error. *Annex Fig 190.* `src: R-ACK-01(annexF), R-ACK-02(annexF)`
> `assert: (ack_bit_slot && sda_drive_low) |-> matched_addr && function_enabled && !pending_error`

**ADR-PREDAA-01** (MUST, FV: YES) — Before holding a DA, the Target MUST still recognize the ends of Directed CCCs it disregards (Sr+7'h7E or STOP) and MUST process required Broadcast CCCs (ENTDAA/RSTDAA/ENEC/DISEC). *p.42/43/44 (phys 78/79/80).* `src: R-RS-02, R-CCC-01`

---

## 4. SDR Private Write (Controller → Target)

**WR-NODRIVE-01** (MUST, FV: YES) — For Controller-written SDR data, the 9th bit is parity (T-bit), NOT an ACK. The Target MUST NOT drive SDA for any written data word, including its T-bit (`sda_oe=0` across all 9 bits; sample only). *p.52 (phys 88).* `src: R-WR-01`
> `assert: (state==WR_DATA || state==WR_TBIT) |-> !sda_oe`

**WR-PAR-01** (MUST, FV: YES) — Write T-bit is odd parity = `~(^Data[7:0])` (total ones incl. T odd). Combinational checker `parity_ok = (sampled_t == ~(^wr_data[7:0]))`. *p.56 (phys 92), Annex legends.* `src: R-WR-02, R-TBIT-01`
> `assert: tbit_sampled |-> (parity_ok == (sampled_t == ~(^wr_data[7:0])))`

**WR-PAR-02** (MUST, FV: YES) — A write-data parity mismatch is a protocol error feeding TE2 recovery (ERR-TE2-01) and the GETSTATUS Protocol-Error bit. (Whether/how surfaced to Avalon-MM is a product decision — see OQ-9.) *p.56, p.151 (phys 188).* `src: R-WR-02 note, R-ERR-TE2`

**WR-HANDOFF-01** (MUST, FV: YES) — On ACKing a header that begins an SDR Write: hold SDA Low during ACK while SCL Low; on the SCL rising edge release SDA to High-Z (push-pull release timing) so the Controller takes the first data bit. *p.52 (phys 88).* `src: R-WR-03`
> `assert: (state==ACK_BIT && match && accept_en && scl_rising && next_is_write) |=> !sda_oe`

**WR-MWL-01** (SHOULD, FV: YES) — Enforce the Max Write Length limit on inbound writes: writes MUST NOT overflow the application buffer; overflow beyond MWL is handled gracefully (defined abort/error). *p.102 (phys 138).* `src: R-MWL-04`
> `assert: write_msg_active && write_byte_count > mwl_reg |-> overflow_handled`

---

## 5. SDR Private Read & T-bit / Parity (Target → Controller)

**RD-PP-01** (MUST, FV: YES) — Read data bytes are driven push-pull, MSB-first, with new data appearing after the SCL edge within tSCO (≤20 ns), meeting tSU_PP ≥3 ns / tHD_PP ≥0 ns (timing via SDC, not SVA). Bytes are big-endian for multi-byte fields. *p.178/185 (phys 214/221), Annex F.3.* `src: R-RD-02, R-FMT-05`
> `assert: read_data_phase |-> push_pull_mode && sda_oe`

**RD-TBIT-EOD-01** (MUST, FV: YES) — The read 9th bit is a Target-driven **End-of-Data** T-bit (NOT parity): T=1 = more data, T=0 = end. End sequence: drive SDA Low on SCL falling, then High-Z on the next SCL rising. Continue sequence: drive SDA High on SCL falling, then High-Z on next SCL rising (park bus). *p.56 (phys 92), p.187–191 (phys 223–227), Annex Fig 189.* `src: R-RD-01, R-RD-02, R-TBIT-02, R-READ-TBIT`
> `assert: (RD_TBIT && end_of_read && scl_falling) |-> sda_oe && sda_out==0;  (RD_TBIT && end_of_read && scl_rising) |-> !sda_oe`
> `assert: (RD_TBIT && !end_of_read && scl_falling) |-> sda_oe && sda_out==1;  (RD_TBIT && !end_of_read && scl_rising) |-> !sda_oe`

**RD-RELEASE-01** (MUST, FV: YES) — After driving the read T-bit, the Target MUST release SDA on SCL-High so the Controller can continue (hold High) or abort (pull Low = Sr). *Annex Fig 189.* `src: R-TBIT-03, R-READ-TBIT`
> `assert: (read_tbit_slot && scl_high) |=> !sda_oe`

**RD-ABORT-01** (MUST, FV: YES) — After a continue (T=1) bit, sample SDA at SCL falling: High → continue next byte; Low (Sr = Controller abort) → message aborted, Target MUST NOT drive SDA thereafter and returns to address-decode. *p.57 (phys 93), Annex Fig 189.* `src: R-RD-03, R-TBIT-04`
> `assert: (after_continue_tbit && scl_falling && !sda_in) |=> state==ABORTED && !sda_oe`
> `assert: (after_continue_tbit && scl_falling && sda_in) |=> rd_next_byte`

**RD-MRL-01** (MUST, FV: YES) — The read end-of-data decision is bounded by the configured Max Read Length (MRL) counter; the Target MUST NOT return more than MRL bytes per Read Message (and ≤ Max IBI Payload for IBI; see IBI-MDB-LIM-01). *p.103 (phys 139).* `src: R-RD-01 (MRL ref), R-MRL-01`
> `assert: read_byte_count <= mrl_reg`

**RD-WD-01** (SHOULD, FV: no) — Read stall watchdog: if SCL has not changed for ~150 µs while the Target holds SDA Low during a read, abandon the read (release SDA to High-Z) and await Sr/STOP. Real-time counter; model as parameterized cycle count if formalized. *p.52 (phys 88), p.158 (phys 194).* `src: R-RD-04, R-READ-ABORT-150US`

---

## 6. Dynamic Address Assignment (ENTDAA / SETDASA / SETAASA / SETNEWDA / RSTDAA)

### 6.1 Method support
**DAA-METHOD-01** (MUST, FV: no) — The Target MUST support ≥1 of ENTDAA / SETDASA / SETAASA. For generic-bus use, **ENTDAA is mandatory in v1**. *p.64 (phys 100), p.101 (phys 137).* `src: R-DAA-01, R-DAA-ENT-03`

### 6.2 ENTDAA
**DAA-PART-01** (MUST, FV: YES) — On ENTDAA (broadcast 0x07): if no DA, participate; if a DA is held, do NOT respond / await the STOP that exits DAA (no arbitration). *p.44/101 (phys 80/137), p.64.* `src: R-CCC-03, R-DAA-ENT-01, R-DAA-ENT-02, R-DAA-03`
> `assert: (entdaa_entered && !has_da) |-> enter_daa_mode;  (entdaa_entered && has_da) |-> !daa_drive_sda`

**DAA-ACK7E-01** (MUST, FV: YES) — In ENTDAA, when the Controller sends Sr+7'h7E/R, an unassigned ENTDAA-supporting Target MUST ACK (drive SDA Low) on the ACK bit (gated `!has_da`). *p.64 (phys 100).* `src: R-DAA-02`
> `assert: (entdaa_active && addr_match_7E && rnw_read && ack_phase && !has_da) |-> sda_drive_low`

**DAA-PAYLOAD-01** (MUST, FV: YES) — After ACKing 7E/R, the Target drives its 64-bit payload `{PID[47:0], BCR[7:0], DCR[7:0]}` MSB-first, continuously, NO delimiters, NO ACK/NACK between bytes, open-drain, until it loses arbitration. *p.64–65 (phys 100–101), Annex Fig 175.* `src: R-DAA-04, R-DAA-05, R-DAA-01(annexF)`
> `assert: daa_payload_phase |-> sda_tx_bit == daa_word[63-bit_idx]` where `daa_word={pid,bcr,dcr}`

**DAA-ARB-01** (MUST, FV: YES) — Arbitration: drive Low for 0, release for 1; if it released for 1 but samples SDA Low, it has LOST — latch `arb_lost`, immediately stop driving, stay passive for the rest of the round (lowest concatenated value wins). *p.65 (phys 101).* `src: R-DAA-06, R-ARB-01/02 (4.3.2)`
> `assert: (daa_payload_phase && tx_bit==1 && sda_sampled==0) |=> arb_lost;  arb_lost |-> !sda_drive_low`

**DAA-OD-ONLY-01** (MUST, FV: YES) — The Target NEVER push-pull drives during DAA; PID/BCR/DCR and ACKs are strictly open-drain. *p.64–65.* `src: R-DAA-07`
> `assert: daa_active |-> !sda_push_pull_drive`

**DAA-RELEASE-01** (MUST, FV: YES) — On arb-loss or round completion, release SDA before the Controller drives the next Sr High (no contention with active SDA-High). *p.64.* `src: R-DAA-08`
> `assert: (arb_lost || daa_round_done) |-> sda_released` (until next ACK-7E phase)

**DAA-PAR-01** (MUST, FV: YES) — The winner receives 7-bit DA + odd-parity PAR (`PAR = ~(^DA[6:0])`, bit 0). If parity valid → ACK (drive Low) and latch DA (`dyn_addr<=rx_da; has_da<=1`); if invalid → passive NACK. *p.65 (phys 101), Annex Fig 175.* `src: R-DAA-09, R-DAA-10, R-DAA-11, R-DAA-02(annexF)`
> `assert: parity_valid == (rx_par == ~(^rx_da[6:0]))`
> `assert: (da_par_phase && parity_valid && ack_done) |=> has_da && dyn_addr==$past(rx_da[6:0])`

**DAA-RETRY-01** (MUST, FV: YES) — On DA-NACK (bad parity) the Target re-arbitrates with the SAME unchanged PID/BCR/DCR in the next round (no mutation between rounds). *p.66 (phys 102).* `src: R-DAA-12`
> `assert: da_nack_event |=> (pid==$past(pid) && bcr==$past(bcr) && dcr==$past(dcr))`

**DAA-ABORT-01** (MUST, FV: YES) — Tolerate aborted/repeated ENTDAA: a STOP at any DAA phase returns the FSM cleanly to IDLE (no deadlock), re-armable by the next ENTDAA+7E. *p.66.* `src: R-DAA-13`
> `assert: stop_detected |=> daa_fsm==IDLE`

**DAA-NOHANDOFF-01** (MUST, FV: YES) — A v1 (non-controller-capable) Target ALWAYS ACKs the assigned address "without Handoff" (never signals controller-role capability). *Annex Figs 175/180.* `src: R-TOL-CRR`

### 6.3 Static-address methods (optional)
**DAA-DASA-01** (MAY, FV: YES) — SETDASA (0x87): if supported (requires Static Address) and `!has_da`, adopt DA from Dynamic-Address-Byte[7:1]. *p.108 (phys 144).* `src: R-ADDR-DASA-01`
> `assert: (setdasa_accept && addr_match_static && !has_da) |=> has_da && dyn_addr==da_byte[7:1]`

**DAA-DASA-02** (MUST if SETDASA, FV: YES) — NACK SETDASA when a DA is already assigned; preserve existing DA. *p.108.* `src: R-ADDR-DASA-02`
> `assert: (setdasa_supported && has_da && setdasa_addr_phase) |-> nack_drive && dyn_addr==$past(dyn_addr)`

**DAA-DASA-03** (SHOULD, FV: YES) — Minimal-Bus point-to-point: match Static 7'h01 and accept DA 7'h01. *p.109 (phys 145).* `src: R-ADDR-DASA-03`

**DAA-AASA-01** (MAY/MUST, FV: YES) — SETAASA (0x29): if supported, requires Static Address; adopt Static→Dynamic only when `!has_da`; IGNORE if a DA already assigned. *p.133 (phys 169).* `src: R-SETAASA-01, R-SETAASA-02`
> `assert: (setaasa && has_da) |=> dyn_addr==$past(dyn_addr) && dyn_addr_valid`

**DAA-AASA-02** (MUST, FV: no) — A Target whose Static Address is a Restricted Address (Table 10) MUST NOT support SETAASA. *p.64.* `src: R-ADDR-04(4.3.4)`

### 6.4 SETNEWDA / RSTDAA / DA stability
**DAA-NEWDA-01** (MUST if ENTDAA, FV: YES) — SETNEWDA (0x88), addressed by current DA: change DA to new value[7:1]; thereafter respond to new DA and NOT the old DA. NACK if unsupported or if no DA yet. *p.110 (phys 146).* `src: R-ADDR-NDA-01/02/03`
> `assert: (setnewda_accept && addr_match_current_da) |=> dyn_addr==newda_byte[7:1]`
> `assert: (!setnewda_supported && setnewda_addr_phase && addr_match_current_da) |-> nack_drive;  (setnewda_addr_phase && !has_da) |-> nack_drive`

**DAA-RSTDAA-01** (MUST, FV: YES) — RSTDAA broadcast (0x06): clear the assigned DA (`has_da→0`); return to the addressable-without-DA state ready for re-assignment (ENTDAA/SETDASA/SETAASA). RSTDAA has no effect when no DA assigned. *p.101 (phys 137).* `src: R-DAA-RST-01/03, R-CCC-01`
> `assert: rstdaa_frame_complete |=> !has_da && daa_ready_state`

**DAA-RSTDAAD-01** (MUST, FV: YES) — Direct RSTDAA (0x86) is deprecated: the Target MUST NACK its address and take NO reset action (DA preserved). *p.93 (phys 129).* `src: R-RSTDAAD-01`
> `assert: (ccc_code==8'h86 && sr_seen && addr_match) |-> nack_drive`

**DAA-STABLE-01** (MUST, FV: YES) — `dyn_addr` changes ONLY via ENTDAA assignment, SETDASA, SETAASA, SETNEWDA, RSTDAA (clear), or reset; otherwise it holds across all bus activity. *p.62 (phys 98).* `src: R-ADDR-02(4.3.4)`
> `assert: dyn_addr != $past(dyn_addr) |-> (da_assign_event || setnewda_event || setdasa_event || setaasa_event || rstdaa_event || reset)`

**DAA-RESTRICT-ASSUME-01** (INFO/assume, FV: YES) — Formal environment assumption: the Controller never assigns a restricted/TE0 address (7'h7F,7C,7A,76,6E,5E,3E) as a DA, so the TE0 comparator is a fixed-code check. *p.151 (phys 187).* `src: R-TE0-04`
> `assume: da_assign_valid |-> dynamic_addr not in restricted_set`

---

## 7. CCC Handling

### 7.1 Framing & classification
**CCC-FRAME-01** (MUST, FV: YES) — A CCC frame opens with S/Sr + 7'h7E/W + ACK, then the 8-bit Command Code. Broadcast = code 0x00–0x7F (bit7=0, applies to all); Direct = code 0x80–0xFE (bit7=1, per-Target). 0xFF reserved → unsupported. *p.85–86 (phys 121–122).* `src: R-BCAST-DIRECT-BIT7-01, R-CCC-FF-RSVD-01, R-CCC-RECOG-01`
> `assert: ccc_is_direct == command_code[7];  (command_code==8'hFF) |-> ccc_unsupported`

**CCC-NINTH-01** (MUST, FV: YES) — The 9th bit after an ADDRESS byte is ACK/NACK; the 9th bit after a DATA/CCC-code byte is a T-bit. The FSM MUST select role by phase. *Annex Figs 170–172.* `src: R-FMT-02`

**CCC-DIRECT-SEQ-01** (MUST, FV: YES) — Direct CCC sequence: 7'h7E/W ACK → CCC code + T → Sr → Target Address + RnW → ACK (only if addressed and supported). The same CCC may repeat (Sr + next Target Addr) for other Targets. *p.97/108 (phys 133/144), Annex Fig 170.* `src: R-CCC-02, R-FMT-03`
> `assert: (direct_ccc_active && sr_seen && addr==my_da && supported(ccc) && rnw_legal) |-> ack_drive`

**CCC-BCAST-INSPECT-01** (MUST, FV: no/coverage) — Every Broadcast CCC MUST be inspected/decoded even if ignored (capture-register coverage; no bus-observable signature). *p.82 (phys 118).* `src: R-BCAST-INSPECT-01, R-ENEC-03`

**CCC-FORM-01** (MUST, FV: YES) — Apply Broadcast-form effects to self (payload follows code, no address); apply Direct-form effects only when own DA matches (payload after Sr+Addr). Only the single addressed Target replies to a Direct segment; a non-addressed Target MUST NOT drive. *p.82/90–95 (phys 118/126–131).* `src: R-CCC-03, R-DIR-SINGLE-RESP-01`
> `assert: (direct_ccc_segment_active && !own_addr_match) |-> !sda_drive`

**CCC-END-01** (MUST, FV: YES) — Detect CCC termination: STOP ends any CCC (→ idle, release SDA); for Broadcast, an Sr (any address) ends it; for Direct, Sr+7'h7E ends the current CCC (Sr with non-7E = new directed segment). *p.86 (phys 122).* `src: R-CCC-END-01`

**CCC-PREMATURE-01** (MUST, FV: YES) — On premature/invalid CCC termination, the Target MUST NOT hang or drive contention: return to safe idle and release SDA. (Disregard-vs-process of partial data is an implementation policy.) *p.86.* `src: R-CCC-PREMATURE-01`
> `assert: (unexpected_stop_mid_ccc || unexpected_rstart_mid_ccc) |=> target_idle && !sda_drive`

**CCC-EXTRA-01** (MUST, FV: YES) — Ignore additional unrecognized data bytes beyond a CCC's defined length without corrupting state or erroring. *p.86–87 (phys 122–123).* `src: R-CCC-IGNORE-EXTRA-01`

### 7.2 Direct GET / read & T-bit
**CCC-GET-TBIT-01** (MUST, FV: YES) — Direct Read/GET CCC data uses the SDR-read T-bit (per RD section) per byte, MSB-first, after the Target ACKs the read address. If NACKed, no data returned. *p.85–86 (phys 121–122).* `src: R-TBIT-READ-01, R-DIR-READ-RESP-01, R-CCC-05`

**CCC-GET-READY-01** (MUST, FV: YES) — During a Direct GET, the Target MUST pre-stage its response (immediate ACK+data if addressed) and MUST NOT drive when not addressed. If it cannot respond in time, it MUST NACK its address. *p.88 (phys 124).* `src: R-GET-READY-01, R-GET-NACK-01`
> `assert: (direct_get_active && own_addr_match && !response_ready && in_ack_slot) |-> nack_drive`

**CCC-GET-RETRY-01** (SHOULD/MAY, FV: YES) — Single-retry model: after a GET NACK, the Controller retries once (Sr + Addr); the Target SHOULD ACK and return data on the retry; it MAY NACK the second attempt (no further retries expected). *p.88.* `src: R-GET-RETRY-ACK-01, R-GET-RETRY-LIMIT-01`

### 7.3 Unsupported CCC / Defining Byte handling (umbrella)
**CCC-NACK-01** (MUST, FV: YES) — **Umbrella rule:** for any Direct CCC (or Direct CCC + Defining Byte) addressed to the DA that the Target does not support, the Target MUST NACK its Target Address (then await STOP/Sr; no data driven for that segment). This is the catch-all for all out-of-scope CCCs (SETBRGTGT, SETROUTE, GETACCCR, CRHDLY, unsupported GETMXDS/RSTACT/GETCAPS/GETSTATUS Defining Bytes, SETGRPA, etc.). *p.87/126–127 (phys 123/162–163).* `src: R-UNSUP-NACK-01, R-CCC-NACK-01, R-CCC-04`
> `assert: (is_direct_ccc && addr_match_dyn && !ccc_supported(ccc_code, defining_byte)) |-> !ack_drive`

**CCC-UNSUP-CLASS-01** (MUST, FV: YES) — A Direct CCC is "unsupported" if: (a) code unsupported; (b) Defining Byte unsupported for a supported code; (c) DA matched with Write where CCC is Read/GET-only; (d) DA matched with Read where CCC is Write/SET-only. (Cases c/d also map to TE5 illegal-format; correctly-formatted-but-unsupported is handled here, NOT as TE5.) *p.87 (phys 123), p.152–153 (phys 189).* `src: R-UNSUP-CLASS-01, R-TE5-03, R-ERR-CCC-UNSUP`

**CCC-BCAST-IGNORE-01** (MUST, FV: YES) — Broadcast CCCs are not per-Target NACKed (only the single 7'h7E ACK). For an unsupported/out-of-scope Broadcast operation the Target MUST ignore it = no internal state change, consume bytes cleanly, no protocol error. *p.136/145–146 (phys 172/181–182).* `src: R-RSTACT-04, R-SETBUSCON-01, R-DEFTGTS-01, R-DEFGRPA-01`

### 7.4 Defining Byte semantics
**CCC-DEFB-STICKY-01** (MUST, FV: YES) — A Defining Byte is sticky across all Direct segments until a new Direct CCC (new 7'h7E+code) is sent. *p.85 (phys 121).* `src: R-DEFB-STICKY-01`

**CCC-DEFB-TRACK-01** (MUST, FV: YES) — Track {Command Code, Defining Byte present/value}; select the response (8-bit vs 16-bit interpretation) when the directed address matches after Sr. *p.87.* `src: R-DEFB-TRACK-01`

**CCC-DEFB-ZERO-01** (SHOULD, FV: YES) — For optional-Defining-Byte GET CCCs, treat DB value 0x00 the same as "no Defining Byte" (NOT for Required-DB CCCs). *p.87.* `src: R-DEFB-ZERO-01`

**CCC-DEFB-NACK-01** (MUST, FV: YES) — If a Direct CCC is supported without a DB but the specific DB value is unsupported, NACK after the Target Address. *p.87.* `src: R-DEFB-NACK-01`

**CCC-SUBCMD-01** (INFO) — Sub-Command Byte (Direct Write/SET) follows the directed address + T-bit and applies only to that segment (distinct from the sticky Defining Byte). Implement only if a supported v1 Direct SET CCC uses sub-commands. *p.85.* `src: R-SUBCMD-01`

### 7.5 Master CCC list — Target behavior (v1)

Legend: B=Broadcast code, D=Direct code. "Support" = v1 obligation.

| CCC | Codes | Level | v1 Target behavior | Page | FV |
|---|---|---|---|---|---|
| **ENEC / DISEC** | 0x00/0x80, 0x01/0x81 | MUST | Decode Events Byte; ENINT(bit0) sets/clears `ibi_en`; ENCR(bit1)/ENHJ(bit3)/reserved bits tolerated & ignored (no error). Broadcast→self; Direct→if addressed. | p.97–98 (phys 133–134) | YES |
| **ENTASx** | 0x02–0x05 / 0x82–0x85 | MAY | Optional; decode-and-ignore (consume bytes). Must keep comms in all activity states (BUS-ACT-02). NACK Direct form if unsupported. | p.99 (phys 135) | no |
| **RSTDAA** | 0x06 (B) | MUST | Clear DA (`has_da→0`); ready for re-assignment. Direct 0x86 → NACK (deprecated). | p.101 (phys 137) | YES |
| **ENTDAA** | 0x07 (B) | MUST | Participate if `!has_da`, else don't respond. | p.101 | YES |
| **DEFTGTS** | 0x08 (B) | INFO | Secondary-controller only → ignore, tolerate. | p.104–105 (phys 140–141) | no |
| **SETMWL / GETMWL** | 0x09/0x89, 0x8B | MUST* | Store/return 16-bit MWL (MSB first). Out-of-range SETMWL → leave unchanged (SHOULD). *Required iff variable write-length limit. | p.102 (phys 138) | YES |
| **SETMRL / GETMRL** | 0x0A/0x8A, 0x8C | MUST* | Store/return 16-bit MRL (MSB first); GETMRL returns 3rd byte (Max IBI Payload) iff BCR[2]=1. Out-of-range → leave unchanged. *Required iff IBI payload >1 byte. | p.103 (phys 139) | YES |
| **ENTTM** | 0x0B (B) | MAY | Optional Test Mode; v1 = ignore (out of scope). | p.106 (phys 142) | no |
| **SETBUSCON** | 0x0C (B) | SHOULD | Tolerate any context byte; react only to recognized values; v1 = no-op. | p.145–146 (phys 181–182) | YES |
| **ENDXFER** | 0x12/0x92 | MAY | HDR/monitoring only → NACK Direct / ignore Broadcast. | p.134–135 (phys 170–171) | no |
| **ENTHDR0..7** | 0x20–0x27 (B) | MUST(tol) | Recognize HDR entry; enter HDR-quiesce; await HDR Exit Pattern. No HDR datapath. | p.107 (phys 143) | YES |
| **SETAASA** | 0x29 (B) | MAY | Optional; static→dynamic only if `!has_da`. | p.133 (phys 169) | YES |
| **RSTACT** | 0x2A/0x9A | MUST | Configure/query Target Reset action; DB 0x00/0x01 supported & ACKed; unsupported DB → NACK (Direct) / ignore (Broadcast). | p.136 (phys 172) | YES |
| **DEFGRPA** | 0x2B (B) | INFO | Secondary-controller only → ignore. | p.144 (phys 180) | no |
| **RSTGRPA** | 0x2C/0x9C | MUST† | †Only if Group Addressing supported (N/A v1). | p.142–143 (phys 178–179) | YES |
| **SETDASA** | 0x87 (D) | MAY | Optional; DA from Static if `!has_da`; NACK if has_da. | p.108 (phys 144) | YES |
| **SETNEWDA** | 0x88 (D) | MUST‡ | ‡Required if ENTDAA supported; change DA; NACK if unsupported/no DA. | p.110 (phys 146) | YES |
| **GETMXDS** | 0x94 (D) | MUST§ | §Required iff BCR[0]=1; else NACK. CRHDLY DB 0x91 → NACK (not controller-capable). | p.122/128 (phys 158/164) | YES |
| **GETPID** | 0x8D (D) | MUST‡ | Return 48-bit PID as 6 bytes MSB-first; ‡required if ENTDAA. | p.111 (phys 147) | YES |
| **GETBCR** | 0x8E (D) | MUST‡ | Return BCR (1 byte); must equal DAA-advertised BCR. | p.111 | YES |
| **GETDCR** | 0x8F (D) | MUST‡ | Return DCR (1 byte); must equal DAA DCR. | p.112 (phys 148) | YES |
| **GETSTATUS** | 0x90 (D) | MUST | Always supported; return 2-byte Format-1 status (see §7.6). Format 2 optional; PRECR DB 0x91 → NACK (not controller-capable). | p.113–117 (phys 149–153) | YES |
| **GETACCCR** | 0x91 (D) | MUST | Not controller-capable → NACK its address. | p.119 (phys 155) | YES |
| **GETCAPS** | 0x95 (D) | MUST | v1.1+ → return ≥2 capability bytes (see §7.7). Format 2 DBs unsupported → NACK. | p.130 (phys 166) | YES |
| **SETGRPA / GETGRPA** | 0x9B/… | MUST† | †Only if Group Addressing (N/A v1) → NACK via CCC-NACK-01. | p.141 (phys 177) | YES |
| **SETBRGTGT** | 0x93 (D) | SHOULD | Non-bridge → NACK. | p.121 (phys 157) | YES |
| **SETROUTE** | 0x96 (D) | SHOULD | Non-routing → NACK. | p.131 (phys 167) | YES |
| **SETXTIME / GETXTIME** | — | MUST(NACK) | Timing Control not supported (GETCAP3[7]=0) → NACK. | p.205 (phys 241) | YES |
| **Reserved / N-marked / 0xFF** | — | MUST | Not supported; Direct → NACK own address; Broadcast → ignore. | p.89 (phys 125) | YES |

Per-CCC formal property representatives:
- GETSTATUS REQUIRED ACK: `assert: (ccc==0x90 && addr_match && rnw==READ) |-> ack_drive`
- Identity GETs return constants: `assert: (getbcr_read && ack_drive) |-> data_out==bcr_reg` (same for DCR/PID/MWL/MRL)
- Always-NACK out-of-scope: `assert: (is_direct_ccc && ccc inside {0x91,0x93,0x96,0x86} && addr_match) |-> !ack_drive`

**CCC-GETSTATUS-AVAIL-01** (MUST, FV: YES) — GETSTATUS response logic MUST be in an always-available datapath: the Target MUST remain ready to respond to GETSTATUS to its DA even while busy/NACKing other CCCs. *p.43 (phys 79).* `src: R-CCC-02(4.3.2)`

### 7.6 GETSTATUS (Format 1) — mandatory
**CCC-STAT-01** (MUST, FV: YES) — Return 2 bytes (MSB then LSB): MSB=Vendor Reserved; LSB[7:6]=Activity Mode (private contract / tie 0), LSB[5]=Protocol Error, LSB[4]=Reserved(0), LSB[3:0]=Pending Interrupt. *p.113–114 (phys 149–150).* `src: R-STAT-01`

**CCC-STAT-02** (MUST, FV: YES) — Protocol Error bit (LSB[5]) is sticky-set on a detected protocol error and self-clears on each successful GETSTATUS read completion (read-to-clear). *p.114.* `src: R-STAT-02`
> `assert: protocol_error_event |=> proto_err_bit;  getstatus_read_complete |=> !proto_err_bit`

**CCC-STAT-03** (MUST, FV: YES) — Pending Interrupt field (LSB[3:0]) reflects enqueued interrupts (0=none, ≤15, highest priority if multiple) and is independent of `ibi_en` (readable even when IBI disabled by DISEC). *p.114.* `src: R-STAT-03`

**CCC-STAT-04** (MUST, FV: YES) — GETSTATUS Format 2 optional: unsupported DB → NACK address; PRECR (0x91) → NACK (not controller-capable). If Format 2 supported, advertise via GETCAP3 (see OQ-bit-index). *p.115–117 (phys 151–153).* `src: R-STAT-04/05/06`

### 7.7 GETCAPS — mandatory (≥2 bytes for v1.2)
**CCC-CAPS-01** (MUST, FV: YES) — Return at least GETCAP1, GETCAP2 (may return 2/3/4 bytes; Controller may end early on a byte boundary). *p.130/203 (phys 166/239).* `src: R-GETCAPS-01, R-GCAP-LEN2`
> `assert: getcaps_resp_done |-> resp_byte_count >= 2`

**CCC-CAPS-02** (MUST, FV: YES) — Capability-byte constants for the v1 no-HDR profile:
- GETCAP1 = 0x00 (no HDR-DDR/BT; HDR-TSP/TSL never set). `src: R-GCAP1-HDR0`
- GETCAP2[3:0] = `4'b0010` (v1.2, never 0000); GETCAP2[7:4]=0 (no HDR-DDR abort, no Group Address). `src: R-GCAP2-VER, R-GCAP2-ZEROS`
- GETCAP3: [7]=Timing Control = 0 (→ NACK SET/GETXTIME); [6]=IBI-MDB Pending-Read = `PENDREAD_SUPPORTED` (consistent with MDB group 3'b101); [5]=0; [4]=GETSTATUS-Format2 support; [3]=GETCAPS-Format2 support (see OQ bit-index); [2:0]=0 (no D2DXFER/Multi-Lane). `src: R-GCAP3-TC/IBIMDB/ZEROS/DBGETCAPS`
- GETCAP4 = 0x00 (no HDR CCCs). `src: R-GCAP4-HDR0`
*p.204–206 (phys 240–242).*
> `assert: getcaps_resp && byte_idx==2 |-> resp_byte[3:0]==4'b0010 && resp_byte[7:4]==0`
> `assert: getcaps_resp && byte_idx==3 |-> resp_byte[7]==0 && resp_byte[2:0]==0`
> `assert: ibi_mdb_valid && mdb[7:5]==3'b101 |-> getcap3[6]==1`

**CCC-CAPS-03** (MUST if Format 2, FV: YES) — GETCAPS Format 2 DB map (Table 65): 0x00 TGTCAPS (=Format 1), 0x5A TESTPAT (returns 0xA55AA55A or NACK), 0x91 CRCAPS / 0x93 VTCAPS / 0xD7 DBGCAPS → always NACK in v1; reserved DBs → NACK. *p.207–212 (phys 243–248).* `src: R-GCAP2FMT-DBMAP, R-GCAP2-TGTCAPS, R-GCAP2-TESTPAT, R-GCAP2-NACK`

### 7.8 RSTACT (CCC side; reset behavior in §10)
**CCC-RSTACT-01** (MUST, FV: YES) — RSTACT (B 0x2A / D 0x9A): support & ACK DB 0x00 (No Reset) and 0x01 (Peripheral Reset, default); load `reset_action_reg`. Unsupported DB (0x02–0x7F SET, 0x82–0xFF GET) → NACK (Direct) / ignore (Broadcast). Direct-Read time format (DB 0x81/0x82) optional → may NACK. *p.136/139–140 (phys 172/175–176), p.200 (phys 236).* `src: R-RSTACT-01/02/04/05, R-DEFB-RSTACT, R-RSTACT-DECODE`

---

## 8. In-Band Interrupt (IBI)

### 8.1 Initiation & arbitration
**IBI-INIT-01** (MUST, FV: YES) — An IBI is requested only (a) at a plain START after Bus Free, or (b) during a Bus Available Condition by pulling SDA Low to create the START. NEVER after a Repeated START. *p.46 (phys 82), p.75 (phys 110).* `src: R-IBI-02, R-IBI-01(4.3.6)`
> `assert: ibi_start |-> (bus_free_start || bus_available);  repeated_start |-> !ibi_start`

**IBI-ADDR-01** (MUST, FV: YES) — IBI header = own DA[6:0] with RnW=1, driven MSB-first, open-drain. Requires `da_valid`. Never uses a Group Address. *p.46/75 (phys 82/110), p.148 (phys 184).* `src: R-IBI-01(4.3.2), R-IBI-02/03(4.3.6), R-IBI-01(grp), R-GRP-02(4.3.4)`
> `assert: ibi_drive_addr |-> tx_addr==dyn_addr && tx_rnw==1;  ibi_request_start |-> da_valid;  ibi_arbitration_active |-> ibi_addr==dyn_addr`

**IBI-AVAIL-01** (MUST, FV: YES) — Don't pull SDA Low to request a START before tAVAL has elapsed; in Bus-Available START handoff, control SDA open-drain after the Controller pulls SCL Low. *p.46/75 (phys 82/110).* `src: R-IBI-04, R-IBI-03(4.3.2)`
> `assert: target_pulls_sda_to_request_start |-> bus_available_timer >= tAVAL_cycles`

**IBI-ARB-01** (MUST, FV: YES) — Open-drain arbitration: drive Low for 0; release for 1 and monitor; if released 1 but sample 0 → lost: immediately stop driving for the rest of the header (lower address wins = higher priority). Retry only after the next Bus Available Condition. *p.47/75–76 (phys 83/110–111).* `src: R-ARB-01/02(4.3.2), R-ARB-01(4.3.6), R-IBI-05(4.3.6), R-IBI-01(annexF)`
> `assert: (ibi_header_active && driven_bit==1 && sda_sampled==0) |=> arb_lost && !sda_oe`

**IBI-NORS-01** (MUST, FV: YES) — No Target shall transmit its own DA nor 7'h02 (Hot-Join) after a Repeated START; post-Sr address header is Controller-driven push-pull. The Target only drives the ACK bit. *p.50 (phys 86).* `src: R-IBI-06(4.3.2)`
> `assert: (post_repeated_start && state==ADDR_PHASE) |-> !sda_oe`

**IBI-DEFER-01** (MUST, FV: YES) — Arbitration collisions with the Controller: (a) addr matches but Controller RnW=0 (Private Write) → Controller wins, ACK/NACK the write, defer IBI; (b) addr+RnW=1 both match (Private Read) → double-NACK → defer IBI and retry later. Handle inconclusive ties as a re-arm, not success. *p.49/81 (phys 85/116).* `src: R-IBI-04/05(4.3.2), R-TOL-03`

**IBI-OPEN7E-01** (MUST, FV: YES) — Tolerate / use a Controller-opened arbitrable header (START + 7'h7E): the Target may drive its address into that header to win (7'h7E is high-valued, so any DA out-arbitrates it), provided IBI pending and `int_enabled`. *p.81 (phys 116).* `src: R-TOL-01`

**IBI-PRIO-01** (INFO) — Priority is inherent in the address (lower DA = higher priority); no priority register in the Target. *p.75 (phys 110).* `src: R-PRIO-01`

### 8.2 ACK/NACK response, payload (MDB)
**IBI-NACK-01** (MUST, FV: YES) — If the Controller passively NACKs the IBI address, the Target MUST recognize it, stop driving, release the bus, and await Sr/STOP; may retry later. *p.53/76 (phys 89/111).* `src: R-IBI-08(4.3.2), R-IBI-06(4.3.6), R-IBI-03(annexF)`
> `assert: ibi_nacked |-> (!sda_oe until (repeated_start || stop))`

**IBI-MDB-01** (MUST, FV: YES) — If BCR[2]=1, after the Controller ACKs the IBI the Target MUST transmit the Mandatory Data Byte (Controller cannot decline it), switching open-drain→push-pull at the specified SCL edges (drive SDA Low after the ACK's SCL rising, begin MDB push-pull on the following SCL falling). If BCR[2]=0, send no payload (frame ends after ACK). *p.53/75–77 (phys 89/110–112), p.215 (phys 251).* `src: R-IBI-07(4.3.2), R-MDB-01/02, R-MDB-MANDATORY`
> `assert: (ibi_acked && bcr[2] && scl_rising) |-> sda_oe && sda_out==0;  (ibi_acked && bcr[2] && scl_falling) |=> push_pull_mode && mbyte_driving`
> `assert: (ibi_acked && !bcr[2]) |-> !target_drives_mdb`

**IBI-MDB-TBIT-01** (MUST, FV: YES) — IBI payload bytes use the read End-of-Data T-bit: T=1 if more bytes follow, T=0 on the final byte (and on the MDB if no further bytes). Additional bytes after the MDB are optional. *p.75–77 (phys 110–112).* `src: R-MDB-03/05, R-IBI-02(annexF)`
> `assert: ibi_last_payload_byte |-> t_bit==0;  ibi_more_bytes |-> t_bit==1`

**IBI-MDB-LIM-01** (MUST, FV: YES) — Total IBI payload MUST NOT exceed the Max IBI Payload Size (SETMRL 3rd byte; 0=unlimited). Min payload = 1 byte (no Timing Control). *p.75/103 (phys 110/139).* `src: R-MDB-04, R-MRL-04`
> `assert: (ibi_payload_active && ibi_payload_max!=0) |-> ibi_payload_byte_count <= ibi_payload_max`

**IBI-MDB-FMT-01** (MUST, FV: YES) — MDB layout: [7:5]=Interrupt Group Identifier, [4:0]=Specific Interrupt Identifier. Emitted group MUST be a defined value (3'b000/001/010/011/100/101); 3'b110/111 reserved → never emitted. *p.77/215–216 (phys 112/251–252).* `src: R-MDB-07, R-MDB-FORMAT, R-MDB-GROUPS, R-MDB-VALUES-I3CWG`
> `assert: ibi_mdb_valid |-> mdb[7:5]!=3'b110 && mdb[7:5]!=3'b111`

**IBI-NOREPEAT-01** (MUST, FV: YES) — If the Controller ACKs the IBI but truncates the transfer before all extra bytes are read, the Target MUST NOT re-issue that already-acknowledged IBI. (Per-IBI "serviced" flag distinct from "fully drained".) *p.75–76 (phys 110–111).* `src: R-MDB-06`

### 8.3 Enable control (ENEC / DISEC)
**IBI-EN-01** (MUST, FV: YES) — `int_enabled` (a.k.a. `ibi_en`) is cleared by DISEC with the DISINT bit (bit0), set by ENEC/ENINT (broadcast or directed to DA). While disabled, the Target MUST NOT initiate any IBI (no SDA-Low for IBI, no arbitration). *p.76/97–98 (phys 111/133–134).* `src: R-ENEC-01, R-EVT-01/03, R-IBI-04/05(annexF)`
> `assert: (disec_applied_to_me && events_byte[0]) |=> !ibi_en;  (enec_applied_to_me && events_byte[0]) |=> ibi_en;  sda_drive_low_for_ibi |-> ibi_en`

**IBI-EN-02** (MUST, FV: YES) — IBI capability is ENABLED by default after reset (`ibi_en` resets to 1) for an IBI-capable Target. *p.98 (phys 133).* `src: R-ENEC-02, R-EVT-02`
> `assert: $past(reset) |-> ibi_en==1`

### 8.4 Pending Read Notification (PRN) — optional contract
**IBI-PRN-01** (SHOULD, conditional-MUST if implemented, FV: YES) — If PRN is implemented: advertise via GETCAP3[6]=1; signal PRN with MDB[7:5]=3'b101; after the Controller reads the PRN MDB, make data available on the next Private Read; only one active PRN at a time (don't issue another PRN-IBI while pending); consume PRN data exactly once (NACK extra reminder-driven reads); on data error NACK the read; do not mark PRN accepted unless the MDB was actually read; PRN disabled by default. *p.79–80 (phys 114–115).* `src: R-PRN-01..10`

**IBI-PRN-02** (MAY, FV: no) — Non-PRN IBIs (e.g., error reports) are allowed while a PRN is pending; reminder re-transmits of the PRN-IBI permitted. *p.80.* `src: R-PRN-05`

### 8.5 Tolerance
**IBI-TOL-01** (MUST, FV: no) — Tolerate Controller pre-emption: NACK, driving a higher-priority address instead, and holding SCL Low until that transaction begins. No watchdog may abort on SCL-low stretch; back off on NACK/loss. *p.76 (phys 111).* `src: R-TOL-02`

---

## 9. SDR Error Detection & Recovery

**ERR-00** (MUST, FV: structural) — Support all SDR Target Error Types (Table 43): TE0–TE5 mandatory; TE6 (Monitoring) and DBR (Dead Bus Recovery) optional. Central error-handling FSM with one recovery-exit arc per type and an "ignore-bus" state that suppresses ACK/drive until the resync event. (Formerly S0–S6.) *p.150 (phys 186).* `src: R-ERR-00`

**ERR-TE0-01** (MUST, FV: YES) — **TE0 (restricted address):** after DA assigned and outside ENTDAA, on the header after any START/Sr, treat any of 7'h7F/W, 7C/W, 7A/W, 76/W, 6E/W, 5E/W, 3E/W, or 7'h7E/R as TE0. Recovery: ignore the bus (no ACK/drive) until the HDR Exit Pattern is detected. *p.150–151 (phys 186–187).* `src: R-TE0-01/02, R-ERR-TE0`
> `assert: (da_assigned && !in_entdaa && header_after_start && addr_rnw in restricted_set) |-> te0_err`
> `assert: te0_err |-> (!ack_oe && !sda_drive_low) until hdr_exit_detected`

**ERR-TE0-02** (MUST, FV: YES) — During ENTDAA the TE0 detector is disabled (7'h7E/R excluded) and TE4 is used instead. *p.151.* `src: R-TE0-03`
> `assert: in_entdaa |-> (!te0_err && te4_detector_active)`

**ERR-TE1-01** (MUST, FV: YES) — **TE1 (CCC-code parity error):** since it could be a corrupted ENTHDR, ignore the bus until the HDR Exit Pattern. *p.150/152 (phys 186/188).* `src: R-TE1-01, R-ERR-TE1`
> `assert: ccc_code_parity_err |-> (!ack_oe && !sda_drive_low) until hdr_exit_detected`

**ERR-TE2-01** (MUST, FV: YES) — **TE2 (write-data parity error):** stop accepting data (commit nothing corrupted) and wait for STOP or Sr. *p.150/152.* `src: R-TE2-01, R-ERR-TE2`
> `assert: wr_data_parity_err |-> !wr_data_commit until (stop_detected || sr_detected)`

**ERR-TE2-02** (MUST, FV: YES) — TE2 after a CCC: **v1 must fix one of** (1) retain CCC state until Sr, or (2) disregard until STOP. No corrupted data committed either way. (See OQ-recovery-choice.) *p.152.* `src: R-TE2-02`

**ERR-TE3-01** (MUST, FV: YES) — **TE3 (DAA assigned-address PAR error):** generate NACK after PAR, do not latch DA, wait for Sr+7'h7E/R, then re-transmit PID/BCR/DCR. *p.150/152 (phys 186/188), Annex Fig 180.* `src: R-TE3-01, R-DAA-03(annexF)`
> `assert: (in_entdaa && assigned_addr_par_err) |-> nack_after_par && !da_latched ##[1:$] (sr && bcast_7E_R) |-> pid_replay`

**ERR-TE4-01** (MUST, FV: YES) — **TE4 (non-7'h7E/R after Sr during ENTDAA):** NACK after the 7'h7E/R slot, then wait for STOP to exit ENTDAA. (Table 43 also lists "STOP or Sr detector"; **OQ-TE4** resolve whether Sr is also a recovery.) *p.150/152, Annex Fig 180.* `src: R-TE4-01, R-DAA-04(annexF)`

**ERR-TE5-01** (MUST, FV: YES) — **TE5 (illegally formatted CCC):** NACK after the matching DA, then wait for STOP/Sr. Examples: matching DA + Write on a Read/GET-only Direct CCC; matching DA + Read on a Write/SET-only Direct CCC. *p.150/152.* `src: R-TE5-01, R-ERR-TE5`
> `assert: (ccc_active && addr_match && rnw != ccc_legal_dir(ccc_code)) |-> nack_after_addr ##[1:$] (stop || sr)`

**ERR-TE5-02** (MUST, FV: YES) — TE5 after a CCC: same retain-vs-discard choice as TE2 (fix one in v1). *p.152.* `src: R-TE5-02`

**ERR-TE5-03** (MUST, FV: no) — A correctly-formatted but UNSUPPORTED Direct CCC is NOT TE5; handle per CCC-NACK-01 (4.3.7.2.2). Two distinct decode paths. *p.152–153 (phys 188–189).* `src: R-TE5-03, R-ERR-CCC-UNSUP`

**ERR-TE6-01** (SHOULD/optional, FV: YES) — **TE6 (read-back monitoring, optional):** if implemented, compare driven SDA vs intended TX bit during Target reads; a mismatch = TE6. Disabled during ENTDAA arbitration. On TE6 in a private-read/Direct-GET context: stop driving, let the Controller finish, wait for STOP/Sr (Direct-GET uses the retain-vs-discard choice). Requires reliable open-drain line read-back (OQ-TE6). *p.153 (phys 189).* `src: R-TE6-01..05, R-ERR-TE6`

**ERR-REC-RESYNC-01** (MUST, FV: YES) — **Liveness/safety:** for every error the Target MUST resynchronize at the defined recovery event and never permanently hang; while in any error/ignore state it MUST NOT falsely ACK or corrupt application state; a STOP or HDR Exit Pattern always returns it to idle/ready. *p.150–154 (phys 186–190).* `src: R-REC-RESYNC`
> `assert: in_any_sdr_error |-> s_eventually(idle_ready);  (stop_detected || hdr_exit_detected) |=> resync_to_idle`

**ERR-REC-CE2-01** (MUST, FV: YES) — Tolerate Controller CE2 recovery (optional 7'h7E/W, HDR Exit Pattern, then STOP): recover from TE0/TE1/TE2/TE5/TE6 to idle regardless of current error state. *p.156 (phys 192).* `src: R-REC-CE2`
> `assert: (hdr_exit_detected ##[1:$] stop_detected) |=> idle_ready`

**ERR-REC-60US-01** (MAY, FV: no) — Optional TE0/TE1 recovery: both lines High > 60 µs → treat bus as non-HDR, enable STOP/START detector, resume. Real-time timer. *p.151–152/154 (phys 187–188/190).* `src: R-REC-60US, R-ERR-RECOVERY-60US`

**ERR-DBR-01** (INFO) — DBR applies only to controller-capable devices; v1 Target never becomes Active Controller → not implemented (BCR controller-capable = 0). *p.150/153–154.* `src: R-DBR-01`

---

## 10. Target Reset

**RST-00** (MUST, FV: structural) — Support the in-band Target Reset mechanism: react to the Target Reset Pattern by performing a reset action selected by RSTACT config or default escalation. Reset-action register + escalation FSM + Target Reset Pattern detector live in the always-available domain. *p.160 (phys 196).* `src: R-TRST-00, R-RSTACT-SUPPORT`

### 10.1 RSTACT configuration
**RST-CFG-01** (MUST, FV: YES) — Decode RSTACT Defining Byte (Table 45/59): 0x00=No Reset on TRP; 0x01=Reset I3C Peripheral Only (default); 0x02=Reset Whole Target (optional/recommended); 0x03 Debug / 0x04 Virtual Target Detect (out of scope); 0x81/0x82=GET reset-time; load `reset_action_reg`. SET 0x00/0x01 supported & ACKed; unsupported → NACK (Direct) / ignore (Broadcast). *p.136/164 (phys 172/200), p.200 (phys 236).* `src: R-RSTACT-01/02/04, R-RSTACT-DECODE, R-DEFB-RSTACT, R-RSTACT-SUPPORT`

**RST-CFG-02** (MUST, FV: YES) — Clear the configured reset action (re-arm to default/No-Reset) on the next true START's first SCL-falling edge, but NOT on a Repeated START. (Hence Controller keeps RSTACT and TRP within one Frame.) Requires accurate START vs Sr discrimination. *p.139/161 (phys 175/197).* `src: R-RSTACT-03, R-TRST-CLRCFG`
> `assert: (after_start && !after_repeated_start) |=> reset_action_reg==DEFAULT;  after_repeated_start |=> $stable(reset_action_reg)`

**RST-CFG-03** (SHOULD/optional, FV: no) — RSTACT Direct-Read (Format 3) return-time uses Table 39 encoding (bit7=unit 10ms/1s, [6:0]=count); a minimal Target may NOT support and NACK 0x81–0x83. *p.140 (phys 176).* `src: R-RSTACT-05`

### 10.2 Target Reset Pattern (TRP) detection
**RST-TRP-01** (MUST, FV: YES) — Recognize the TRP: 14 SDA transitions while SCL is held Low (SDA ends High), followed by a Repeated START then a STOP while SCL High. Use min-timing rules (tDIG_H). *p.162–163 (phys 198–199).* `src: R-TRP-RECOG`
> `assert: (scl==0 && sda_transition_count==14 && sda==1) |-> trp_body_valid`

**RST-TRP-02** (MUST, FV: YES) — Trigger the reset action only on the STOP that follows the validating Sr (not before). *p.163.* `src: R-TRP-TRIGGER`
> `assert: (trp_body_valid ##[1:$] sr_detected ##[1:$] stop_detected) |-> trp_trigger`

**RST-TRP-03** (MUST, FV: YES) — Distinguish the TRP (14 transitions) from the HDR Exit Pattern (4) and HDR Restart Pattern: an HDR Exit/Restart or any too-short count MUST NOT trigger reset. *p.162.* `src: R-TRP-DISTINGUISH`
> `assert: (hdr_exit_pattern_detected && !target_reset_pattern_detected) |-> !trp_trigger`

**RST-TRP-04** (MUST, FV: YES) — If the Controller pulls SCL Low first (to start a TRP), the Target MUST NOT pull SDA Low; release SDA and wait. (No fresh IBI/CRR SDA pull-down once SCL has fallen from idle without a prior START.) *p.162.* `src: R-TRP-NOSDA`
> `assert: (scl_fell_from_idle && !prior_start) |-> !sda_drive_low until trp_done`

**RST-TRP-05** (INFO) — If the Target pulled SDA Low first (IBI/HJ/CRR before SCL falls), the Controller cancels the TRP and services the request; the Target must continue normally and accept a subsequent DISEC. *p.162–163.* `src: R-TRP-IBIFIRST`

### 10.3 Escalation
**RST-ESC-01** (MUST, FV: YES) — On TRP, if RSTACT-configured (incl. 0x00 No-Action) and the RSTACT was processable, perform exactly the configured action. *p.161 (phys 197).* `src: R-TRST-CFG`

**RST-ESC-02** (MUST, FV: YES) — Default escalation level 1: if no/unprocessable RSTACT and this is the first TRP, reset the I3C Peripheral (default) and (if a processor exists) notify the application. *p.161.* `src: R-TRST-DEFAULT1`

**RST-ESC-03** (MUST, FV: YES) — Default escalation level 2: a new TRP after a Peripheral reset with no intervening RSTACT or GETSTATUS → reset the whole chip (SRSTn). The "armed" flag MUST survive a Peripheral reset (always-on domain). *p.161.* `src: R-TRST-ESC2`
> `assert: (escalation_armed && !intervening_rstact_or_getstatus) |-> reset_whole_target`

**RST-ESC-04** (MUST, FV: YES) — An intervening RSTACT or GETSTATUS clears escalation arming. *p.161–162.* `src: R-TRST-DISARM`
> `assert: (rstact_seen || getstatus_seen) |=> !escalation_armed`

### 10.4 Reset scopes
**RST-WHOLE-01** (MUST if supported, FV: YES) — Whole Target reset (RSTACT 0x02 or escalation) clears the entire I3C Target configuration to defaults: DA cleared (Required), all config reset (Required); other chip logic optional. Support of whole-reset is itself optional, but if supported it MUST reset all I3C Target logic. After whole reset, `!da_valid` and ready for ENTDAA. *p.164–165 (phys 200–201).* `src: R-TRST-WHOLE, R-TRST-WHOLE-OPT, R-TRST-WHOLE-DA`
> `assert: whole_target_reset |=> (!da_valid && all_config_regs==DEFAULT && ready_for_entdaa)`

**RST-PERIPH-01** (MUST, FV: YES) — Peripheral-only reset (0x01) MUST NOT reset other chip logic (no chip/application reset line). *p.164.* `src: R-TRST-PERIPH-NOCHIP`
> `assert: peripheral_reset |-> !chip_logic_reset`

**RST-PERIPH-02** (MUST, FV: YES) — In a Peripheral reset, the DA may be retained or cleared (implementation choice — fix in v1, OQ-reset-persistence): if cleared, participate in a following ENTDAA; if retained, do not. *p.161.* `src: R-TRST-PERIPH-DA`
> `assert: !da_valid |-> participates_in_entdaa;  da_valid |-> !participates_in_entdaa`

**RST-CFGLIST-01** (SHOULD, FV: YES) — "Reset all Target configuration" covers ENEC/DISEC, ENTAS0..3, SETMRL, SETMWL, ENTTM, ENDXFER → defaults on whole reset; peripheral-reset scope is implementer-chosen. *p.164.* `src: R-TRST-CFGLIST`

**RST-NOTIFY-01** (SHOULD, FV: no) — Notify the application via internal interrupt after a Peripheral reset (Avalon-MM status/IRQ). *p.161.* `src: R-TRST-PERIPH-NOTIFY`

**RST-PRIMCTRL-01** (INFO) — Primary-Controller-after-whole-reset procedure (4.3.9.4.1) is controller-only → not implemented; the endpoint stays a Target and does ENTDAA. *p.165.* `src: R-TRST-PRIMCTRL`

**RST-WAKE-01** (INFO) — Wake-from-Target-Reset behavior is implementation-defined; v1 has no deepest-sleep wake / no active Hot-Join. *p.165–166.* `src: R-WAKE-01`

---

## 11. HDR Tolerance (no HDR datapath)

**HDR-TOL-01** (MUST, FV: YES) — Every Target MUST recognize HDR entry (any ENTHDR0..7, codes 0x20–0x27) and MUST detect the common HDR Exit Pattern, even without HDR support. On ENTHDRx, set a sticky `is_hdr` (HDR-quiesce) state. *p.167/107 (phys 203/143).* `src: R-HDR-01(multiple), R-HDR-01(4.3.7.3.9), R-TOL-HDR`
> `assert: $rose(enthdrx_ccc_decoded) |=> is_hdr`

**HDR-TOL-02** (MUST, FV: YES) — While in an unsupported HDR Mode, the Target MUST stay off the bus (no SDA drive, no ACK), MUST NOT interpret HDR framing as SDR, and MUST NOT corrupt traffic; only the exit detector runs. `is_hdr` persists until the HDR Exit Pattern (then STOP). *p.167–168 (phys 203–204).* `src: R-HDR-02/03, R-HDR-01(4.3.2)`
> `assert: is_hdr |-> !sda_oe && !ack_drive;  is_hdr && !hdr_exit_detected |=> is_hdr`

**HDR-EXIT-01** (MUST, FV: YES) — All Targets MUST detect & respond to the HDR Exit Pattern; on detection, clear `is_hdr`/error state and return to SDR. *p.168 (phys 204).* `src: R-HDREXIT-01, R-HDR-01(4.3.7.3.9)`
> `assert: hdr_exit_detected |=> !is_hdr`

**HDR-EXIT-02** (MUST, FV: YES) — HDR Exit Pattern definition the detector MUST match: SDA starts High, SCL starts Low; SDA falls (High→Low) exactly **4 times** while SCL is held Low; each transition separated by ≥ tDIG_H (min 32 ns); a normal STOP follows. *p.168 (phys 204).* `src: R-HDREXIT-02`
> `assert: exit_en && (sda_fall_cnt==4 with scl held 0) |-> hdr_exit_detected`

**HDR-EXIT-03** (MUST, FV: structural) — The Target MUST include an HDR Exit Pattern Detector block (digital logic preferred for FPGA; reference Listing 1 — re-implement as fully-synchronous oversampled FSM for clean formal/STA, OQ-detector-impl). *p.169 (phys 205).* `src: R-HDREXIT-03, R-HDREXIT-08`

**HDR-EXIT-04** (MUST, FV: YES) — Enable the detector when (A) ENTHDRx seen, OR (B) the Target is in any HDR-Exit-recoverable error state (TE0/TE1 per §9). Once enabled, act on the pattern when first seen. *p.169.* `src: R-HDREXIT-04/05`
> `assert: (is_hdr || err_recoverable) |-> exit_en;  exit_en && hdr_exit_seen |=> !is_hdr && !err_recoverable`

**HDR-EXIT-05** (MUST, FV: YES) — No spurious action: when `exit_en` is deasserted, an HDR Exit Pattern MUST NOT initiate any special action. *p.169.* `src: R-HDREXIT-06`
> `assert: !exit_en |-> !hdr_exit_action`

**HDR-EXIT-06** (MUST, FV: YES) — SCL High resets the exit counter: any SCL rising edge before the 4th SDA fall MUST reset the count so no false Exit is signaled (handle metastable SCL-between-edges cases). *p.169.* `src: R-HDREXIT-07`
> `assert: scl_sync |=> sda_fall_cnt==0;  (exit_en && sda_fall_cnt<4 && $rose(scl_sync)) |-> !hdr_exit_detected`

(Shared SDA-transition counter feeds both HDR-Exit recovery [4] and the Target Reset Pattern detector [14] — RST-TRP-03.)

---

## 12. Electrical / Timing Constraints Relevant to FPGA

(These are SDC/IO/STA obligations, not bit-level SVA, unless noted.)

**ELE-DRV-01** (MUST, FV: YES on mode-select) — SDA driver MUST dynamically switch between push-pull and open-drain per phase (Tables 51–53): ACK & address-arbitration = open-drain; read data + T-bit & STOP-handoff = push-pull. Pad = 3-state with per-phase mode select. *p.176/194 (phys 212/230).* `src: R-DRV-01, R-ARB-01(elec)`
> `assert: ack_phase |-> open_drain_mode;  read_data_phase |-> push_pull_mode`

**ELE-DRV-02** (MUST, FV: YES) — The Target NEVER drives SCL and NEVER clock-stretches (`scl_oe ≡ 0`); meets tSCO without stalling SCL. *p.173–174 (phys 209–210), Table 47.* `src: R-DRV-02/03, R-I2CF-04`
> `assert: scl_oe == 0`

**ELE-TIM-01** (MUST, FV: no) — SCL up to 12.5 MHz sustained / 12.9 MHz burst; tDIG_L/tDIG_H min 32 ns; tLOW/tHIGH min 24 ns. Oversample SCL well above 12.5 MHz. *p.178–179 (phys 214–215), Table 50.* `src: R-TIM-01`

**ELE-TIM-02** (MUST, FV: no) — Clock-to-Data-Out tSCO ≤ 20 ns; if tSCO > 20 ns, set BCR[0]=1 and the maxRD turnaround field = 3'b111 and support GETMXDS. *p.178/180 (phys 214/216).* `src: R-TIM-02, R-GETMXDS-02`

**ELE-TIM-03** (MUST, FV: no) — Target push-pull setup/hold: tSU_PP ≥ 3 ns, tHD_PP ≥ 0 ns (SDA vs recovered SCL). *p.178–179.* `src: R-TIM-03`

**ELE-TIM-04** (MUST, FV: no) — Open-drain SDR timing tolerances (Table 49): tLOW_OD ≥200 ns, tHIGH pure ≥24 ns / tDIG_H ≥32 ns, tHIGH mixed ≤41 ns, tSU_OD ≥3 ns, tfDA_OD ≤12 ns, tCAS ≥38.4 ns, tCBP ≥ tCAS/2. *p.176–177 (phys 212–213).* `src: R-TIM-04`

**ELE-BUS-01** (MUST, FV: YES on sequencing) — Bus-condition timing the Target measures: tBUF (Fm 1.3 µs / Fm+ 0.5 µs), tAVAL ≥1 µs, tIDLE ≥200 µs. IBI START gated by tAVAL counter (cf. BUS-AVAIL-01). *p.175–177 (phys 211–213), Tables 48/49.* `src: R-BUS-01(elec)`

**ELE-V-01** (INFO) — Operating VDD 1.2/1.8/3.3 V (or less); not characterized for 5 V; optional F010 1.0 V/100 pF. Match FPGA IO bank VCCIO/IO standard to bus VDD. *p.171–172 (phys 207–208), Table 46.* `src: R-ELEC-01`

**ELE-V-02** (SHOULD, FV: no) — Inputs: VIL −0.1·VDD..0.3·VDD, VIH 0.7·VDD..1.1·VDD; Schmitt-trigger with Vhys ≥0.1·VDD recommended. *p.172–173.* `src: R-ELEC-02`

**ELE-V-03** (MUST, FV: no) — Output-low drive: VOL ≤0.18 V @ 2 mA (VDD<1.4 V) or ≤0.27 V @ 3 mA (VDD≥1.4 V); continuous-sink capable (pad ~2× peak). Set FPGA IO drive strength accordingly on SDA. *p.172–173.* `src: R-ELEC-03`

**ELE-CAP-01** (MUST, FV: no) — Pin capacitance Ci ≤5 pF (<1.8 V) / ≤10 pF (≥1.8 V); SDA-vs-SCL ΔC ≤1.5 pF (≤3 pF); total bus load Cb ≤50 pF for peak speed. *p.172/178.* `src: R-ELEC-04`

**ELE-PU-01** (MUST, FV: no) — Any open-drain-class pull-up switched off during push-pull; disable internal weak pull-ups on SDA/SCL (external bus pull-up used). *p.173.* `src: R-ELEC-05`

**ELE-SPK-01** (MUST/SHOULD, FV: YES on latch) — 50 ns I2C Spike Filter is Not-Allowed at full I3C speed; if a legacy filter exists, disable it after the first I3C Broadcast (7'h7E) ACK / on entering I3C mode. v1 (no I2C) need not implement any filter; any filter MUST be disabled before high-speed SDR so it doesn't erase 24–32 ns half-periods. *p.36/44 (phys 72/80), p.174–175 (phys 210–211).* `src: R-I2CF-01/02/03, R-SPK-01(both), R-SPK-01(elec)`
> `assert: (start_detected && addr7==7'h7E) |=> i3c_mode && !i2c_spike_filter_en`

**ELE-ADDR-01** (MUST, FV: YES) — Static Address (if any) MUST NOT be an I3C Reserved Address nor a TE0-type address (Table 43). Combinational legality check at config. *p.36 (phys 72).* `src: R-ADDR-01/02 (4.3.1)`
> `assert: static_addr_valid |-> !is_i3c_reserved_addr(static_addr) && !is_TE0_addr(static_addr)`

**ELE-SDR-01** (MUST, FV: no) — Bus is always initialized in SDR; primary datapath is SDR (matches v1 scope). *p.33 (phys 69).* `src: R-SDR-01`

---

## 13. Cross-cutting Safety Properties (v1 negative invariants)

These consolidate "MUST NEVER" obligations into directly assertable safety properties:

| ID | Property | Source |
|---|---|---|
| **SAFE-01** | Target never drives SCL: `scl_oe==0` always. | ELE-DRV-02 |
| **SAFE-02** | Target never actively drives a High in an open-drain phase. | BUS-OD-02 |
| **SAFE-03** | Never initiate IBI when `!ibi_en` or `!da_valid` or `bcr[1]==0`. | IBI-EN-01, IBI-ADDR-01, ID-BCR-04 |
| **SAFE-04** | Never arbitrate/self-address after a Repeated START; never drive 7'h02 (Hot-Join) or a Controller-Role-Request pattern. | IBI-NORS-01, HJ-TOL-01 |
| **SAFE-05** | Never self-assign/alter DA except via the enumerated CCC/reset events. | DAA-STABLE-01, ID-ROLE-02 |
| **SAFE-06** | Never ACK an address that is not 7'h7E, the assigned DA, or the ENTDAA flow. | ADR-IGN-01, ACK-COMPLY-01 |
| **SAFE-07** | Never drive read data / push-pull during another Target's Direct segment or when not addressed. | CCC-FORM-01 |
| **SAFE-08** | Never trigger a chip/peripheral reset except via TRP (validated 14-transition + Sr + STOP) or RSTACT-config. | RST-TRP-01..03 |
| **SAFE-09** | Never hang: from any error/ignore/HDR state, a STOP or HDR Exit Pattern returns to idle. | ERR-REC-RESYNC-01 |
| **SAFE-10** | Never become Active Controller / accept handoff (NACK GETACCCR; ACK without handoff). | DAA-NOHANDOFF-01, CCC-NACK-01 |

**HJ-TOL-01** (MUST, FV: YES) — No Hot-Join in v1: never claim/ACK/drive 7'h02; tolerate DISEC(DISHJ) and decode bit3 of the Events Byte cleanly; not disrupted by others' 7'h02 traffic. *p.70/446 (phys 105/482).* `src: R-HJ-01..05, R-TOL-HJ, R-EVT-05`

**I2C-TOL-01** (MUST, FV: YES) — Coexist with legacy I2C traffic without false response: only ACK 7'h7E/DA/DAA; rely on the TE0 detector to avoid misinterpreting I2C/HDR traffic. No Static-Address ACK in v1 (after DA). Do not implement 10-bit addressing, HS/UFm, clock-stretch. *p.36/434–435 (phys 72/470–471).* `src: R-TOL-I2C, R-I2CF-02`

---

## 14. Deferred / Out-of-Scope for v1

| Feature | Status | Notes / minimal tolerance still required |
|---|---|---|
| **HDR data modes (DDR/BT/TSP/TSL)** | Deferred | MUST still detect ENTHDRx + HDR Exit Pattern (HDR-TOL/HDR-EXIT). GETCAP1/4=0. |
| **Active Hot-Join (initiate 7'h02)** | Deferred | MUST never drive 7'h02; tolerate DISEC(DISHJ); decode Events-byte bit3. Failsafe pads (R-HJ-05) future electrical only. |
| **Secondary / Controller role (CRR, GETACCCR, DEFTGTS, DEFGRPA, PRECR, CRHDLY, CRCAPS, DBR)** | Deferred | MUST never accept handoff; NACK GETACCCR/PRECR/CRHDLY; ignore DEFTGTS/DEFGRPA; ACK without handoff. BCR[7:6]=00, controller_capable=0. |
| **Group Addressing (SETGRPA/RSTGRPA/GETGRPA, group multicast)** | Deferred | GETCAP2[5:4]=0. Matcher = {7'h7E, single DA}. SETGRPA → NACK (CCC-NACK-01). No IBI/read on a group address. |
| **Virtual Targets / composite (VTCAPS)** | Deferred | BCR[4]=0; NACK VTCAPS (0x93). |
| **Timing Control (SETXTIME/GETXTIME)** | Deferred | GETCAP3[7]=0; NACK SET/GETXTIME. |
| **Test Mode (ENTTM)** | Deferred | Ignore/NACK (needs unverifiable random PID otherwise). |
| **Multi-Lane / D2DXFER / Bridge / Routing (MLANE, SETBRGTGT, SETROUTE)** | Deferred | GETCAP3[2:0]=0; NACK via CCC-NACK-01. |
| **ENDXFER, ENTTM, Activity States (ENTASx)** | Optional/deferred | Decode-and-ignore / NACK Direct; must keep comms in all activity states. |
| **TE6 read-back monitoring, DBR, 60 µs & 150 µs real-time recoveries** | Optional | SHOULD/MAY; in/out per product decision. |
| **PRN (Pending Read Notification)** | Optional | If implemented, full IBI-PRN-01 obligations apply; GETCAP3[6]=1. |
| **Static-address DA methods (SETDASA/SETAASA, Minimal-Bus 7'h01)** | Optional | ENTDAA mandatory; static methods compile-time options. |
| **Whole-Target reset** | Optional | If supported, must reset all I3C logic; else define conformant default-escalation stop point (OQ). |

---

## 15. Consolidated Open Questions (must be resolved before RTL/property freeze)

Grouped, deduplicated from all section extracts. Each blocks at least one formal property or sizing decision.

### A. Application interface / accept gating
- **OQ-1 (ACK gating):** Is the DA-match ACK always asserted in v1, or gated by an application `accept_en`/busy signal? Required to make ACK-DA-01 meaningful. `src: R-ACK-02`
- **OQ-2 (parity surfacing):** Must a write/T-bit parity mismatch be surfaced to Avalon-MM (vs. only feeding TE2 + GETSTATUS Protocol-Error)? How is it reported? `src: R-WR-02`
- **OQ-3 (peripheral-reset notify):** Form of the application reset-notification IRQ/status bit after a Peripheral reset.

### B. Scope confirmations
- **OQ-4:** Confirm DA-assignment methods implemented (ENTDAA only, or + SETDASA/SETAASA). Drives DAA-DASA/AASA and Static-Address comparator.
- **OQ-5:** Confirm Group Addressing fully out of scope (matcher = {7'h7E, single DA}); defensive reaction to SETGRPA / group-addressed reads = NACK via CCC-NACK-01.
- **OQ-6:** Confirm endpoint MUST NEVER initiate CRR or Hot-Join (7'h02) — assert as SAFE-04; confirm GETACCCR/PRECR/CRHDLY always NACKed.
- **OQ-7 (BCR[2]/MDB):** Decide BCR[2] (IBI MDB present?) — selects IBI-MDB-01 vs IBI-MDB(no payload) and whether the push-pull payload datapath exists.
- **OQ-8 (IBI MDB constants):** Which Interrupt Group / Specific ID does the endpoint emit (vendor 000, I3C-WG 001 error 0x0D/0x0E, or PRN 101)? Drives BCR[2], GETCAP3[6], MDB generator.
- **OQ-9 (DCR constant):** Ship DCR=0x00 (Generic) or a registered code?
- **OQ-10 (Test Mode, Timing Control, TESTPAT, GETCAPS/GETSTATUS Format 2, GETMXDS turnaround):** confirm all out of scope → GETCAP3[7]=0, NACK SET/GETXTIME, NACK 0x5A, NACK Format-2 DBs (define behavior for any DB≠0x00 on a Format-2-incapable Target). `src: multiple §5/§4.3.7`

### C. Error-recovery design choices (must fix one)
- **OQ-11 (retain vs discard):** TE2/TE5/TE6 post-CCC recovery — choose (1) retain CCC state until Sr, or (2) discard until STOP. Affects ERR-TE2-02/TE5-02/TE6.
- **OQ-12 (TE4 recovery):** Body says "wait for STOP"; Table 43 says "STOP or Sr". Does the Target also accept Sr as a TE4 recovery?
- **OQ-13 (TE6 in scope?):** Is optional read-back monitoring implemented, and does the FPGA IO give reliable open-drain line read-back?
- **OQ-14 (CCC-unsupported vs TE5):** Confirm the precise internal distinction between TE5 illegal-format NACK and 4.3.7.2.2 unsupported-but-legal NACK.
- **OQ-15 (pre-DAA decode policy):** What address-decode/ignore policy applies to a freshly powered, un-assigned Target outside ENTDAA (TE0 detector only runs after DA assigned)?

### D. Reset partitioning
- **OQ-16 (escalation persistence):** Which always-on reset domain holds the `escalation_armed` flag and `reset_action_reg` so they survive a Peripheral reset?
- **OQ-17 (peripheral-reset memory):** Are DA and which config registers retained vs cleared on Peripheral reset? Drives RST-PERIPH-02 / ENTDAA participation.
- **OQ-18 (whole-reset optionality tension):** 4.3.9.1 says 2nd TRP "shall reset whole chip" but whole-reset support is optional. If unsupported, what is the conformant escalation behavior (stay at peripheral? NACK?)?
- **OQ-19 (RSTACT DB 0x03/0x04 and 0x40–0x7F):** Treat as unsupported (ignore/no-op/NACK)?
- **OQ-20 (RSTACT scope):** Is full RSTACT (incl. Direct-Read time) mandatory for a minimal v1 Target, or may it rely on default escalation? Need exact reset-time constants (DB 0x81/0x82).

### E. Timing thresholds & real-time behaviors
- **OQ-21 (numeric thresholds):** Concrete cycle counts for tCAS, tBUF, tAVAL, tIDLE, tDIG_L, tDIG_H, tSCO, tSU_PP, trDA from Tables 48/49/50 — needed to parameterize Free/Available/Idle/IBI counters and the exit detector.
- **OQ-22 (real-time recoveries):** Implement 150 µs read-abort (RD-WD-01), 60 µs TE0/TE1 recovery (ERR-REC-60US), 50 ms tCAS watchdog? If so, model as parameterized cycle counters vs. exclude from formal (cover by simulation).
- **OQ-23 (oversampling/metastability):** Fix the internal sample-clock rate (≥~50–100 MHz) and metastability sync depth so exit/START/STOP/TRP detectors meet 32 ns edge spacing; re-implement Listing 1 as synchronous oversampled FSM.
- **OQ-24 (tSCO ≤ 20 ns feasibility):** Confirm FPGA path can meet tSCO ≤ 20 ns; if not, BCR[0]=1 + GETMXDS/maxRD become mandatory.

### F. Bit-level framing details needing cross-section confirmation
- **OQ-25 (START vs Sr discrimination):** Confirm the detector resolution and formal modeling — load-bearing for RST-CFG-02, ERR-TE0-01, BUS-STOPSR-01.
- **OQ-26 (GETCAP3 bit index):** Prose says bit 4 = GETCAPS-Format-2 support; Table 63 labels bit 3 = GETCAPS-DB-support, bit 4 = GETSTATUS-DB-support. Resolve which physical bit encodes GETCAPS Format-2.
- **OQ-27 (Events Byte bit map):** Confirm ENINT=bit0, ENCR=bit1, ENHJ=bit3, others reserved; confirm reserved/unsupported event bits are silently ignored (no protocol error).
- **OQ-28 (Direct-CCC direction-legality matrix):** Full per-CCC SET/GET/Read/Write legality table (needed for the TE5 detector and CCC-UNSUP-CLASS-01).
- **OQ-29 (read T-bit forced termination):** Confirm exactly when the Target drives T=0 (genuine last byte / MRL limit) vs. how it interacts with Controller abort (Sr).
- **OQ-30 (IBI payload count semantics):** Does the Max IBI Payload limit count the MDB itself or only bytes after the MDB? Does the MDB carry its own T-bit, and its semantics?
- **OQ-31 (ENTDAA payload bit map):** Confirm 8-byte order = PID[47:0] (6 B) + BCR + DCR, MSB-first at bit granularity, for the arbitration comparator (Section 5.1.4).
- **OQ-32 (MWL/MRL defaults & range policy):** Define default/min/max MWL and MRL; decide out-of-range SETMWL/SETMRL = leave-unchanged (SHOULD) vs NACK.
- **OQ-33 (GETSTATUS Activity Mode bits):** LSB[7:6] meaning is a private contract — define product values (or tie 0).
- **OQ-34 (SETBUSCON action):** Confirm tolerate-only (no functional dependence on context byte) for a minimal v1 Target.
- **OQ-35 (ENDXFER condition):** Confirm no SDR-mode obligation (treat as fully NACK-able) before final freeze.
- **OQ-36 (passive-NACK / open-drain harness soundness):** Confirm NACK = `sda_oe=0` and that the Altera tri-state/IO model in the formal harness represents bus contention safely so open-drain ACK/arbitration properties are sound.
- **OQ-37 (HDR-Exit/error-state coupling):** The set of "error states recoverable by HDR Exit Pattern" (HDR-EXIT-04 case B) is defined in §4.3.8.1 — cross-reference to wire `err_recoverable`.

---

### Relevant file paths
This master specification is returned inline (no file written, per instructions). Project root: `/home/tcovert/projects/i3c_endpoint_formally_verified`. No source RTL/property files exist yet to reference; the next deliverables are the RTL module hierarchy and the SymbiYosys property set keyed to the IDs above (suggested files: `/home/tcovert/projects/i3c_endpoint_formally_verified/rtl/`, `/home/tcovert/projects/i3c_endpoint_formally_verified/formal/`).
