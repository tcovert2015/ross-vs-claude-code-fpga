# Inter-Module Interface Contract (FROZEN)
## I3C Basic v1.2 SDR + IBI Target — port + connectivity contract

This file is the **binding port contract**. Every implementer codes their module's port
list **exactly** to the table here (names, directions, widths). It is consistent with the
already-proven modules (`i3c_pkg`, `i3c_sda_mux`, `i3c_io_altera`, `i3c_bus_frontend`,
`i3c_regfile`) and with `docs/architecture.md` §1/§3 and `docs/design_decisions.md`.

Where this file and an `architecture.md` "I/O sketch" disagree, **this file wins** (the
sketches predate the frozen single-owner-mux decision F-2). Deviations from the sketches
are called out under "Naming decisions" at the bottom.

---

## 0. Global conventions (apply to every module unless stated)

| Item | Rule |
|---|---|
| Clock | `clk` — single free-running `sys_clk` oversample domain (D-1: ≥100 MHz). `i3c_avalon_mm` + the read side of `i3c_fifo` MAY use a separate `avl_clk`; default config ties `avl_clk = clk`. |
| Reset | `rst_n` — active-low, synchronously de-asserted. Formal: `initial assume(!rst_n)`. |
| Strobes | All `*_stb` / `*_rising` / `*_falling` are **1-cycle** pulses in the `clk` domain. Standalone proofs `assume` bus-event strobes are ≥ K cycles apart (idealized-edge model, architecture §2.4). |
| Booleans | `1` = asserted/true. Active-low signals carry an `_n` suffix. |
| SDA drive | Every block that drives SDA exposes a 2-bit request `{<src>_oe, <src>_o}`. `oe=1,o=0`→drive Low; `oe=1,o=1`→drive High (push-pull phases only); `oe=0`→release. `i3c_target_top` wires each into `i3c_sda_mux.src_oe[SDA_*]` / `src_o[SDA_*]` (indices from `i3c_pkg`). The mux output `sda_oe/sda_o` is the **only** signal reaching the pad and the **only** SDA-drive feedback to the front-end. |
| Phase | `phase` is `i3c_pkg::phase_e` (`PH_IDLE/PH_ADDR/PH_DATA`). |
| Dynamic address | `dyn_addr[6:0]` + `da_valid` are **owned by `i3c_daa`** and fanned out read-only to every consumer. |
| FIFO words | RX/TX FIFO payloads use `i3c_pkg::RX_FIFO_W` (11) / `TX_FIFO_W` (9) and the `RXF_*`/`TXF_*` field offsets. |
| Package use | `import`/`include "i3c_pkg.sv"`; never redefine its constants/types. |

### SDA mux source ownership (single-owner, critique F-2 — `$onehot0(src_oe)` proven at integration)

| `i3c_pkg` index | Source | Owning module | Drive port pair |
|---|---|---|---|
| `SDA_ACK`=0  | address/CCC ACK bit        | `i3c_protocol_fsm` | `ack_oe`/`ack_o` |
| `SDA_TBIT`=1 | read T-bit                  | `i3c_framer`       | `tbit_oe`/`tbit_o` |
| `SDA_RDATA`=2| read-data byte bits         | `i3c_bit_engine`   | `rdata_oe`/`rdata_o` |
| `SDA_DAA`=3  | ENTDAA payload + DAA ACK    | `i3c_daa`          | `daa_oe`/`daa_o` |
| `SDA_IBI`=4  | IBI addr/MDB/payload bits   | `i3c_ibi`          | `ibi_oe`/`ibi_o` |
| `SDA_DBG`=5  | reserved/debug              | (tied `0` in top)  | — |

---

## 1. Already-built modules (READ-ONLY reference — do not change ports)

### 1.1 `i3c_sda_mux` (proven)
`#(N=i3c_pkg::SDA_NSRC)` · `clk, rst_n, src_oe[N-1:0], src_o[N-1:0]` → `sda_oe, sda_o`.

### 1.2 `i3c_io_altera` (proven, vendor)
`sda_oe, sda_o` (in) · `sda_i, scl_i` (out) · `inout SDA, input SCL`.

### 1.3 `i3c_bus_frontend` (proven)
`#(SYNC_STAGES, CNT_W, BUS_FREE_CYCLES, BUS_AVAIL_CYCLES, BUS_IDLE_CYCLES)`
- in: `clk, rst_n, sda_i, scl_i, sda_oe`
- out: `sda_sync, scl_sync, scl_rising, scl_falling, sda_rising, sda_falling, start_stb, rstart_stb, stop_stb, bus_busy, bus_free, bus_available, bus_idle`

These output names are the **canonical bus-event signal names** used everywhere below.

### 1.4 `i3c_regfile` — identity already built; full contract in §2.3 below
Currently implements `clk, rst_n` → `bcr[7:0], dcr[7:0], pid[47:0]` (params `BCR, DCR, MFG_ID, PID_TYPE, PID_VAL`). §2.3 adds the mutable-register ports for later slices; the existing five ports/params are retained verbatim.

---

## 2. Module port tables (to be implemented)

Legend: dir = in/out (w.r.t. the module). Width `1` omitted as `1`.

### 2.1 `i3c_bit_engine` — bit shift / deserialize + read-data serialize

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `sda_sync` | in | 1 | synchronized SDA level (front-end) |
| `scl_rising` | in | 1 | SCL↑ strobe — RX sample point |
| `scl_falling` | in | 1 | SCL↓ strobe — TX drive-update point |
| `start_stb` | in | 1 | plain START — clears bit counter / RX shift |
| `rstart_stb` | in | 1 | repeated START — clears bit counter / RX shift |
| `tx_load` | in | 1 | latch `tx_byte` to begin serializing a read-data byte |
| `tx_byte` | in | 8 | read-data byte to send, MSb first |
| `tx_drive_en` | in | 1 | hold SDA_RDATA driven while sending (push-pull) |
| `rx_byte` | out | 8 | last fully-received 8-bit byte, MSb first |
| `bit_cnt` | out | 4 | current bit index 0..8 within the frame |
| `byte_done` | out | 1 | pulses when the 8th data bit has been sampled |
| `sda_bit` | out | 1 | value sampled at the most recent `scl_rising` |
| `rdata_oe` | out | 1 | → `src_oe[SDA_RDATA]` |
| `rdata_o` | out | 1 | → `src_o[SDA_RDATA]` |

*Arbitration loss is computed locally in `i3c_daa`/`i3c_ibi` (read data is push-pull, never arbitrated); the bit engine has no `arb_lost` port — see Naming decision N-1.*

### 2.2 `i3c_framer` — 9th-bit (T/ACK) framing, write parity, read T-bit

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `phase` | in | 2 | `i3c_pkg::phase_e` (from protocol FSM) |
| `is_read` | in | 1 | current data direction (1 = Controller reads from Target) |
| `more_read_data` | in | 1 | Target has a further read byte (drives continue-T=1) |
| `rx_byte` | in | 8 | assembled byte (write-parity source) |
| `sda_bit` | in | 1 | sampled SDA at `scl_rising` (read controller's T-bit on write) |
| `byte_done` | in | 1 | enter the 9th-bit slot |
| `scl_rising` | in | 1 | sample strobe |
| `scl_falling` | in | 1 | drive-update strobe |
| `rstart_stb` | in | 1 | detect read-abort (Sr after continue-T) |
| `ninth_slot` | out | 1 | currently in the 9th (T/ACK) bit slot |
| `ack_slot` | out | 1 | 9th slot is ACK/NACK (`phase==PH_ADDR`) |
| `tbit_slot` | out | 1 | 9th slot is a T-bit (`phase==PH_DATA`) |
| `parity_ok` | out | 1 | write odd-parity matched (`= sampled_t == ~^rx_byte`) |
| `parity_err` | out | 1 | write parity mismatch (TE2 source) |
| `t_drive_val` | out | 1 | read T-bit the Target drives (0=last, 1=continue) |
| `read_abort` | out | 1 | Controller aborted read (Sr after continue-T) |
| `tbit_oe` | out | 1 | → `src_oe[SDA_TBIT]` |
| `tbit_o` | out | 1 | → `src_o[SDA_TBIT]` |

### 2.3 `i3c_regfile` — identity + SET/GET registers + status + reset-action

Params: `BCR, DCR, MFG_ID, PID_TYPE, PID_VAL` (built) plus `MWL_DEFAULT[15:0], MRL_DEFAULT[15:0], MAXIBI_DEFAULT[7:0], GETCAP3[7:0]=i3c_pkg::GETCAP3_DEFAULT`.

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `bcr` | out | 8 | BCR constant (built) |
| `dcr` | out | 8 | DCR constant (built) |
| `pid` | out | 48 | Provisioned ID (built) |
| `mwl` | out | 16 | Max Write Length |
| `mrl` | out | 16 | Max Read Length |
| `max_ibi_payload` | out | 8 | Max IBI payload (0 = unlimited) |
| `ibi_en` | out | 1 | bus event-enable (ENEC/DISEC EVT_ENINT); reset = 1 |
| `getstatus_word` | out | 16 | assembled GETSTATUS Format-1 word |
| `getcaps` | out | 32 | {GETCAP4,GETCAP3,GETCAP2,GETCAP1} |
| `reset_action` | out | 2 | RSTACT action (0=none,1=periph,2=whole) |
| `escalation_armed` | out | 1 | Target-Reset escalation armed (always-on domain) |
| `last_reset_was_whole` | out | 1 | status of last reset |
| `proto_err_seen` | out | 1 | sticky protocol-error (GETSTATUS[5]) |
| **CCC bus-side writes (from `i3c_ccc`)** | | | |
| `ccc_set_mwl` | in | 1 | commit `ccc_mwl_val` to MWL |
| `ccc_mwl_val` | in | 16 | SETMWL value |
| `ccc_set_mrl` | in | 1 | commit `ccc_mrl_val` to MRL |
| `ccc_mrl_val` | in | 16 | SETMRL value |
| `ccc_set_maxibi` | in | 1 | commit `ccc_maxibi_val` |
| `ccc_maxibi_val` | in | 8 | SETMRL 3rd byte (Max IBI payload) |
| `ccc_ibi_en_set` | in | 1 | ENEC EVT_ENINT → `ibi_en=1` |
| `ccc_ibi_en_clr` | in | 1 | DISEC EVT_ENINT → `ibi_en=0` |
| `ccc_set_rstact` | in | 1 | commit RSTACT defining byte |
| `ccc_rstact_val` | in | 8 | RSTACT defining byte |
| `getstatus_rd` | in | 1 | GETSTATUS read complete → clear `proto_err_seen` |
| **status / reset events** | | | |
| `proto_err_set` | in | 1 | set sticky proto-err (from `i3c_error_recovery`) |
| `pending_irq` | in | 4 | GETSTATUS pending-interrupt field (from app/INT) |
| `activity_mode` | in | 2 | GETSTATUS activity-mode field |
| `trp_trigger` | in | 1 | Target-Reset fired (escalation/arm update) |
| `start_clr` | in | 1 | plain START → clear `reset_action` (R-RSTACT-03) |
| `periph_reset` | in | 1 | peripheral reset event |
| `whole_reset` | in | 1 | whole-target reset event (clears config to defaults) |
| **app-side (from `i3c_avalon_mm`)** | | | |
| `app_wr_en` | in | 1 | application register write |
| `app_wr_idx` | in | 4 | register word index (see §3 map, regfile-owned offsets) |
| `app_wr_data` | in | 32 | write data |
| `app_wr_be` | in | 4 | byte-enables |
| `app_rd_idx` | in | 4 | register read index |
| `app_rd_data` | out | 32 | read data for `app_rd_idx` |

### 2.4 `i3c_hdr_exit_detector` — HDR-Exit + Target-Reset-Pattern recognizer

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `sda_sync` | in | 1 | synced SDA level |
| `scl_sync` | in | 1 | synced SCL level (counter qualified by `scl_sync==0`; `==1` resets count) |
| `sda_falling` | in | 1 | SDA↓ strobe (HDR-Exit counts 4 falls) |
| `sda_rising` | in | 1 | SDA↑ strobe (TRP counts 14 transitions) |
| `rstart_stb` | in | 1 | Sr (TRP order: body→Sr→STOP) |
| `stop_stb` | in | 1 | STOP (completes HDR-Exit / TRP) |
| `exit_en` | in | 1 | enable (`is_hdr || err_recoverable`) |
| `hdr_exit_detected` | out | 1 | 4 SDA falls w/ SCL Low → HDR Exit |
| `trp_body_valid` | out | 1 | 14-transition Target-Reset body recognized |
| `trp_trigger` | out | 1 | body→Sr→STOP completed → fire Target Reset |

### 2.5 `i3c_fifo` — generic RX/TX FIFO (single- or dual-clock)

Params: `DW` (`i3c_pkg::RX_FIFO_W` or `TX_FIFO_W`), `DEPTH`, `AW=$clog2(DEPTH)`, `ASYNC` (0 = single-clock; tie `rd_clk=wr_clk`).

| Signal | dir | width | meaning |
|---|---|---|---|
| `wr_clk`,`wr_rst_n` | in | 1 | write-side clock/reset |
| `wr_en` | in | 1 | push |
| `wr_data` | in | DW | data in |
| `full` | out | 1 | write-side full |
| `wr_level` | out | AW+1 | write-side occupancy |
| `overflow` | out | 1 | sticky push-while-full (no silent loss, V5) |
| `rd_clk`,`rd_rst_n` | in | 1 | read-side clock/reset (= write side if `ASYNC=0`) |
| `rd_en` | in | 1 | pop |
| `rd_data` | out | DW | head word |
| `empty` | out | 1 | read-side empty |
| `rd_level` | out | AW+1 | read-side occupancy |

### 2.6 `i3c_protocol_fsm` — SDR sequencer: address match, ACK, private R/W, routing

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `start_stb`,`rstart_stb`,`stop_stb` | in | 1 | bus conditions (front-end) |
| `scl_rising`,`scl_falling` | in | 1 | SCL edge strobes |
| `bus_available` | in | 1 | tAVAL elapsed (front-end) |
| `rx_byte` | in | 8 | assembled byte (bit engine) |
| `byte_done` | in | 1 | 8 data bits received (bit engine) |
| `bit_cnt` | in | 4 | bit index (bit engine) |
| `ack_slot`,`tbit_slot`,`ninth_slot` | in | 1 | framer slot flags |
| `parity_err`,`read_abort` | in | 1 | framer error/abort flags |
| `da_valid`,`dyn_addr` | in | 1/7 | dynamic address (from `i3c_daa`) |
| `daa_active` | in | 1 | a DAA round is in progress (route 7E/R → DAA) |
| `accept_en` | in | 1 | CTRL[1]: ACK private R/W on DA match (R-ACK-02) |
| `core_en` | in | 1 | CTRL[0]: core enable |
| `rx_can_accept` | in | 1 | RX FIFO not full (`!full`) |
| `ccc_ack` | in | 1 | CCC layer wants ACK at directed address |
| `ccc_getstatus_seg` | in | 1 | current segment is GETSTATUS/identity-GET (ACK-bypass B-1) |
| `ccc_resp_valid` | in | 1 | CCC read-response byte available |
| `ccc_resp_byte` | in | 8 | CCC read-response byte (GET* result) |
| `ccc_resp_last` | in | 1 | last CCC response byte |
| `tx_empty` | in | 1 | TX FIFO empty |
| `tx_byte` | in | 8 | TX FIFO head byte (`[TXF_DATA_LSB+:8]`) |
| `tx_last` | in | 1 | TX FIFO head last flag (`[TXF_LAST]`) |
| `in_error` | in | 1 | error-recovery active (inhibit) |
| `ack_inhibit` | in | 1 | error layer forbids ACK this slot |
| `in_hdr_quiesce` | in | 1 | HDR quiesce (inhibit drive) |
| `phase` | out | 2 | `phase_e` to framer/bit engine |
| `state_idle`,`state_ignore` | out | 1 | decoded FSM state (status / S3) |
| `match_7e` | out | 1 | address byte == 7'h7E |
| `match_da` | out | 1 | address byte == `dyn_addr` and `da_valid` |
| `is_broadcast` | out | 1 | current frame is a broadcast (7E) frame |
| `is_read` | out | 1 | captured RnW (1 = read) |
| `addr_capture_armed` | out | 1 | armed to capture address after (R)START (F2) |
| `post_rstart` | out | 1 | sticky: a Sr occurred this frame (S4) |
| `ack_oe`,`ack_o` | out | 1 | → `src[SDA_ACK]` (address/CCC ACK) |
| `tx_load`,`tx_byte_out` | out | 1/8 | load read byte into bit engine (muxed FIFO/CCC) |
| `tx_drive_en` | out | 1 | bit-engine read-data drive enable |
| `more_read_data` | out | 1 | another read byte pending (to framer) |
| `tx_pop` | out | 1 | pop TX FIFO (private read byte consumed) |
| `rx_push` | out | 1 | push RX FIFO |
| `rx_wdata` | out | 11 | RX word `{is_ccc,last,valid,data}` (`RXF_*`) |
| `to_ccc` | out | 1 | route: broadcast/direct CCC frame active |
| `priv_write_done` | out | 1 | private write finished (INT) |
| `priv_read_req` | out | 1 | private read requested (INT) |

### 2.7 `i3c_daa` — ENTDAA arbitration + DA lifecycle (owns `dyn_addr`/`da_valid`)

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `scl_rising`,`scl_falling` | in | 1 | SCL edge strobes |
| `sda_sync` | in | 1 | sampled SDA (per-bit arbitration, PAR capture) |
| `start_stb`,`rstart_stb`,`stop_stb` | in | 1 | bus conditions |
| `bit_cnt` | in | 4 | bit index (bit engine) |
| `byte_done` | in | 1 | byte boundary (DA/PAR capture) |
| `rx_byte` | in | 8 | assembled byte (DA + parity) |
| `pid` | in | 48 | Provisioned ID (regfile) |
| `bcr` | in | 8 | BCR (regfile) |
| `dcr` | in | 8 | DCR (regfile) |
| `entdaa_start` | in | 1 | ENTDAA broadcast accepted (from `i3c_ccc`) |
| `entdaa_active` | in | 1 | in an ENTDAA round (CCC-tracked) |
| `rstdaa` | in | 1 | RSTDAA → clear DA (from `i3c_ccc`) |
| `setdasa_load` | in | 1 | SETDASA load (static_en) |
| `setaasa_load` | in | 1 | SETAASA load (static_en) |
| `setnewda_load` | in | 1 | SETNEWDA load |
| `load_addr` | in | 7 | DA to load for SET*DASA/SETNEWDA |
| `whole_reset` | in | 1 | clear DA on whole-target reset |
| `dyn_addr` | out | 7 | current dynamic address |
| `da_valid` | out | 1 | dynamic address assigned |
| `daa_active` | out | 1 | DAA round in progress (to protocol FSM routing) |
| `daa_done` | out | 1 | DA latched this round (INT `da_changed`) |
| `daa_oe`,`daa_o` | out | 1 | → `src[SDA_DAA]` (64-bit payload + DAA ACK) |
| `arb_lost` | out | 1 | lost ENTDAA arbitration this round |
| `par_err` | out | 1 | DA odd-parity mismatch (TE3 source) |
| `te4_event` | out | 1 | non-{7E,R} header after Sr inside DAA (TE4) |

### 2.8 `i3c_ccc` — CCC decode + handlers

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `start_stb`,`rstart_stb`,`stop_stb` | in | 1 | bus conditions |
| `scl_rising`,`scl_falling` | in | 1 | SCL edge strobes |
| `rx_byte` | in | 8 | assembled byte |
| `byte_done` | in | 1 | byte boundary |
| `bit_cnt` | in | 4 | bit index |
| `phase` | in | 2 | `phase_e` |
| `ninth_slot`,`ack_slot` | in | 1 | framer slot flags |
| `match_7e`,`match_da` | in | 1 | address match (protocol FSM) |
| `is_broadcast`,`is_read` | in | 1 | frame class / direction |
| `da_valid` | in | 1 | DA assigned |
| `bcr`,`dcr` | in | 8 | identity (regfile) for GET* |
| `pid` | in | 48 | identity (regfile) for GETPID |
| `mwl`,`mrl` | in | 16 | regfile config for GET* |
| `max_ibi_payload` | in | 8 | regfile config (GETMRL 3rd byte) |
| `getstatus_word` | in | 16 | regfile-assembled GETSTATUS |
| `getcaps` | in | 32 | regfile GETCAPS bytes |
| `ccc_code` | out | 8 | latched CCC code |
| `ccc_is_direct` | out | 1 | `= ccc_code[7]` |
| `ccc_supported` | out | 1 | code+defining-byte supported (else NACK, K6) |
| `ccc_ack` | out | 1 | directed-address ACK request (to protocol FSM) |
| `ccc_getstatus_seg` | out | 1 | segment is GETSTATUS/identity-GET (ACK-bypass B-1) |
| `ccc_resp_valid` | out | 1 | GET* response byte available |
| `ccc_resp_byte` | out | 8 | GET* response byte, MSb-first |
| `ccc_resp_last` | out | 1 | last GET* response byte |
| `enthdr_seen` | out | 1 | ENTHDRx → quiesce (to error/quiesce logic) |
| `entdaa_start` | out | 1 | ENTDAA accepted (to `i3c_daa`) |
| `entdaa_active` | out | 1 | ENTDAA round active (to `i3c_daa`/routing) |
| `rstdaa` | out | 1 | RSTDAA (to `i3c_daa`) |
| `setdasa_load`,`setaasa_load`,`setnewda_load` | out | 1 | DA-load strobes (to `i3c_daa`) |
| `load_addr` | out | 7 | DA value for SET*DASA/SETNEWDA |
| `ccc_set_mwl`,`ccc_mwl_val` | out | 1/16 | SETMWL → regfile |
| `ccc_set_mrl`,`ccc_mrl_val` | out | 1/16 | SETMRL → regfile |
| `ccc_set_maxibi`,`ccc_maxibi_val` | out | 1/8 | SETMRL 3rd byte → regfile |
| `ccc_ibi_en_set`,`ccc_ibi_en_clr` | out | 1 | ENEC/DISEC EVT_ENINT → regfile |
| `ccc_set_rstact`,`ccc_rstact_val` | out | 1/8 | RSTACT defining byte → regfile |
| `getstatus_rd` | out | 1 | GETSTATUS read complete (regfile clear-on-read) |
| `ccc_code_parity_err` | out | 1 | CCC code parity bad (TE1 source) |
| `ccc_illegal_format` | out | 1 | malformed CCC framing (TE5 source) |
| `ccc_event` | out | 1 | ENEC/DISEC/SET* occurred (INT) |

### 2.9 `i3c_ibi` — IBI request / arbitration / MDB + payload

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `scl_rising`,`scl_falling` | in | 1 | SCL edge strobes |
| `sda_sync` | in | 1 | sampled SDA (arbitration) |
| `start_stb`,`rstart_stb`,`stop_stb` | in | 1 | bus conditions |
| `bus_available` | in | 1 | tAVAL elapsed (gate) |
| `post_rstart` | in | 1 | a Sr occurred (no IBI after Sr, S4/I1) |
| `dyn_addr`,`da_valid` | in | 7/1 | dynamic address (from `i3c_daa`) |
| `bcr` | in | 8 | BCR — `[1]` IBI-capable, `[2]` MDB present |
| `ibi_en` | in | 1 | bus event-enable (regfile) |
| `ibi_en_app` | in | 1 | CTRL[2] application gate |
| `ibi_request` | in | 1 | request an IBI (from IBI_CTRL/Avalon) |
| `mdb` | in | 8 | Mandatory Data Byte |
| `mdb_is_prn` | in | 1 | MDB is a Pending-Read-Notification |
| `max_ibi_payload` | in | 8 | payload bound (regfile; 0 = unlimited) |
| `pl_byte` | in | 8 | IBI payload head byte (TX/IBI FIFO) |
| `pl_valid` | in | 1 | payload byte available |
| `pl_last` | in | 1 | last payload byte |
| `ibi_oe`,`ibi_o` | out | 1 | → `src[SDA_IBI]` |
| `pl_pop` | out | 1 | pop IBI payload FIFO |
| `ibi_active` | out | 1 | IBI sequence in progress |
| `ibi_busy` | out | 1 | request accepted, not yet done (STATUS[11]) |
| `ibi_acked` | out | 1 | controller ACKed the IBI address |
| `ibi_nacked` | out | 1 | controller NACKed the IBI |
| `ibi_arb_lost` | out | 1 | lost IBI arbitration |
| `ibi_deferred` | out | 1 | deferred on collision/back-off |
| `ibi_done` | out | 1 | sequence complete (INT) |
| `ibi_addr` | out | 7 | address driven in the IBI header (== `dyn_addr`, I3) |

### 2.10 `i3c_error_recovery` — TE0..TE6 detect + recovery FSM

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk`,`rst_n` | in | 1 | common |
| `start_stb`,`rstart_stb`,`stop_stb` | in | 1 | bus conditions |
| `scl_rising`,`scl_falling` | in | 1 | SCL edge strobes |
| `rx_byte` | in | 8 | address/CCC byte (TE0 restricted-addr LUT) |
| `byte_done` | in | 1 | byte boundary |
| `phase` | in | 2 | `phase_e` |
| `match_7e`,`match_da` | in | 1 | address match |
| `is_read` | in | 1 | RnW |
| `da_valid` | in | 1 | DA assigned |
| `daa_active` | in | 1 | inside ENTDAA (masks TE0, enables TE4) |
| `parity_err` | in | 1 | write-data parity (framer, TE2) |
| `par_err` | in | 1 | DAA PAR error (daa, TE3) |
| `te4_event` | in | 1 | DAA non-{7E,R} after Sr (daa, TE4) |
| `ccc_code_parity_err` | in | 1 | CCC code parity (ccc, TE1) |
| `ccc_illegal_format` | in | 1 | malformed CCC (ccc, TE5) |
| `ccc_supported` | in | 1 | unsupported ≠ TE5 (E7) |
| `hdr_exit_detected` | in | 1 | HDR-Exit recovery event |
| `in_error` | out | 1 | recovery active (STATUS[3]) |
| `err_recoverable` | out | 1 | enables HDR-Exit detector (`exit_en`) |
| `ack_inhibit` | out | 1 | forbid ACK while in error (to protocol FSM) |
| `drive_inhibit` | out | 1 | forbid any SDA drive (S3) |
| `proto_err_set` | out | 1 | set sticky proto-err (to regfile) |
| `te_code` | out | 4 | last TE code (STATUS[10:7]) |

### 2.11 `i3c_avalon_mm` — Avalon-MM agent + FIFO/IBI/INT glue

Params: `AW=5` (word address). Register map in §3.

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk` (`avl_clk`),`rst_n` | in | 1 | Avalon clock/reset (default = `sys_clk`) |
| **Avalon-MM agent** | | | |
| `avs_address` | in | AW | word address |
| `avs_read` | in | 1 | read command |
| `avs_write` | in | 1 | write command |
| `avs_writedata` | in | 32 | write data |
| `avs_byteenable` | in | 4 | byte enables |
| `avs_readdata` | out | 32 | read data |
| `avs_readdatavalid` | out | 1 | read-data valid (V1) |
| `avs_waitrequest` | out | 1 | back-pressure (V2) |
| `irq` | out | 1 | `\| (int_status & int_enable)` (V6) |
| **regfile app port** | | | |
| `app_wr_en`,`app_wr_idx`,`app_wr_data`,`app_wr_be` | out | 1/4/32/4 | regfile write |
| `app_rd_idx` | out | 4 | regfile read index |
| `app_rd_data` | in | 32 | regfile read data |
| **RX FIFO (read side)** | | | |
| `rx_rd_data` | in | 11 | RX head word |
| `rx_empty` | in | 1 | RX empty |
| `rx_level` | in | 8 | RX occupancy |
| `rx_overflow` | in | 1 | RX overflow sticky |
| `rx_pop` | out | 1 | pop RX on the read SAMPLE beat of RX_DATA (one cycle before readdatavalid; readdata is registered, issue #1), D-3 |
| **TX FIFO (write side)** | | | |
| `tx_full` | in | 1 | TX full |
| `tx_level` | in | 8 | TX occupancy |
| `tx_push` | out | 1 | push TX |
| `tx_wr_data` | out | 9 | TX word `{last,data}` (`TXF_*`) |
| `flush_rx`,`flush_tx` | out | 1 | CTRL[6]/[7] FIFO flush |
| **IBI control / status** | | | |
| `ibi_request` | out | 1 | trigger IBI (IBI_CTRL[0]) |
| `mdb` | out | 8 | MDB (IBI_CTRL[12:5]) |
| `mdb_is_prn` | out | 1 | IBI_CTRL[15] |
| `ibi_busy`,`ibi_acked`,`ibi_nacked`,`ibi_deferred`,`ibi_arb_lost` | in | 1 | IBI_STATUS |
| **CTRL outputs to core** | | | |
| `core_en`,`accept_en`,`ibi_en_app`,`soft_reset`,`static_addr_en`,`prn_send_en` | out | 1 | CTRL[0..5] |
| **status inputs from core** | | | |
| `da_valid`,`dyn_addr` | in | 1/7 | DA mirror (from `i3c_daa`) → DYN_ADDR/STATUS |
| `in_hdr_quiesce`,`in_error` | in | 1 | STATUS[2]/[3] |
| `bus_busy`,`bus_free`,`bus_available`,`bus_idle` | in | 1 | front-end → STATUS bus_state[6:4] |
| `te_code` | in | 4 | STATUS[10:7] |
| `proto_err_seen` | in | 1 | STATUS[12] |
| **INT sources (latched into INT_STATUS, W1C)** | | | |
| `int_rx_ready` | in | 1 | RX FIFO has data |
| `int_tx_space` | in | 1 | TX FIFO has space |
| `int_priv_write_done` | in | 1 | private write done |
| `int_priv_read_req` | in | 1 | private read requested |
| `int_ibi_done` | in | 1 | IBI done |
| `int_ibi_nacked` | in | 1 | IBI NACKed |
| `int_da_changed` | in | 1 | DA changed (`daa_done`) |
| `int_periph_reset` | in | 1 | peripheral reset notify |
| `int_proto_err` | in | 1 | protocol error |
| `int_ccc_event` | in | 1 | ENEC/DISEC/SET* event |

### 2.12 `i3c_target_top` — device-agnostic top (instantiates all of the above + mux + IO)

Params (straps, forwarded to children): `BCR, DCR, MFG_ID, PID_TYPE, PID_VAL, MWL_DEFAULT, MRL_DEFAULT, MAXIBI_DEFAULT, GETCAP3, STATIC_ADDR_EN, RX_DEPTH, TX_DEPTH, SYNC_STAGES, BUS_FREE_CYCLES, BUS_AVAIL_CYCLES, BUS_IDLE_CYCLES, AVL_ASYNC`.

| Signal | dir | width | meaning |
|---|---|---|---|
| `clk` | in | 1 | `sys_clk` |
| `rst_n` | in | 1 | system reset |
| `avl_clk` | in | 1 | Avalon clock (tie to `clk` if `AVL_ASYNC=0`) |
| `avl_rst_n` | in | 1 | Avalon reset |
| `avs_address` | in | 5 | Avalon word address |
| `avs_read`,`avs_write` | in | 1 | Avalon commands |
| `avs_writedata` | in | 32 | Avalon write data |
| `avs_byteenable` | in | 4 | byte enables |
| `avs_readdata` | out | 32 | Avalon read data |
| `avs_readdatavalid` | out | 1 | read-data valid |
| `avs_waitrequest` | out | 1 | back-pressure |
| `irq` | out | 1 | interrupt |
| `SDA` | inout | 1 | I3C SDA pad |
| `SCL` | in | 1 | I3C SCL pad (input only — Target never drives SCL) |

---

## 3. Avalon-MM register map (authoritative, mirrors architecture §3)

32-bit, word-aligned (`avs_address` = byte offset ÷ 4). Storage owner: **RF** = `i3c_regfile`, **AV** = `i3c_avalon_mm`, **FIFO**, **core** = live core status.

| Off | Idx | Name | Owner | Key fields |
|---|---|---|---|---|
| 0x00 | 0 | CTRL | AV | [0]core_en [1]accept_en [2]ibi_en_app [3]soft_reset [4]static_addr_en [5]prn_send_en [6]flush_rx [7]flush_tx |
| 0x04 | 1 | STATUS | core | [0]da_valid [1]i3c_mode [2]in_hdr_quiesce [3]in_error [6:4]bus_state [10:7]te_code [11]ibi_busy [12]proto_err_seen [13]rx_overflow |
| 0x08 | 2 | INT_ENABLE | AV | mirror of INT_STATUS |
| 0x0C | 3 | INT_STATUS | AV | W1C: [0]rx_ready [1]tx_space [2]priv_write_done [3]priv_read_req [4]ibi_done [5]ibi_nacked [6]da_changed [7]periph_reset [8]proto_err [9]ccc_event |
| 0x10 | 4 | DYN_ADDR | core | [6:0]dyn_addr [7]da_valid (RO) |
| 0x14 | 5 | PID_LOW | RF | PID[31:0] |
| 0x18 | 6 | PID_HIGH | RF | [15:0]PID[47:32] |
| 0x1C | 7 | IDENT | RF | [7:0]bcr [15:8]dcr [22:16]static_addr [23]static_addr_valid |
| 0x20 | 8 | MWL | RF | [15:0]max_write_len |
| 0x24 | 9 | MRL | RF | [15:0]max_read_len [23:16]max_ibi_payload |
| 0x28 | 10 | IBI_CTRL | AV | [0]ibi_request [12:5]mdb [15]mdb_is_prn [23:16]payload_len |
| 0x2C | 11 | IBI_STATUS | core | [0]ibi_pending [1]ibi_acked [2]ibi_nacked [3]arb_lost [4]deferred |
| 0x30 | 12 | RX_DATA | FIFO | [7:0]data [8]valid [9]last [10]is_ccc (pop on read) |
| 0x34 | 13 | TX_DATA | FIFO | [7:0]data [8]last (push on write) |
| 0x38 | 14 | FIFO_STATUS | FIFO | [7:0]rx_level [15:8]tx_level [16]rx_empty [17]tx_full |
| 0x3C | 15 | GETSTATUS_CFG | RF | [7:0]vendor_msb [9:8]activity_mode [13:10]pending_irq |
| 0x40 | 16 | CAPS | RF | [7:0]GETCAP1 [15:8]GETCAP2 [23:16]GETCAP3 [31:24]GETCAP4 |
| 0x44 | 17 | RESET_CFG | RF | [1:0]reset_action [2]escalation_armed(RO) [3]last_reset_was_whole(RO) |

`bus_state[6:4]` encoding (AV-assembled from front-end): 0=idle,1=free,2=available,3=busy.
`app_wr_idx`/`app_rd_idx` use the RF-owned indices above (5..9,15,16,17).

---

## 4. Top-level connectivity map (`i3c_target_top` netlist)

Notation `A.out → B.in` means signal `out` of instance `A` drives input `in` of `B`.
`u_*` = instance names. All `clk/rst_n` go to `sys_clk`/`rst_n` unless noted.

```
PADS
  SCL(pad)                         → u_io.SCL
  SDA(pad)                         ↔ u_io.SDA

IO  (u_io : i3c_io_altera)
  u_sda_mux.sda_oe                 → u_io.sda_oe
  u_sda_mux.sda_o                  → u_io.sda_o
  u_io.sda_i                       → u_fe.sda_i
  u_io.scl_i                       → u_fe.scl_i

FRONT-END  (u_fe : i3c_bus_frontend)
  u_sda_mux.sda_oe                 → u_fe.sda_oe          (F-3 gate)
  u_fe.{sda_sync,scl_sync,scl_rising,scl_falling,sda_rising,sda_falling}
  u_fe.{start_stb,rstart_stb,stop_stb,bus_busy,bus_free,bus_available,bus_idle}
       → fan out to ALL core blocks per their port tables.

SDA MUX  (u_sda_mux : i3c_sda_mux, N=SDA_NSRC)
  src_oe[SDA_ACK]   = u_pfsm.ack_oe    ; src_o[SDA_ACK]   = u_pfsm.ack_o
  src_oe[SDA_TBIT]  = u_framer.tbit_oe ; src_o[SDA_TBIT]  = u_framer.tbit_o
  src_oe[SDA_RDATA] = u_be.rdata_oe    ; src_o[SDA_RDATA] = u_be.rdata_o
  src_oe[SDA_DAA]   = u_daa.daa_oe     ; src_o[SDA_DAA]   = u_daa.daa_o
  src_oe[SDA_IBI]   = u_ibi.ibi_oe     ; src_o[SDA_IBI]   = u_ibi.ibi_o
  src_oe[SDA_DBG]   = 1'b0             ; src_o[SDA_DBG]   = 1'b0

BIT ENGINE  (u_be : i3c_bit_engine)
  in : u_fe.sda_sync, scl_rising, scl_falling, start_stb, rstart_stb
       u_pfsm.tx_load, tx_byte_out→tx_byte, tx_drive_en
  out: rx_byte, bit_cnt, byte_done, sda_bit → u_framer/u_pfsm/u_daa/u_ccc/u_err
       rdata_oe/rdata_o → mux[SDA_RDATA]

FRAMER  (u_framer : i3c_framer)
  in : u_pfsm.phase, u_pfsm.is_read, u_pfsm.more_read_data,
       u_be.rx_byte, u_be.sda_bit, u_be.byte_done,
       u_fe.scl_rising, scl_falling, rstart_stb
  out: ninth_slot, ack_slot, tbit_slot → u_pfsm,u_ccc
       parity_ok, parity_err → u_pfsm,u_err
       t_drive_val, read_abort → u_pfsm
       tbit_oe/tbit_o → mux[SDA_TBIT]

PROTOCOL FSM  (u_pfsm : i3c_protocol_fsm)
  in : front-end events; u_be.{rx_byte,byte_done,bit_cnt};
       u_framer.{ack_slot,tbit_slot,ninth_slot,parity_err,read_abort};
       u_daa.{da_valid,dyn_addr,daa_active};
       u_ccc.{ccc_ack,ccc_getstatus_seg,ccc_resp_valid,ccc_resp_byte,ccc_resp_last};
       u_err.{in_error,ack_inhibit}; u_av.{accept_en,core_en};
       u_rxfifo.full(→rx_can_accept=!full); u_txfifo.{empty→tx_empty,rd_data→tx_byte/tx_last}
  out: phase→u_framer/u_be; match_7e,match_da,is_broadcast,is_read→u_ccc/u_err;
       state_idle,state_ignore→u_av; post_rstart→u_ibi/u_err;
       ack_oe/ack_o→mux[SDA_ACK];
       tx_load,tx_byte_out,tx_drive_en,more_read_data→u_be/u_framer;
       tx_pop→u_txfifo.rd_en; rx_push→u_rxfifo.wr_en; rx_wdata→u_rxfifo.wr_data;
       priv_write_done,priv_read_req→u_av (INT)

DAA  (u_daa : i3c_daa)   — owns dyn_addr/da_valid
  in : front-end events; u_be.{bit_cnt,byte_done,rx_byte}; u_rf.{pid,bcr,dcr};
       u_ccc.{entdaa_start,entdaa_active,rstdaa,setdasa_load,setaasa_load,setnewda_load,load_addr};
       u_rstgen.whole_reset
  out: dyn_addr,da_valid → u_pfsm,u_ccc,u_ibi,u_err,u_av;
       daa_active→u_pfsm,u_err; daa_done→u_av(INT da_changed);
       daa_oe/daa_o→mux[SDA_DAA]; arb_lost(local); par_err→u_err; te4_event→u_err

CCC  (u_ccc : i3c_ccc)
  in : front-end events; u_be.{rx_byte,byte_done,bit_cnt}; u_framer.{ninth_slot,ack_slot};
       u_pfsm.{phase,match_7e,match_da,is_broadcast,is_read}; u_daa.da_valid;
       u_rf.{bcr,dcr,pid,mwl,mrl,max_ibi_payload,getstatus_word,getcaps}
  out: ccc_ack,ccc_getstatus_seg,ccc_resp_*→u_pfsm;
       entdaa_*,rstdaa,set*_load,load_addr→u_daa;
       ccc_set_mwl/mrl/maxibi/rstact(+vals),ccc_ibi_en_set/clr,getstatus_rd→u_rf;
       ccc_code_parity_err,ccc_illegal_format,ccc_supported→u_err;
       enthdr_seen→u_err(quiesce); ccc_event→u_av(INT)

IBI  (u_ibi : i3c_ibi)
  in : front-end events incl. bus_available; u_fe.sda_sync; u_pfsm.post_rstart;
       u_daa.{dyn_addr,da_valid}; u_rf.{bcr,ibi_en,max_ibi_payload};
       u_av.{ibi_en_app,ibi_request,mdb,mdb_is_prn};
       u_txfifo.rd_data (payload share) → pl_byte/pl_valid/pl_last
  out: ibi_oe/ibi_o→mux[SDA_IBI]; pl_pop→u_txfifo.rd_en(payload);
       ibi_busy,ibi_acked,ibi_nacked,ibi_deferred,ibi_arb_lost→u_av(IBI_STATUS);
       ibi_done→u_av(INT); ibi_addr(==dyn_addr)

ERROR RECOVERY  (u_err : i3c_error_recovery)
  in : front-end events; u_be.{rx_byte,byte_done}; u_pfsm.{phase,match_7e,match_da,is_read};
       u_daa.{da_valid,daa_active,par_err,te4_event}; u_framer.parity_err;
       u_ccc.{ccc_code_parity_err,ccc_illegal_format,ccc_supported};
       u_hdr.hdr_exit_detected
  out: in_error→u_pfsm,u_av; err_recoverable→u_hdr.exit_en;
       ack_inhibit→u_pfsm; drive_inhibit→(all drivers, S3); proto_err_set→u_rf;
       te_code→u_av

HDR-EXIT / TRP  (u_hdr : i3c_hdr_exit_detector)
  in : u_fe.{sda_sync,scl_sync,sda_falling,sda_rising,rstart_stb,stop_stb};
       exit_en = u_err.err_recoverable || u_ccc.enthdr_seen(is_hdr)
  out: hdr_exit_detected→u_err; trp_body_valid; trp_trigger→u_rf,u_rstgen

REGFILE  (u_rf : i3c_regfile)
  in : params(straps); u_ccc.{ccc_set_*,ccc_*_val,ccc_ibi_en_*,getstatus_rd};
       u_err.proto_err_set; u_av.{app_wr_*,app_rd_idx,pending_irq,activity_mode};
       u_hdr.trp_trigger; u_fe.start_stb(→start_clr); u_rstgen.{periph_reset,whole_reset}
  out: bcr,dcr,pid→u_daa,u_ccc; mwl,mrl,max_ibi_payload,getstatus_word,getcaps→u_ccc;
       ibi_en→u_ibi; reset_action,escalation_armed,last_reset_was_whole→u_av/u_rstgen;
       proto_err_seen→u_av; app_rd_data→u_av

FIFOs  (u_rxfifo, u_txfifo : i3c_fifo)
  u_rxfifo: DW=RX_FIFO_W; wr side(sys)=u_pfsm.rx_push/rx_wdata; rd side(avl)=u_av.rx_pop/rx_rd_data
  u_txfifo: DW=TX_FIFO_W; wr side(avl)=u_av.tx_push/tx_wr_data; rd side(sys)=u_pfsm.tx_pop & u_ibi.pl_pop
            (read port shared: private-read bytes to u_be via u_pfsm; IBI payload to u_ibi)

AVALON  (u_av : i3c_avalon_mm, clk=avl_clk)
  in : Avalon agent bus(top); u_rf.app_rd_data; u_rxfifo.{rd_data,empty,level,overflow};
       u_txfifo.{full,level}; u_ibi.{ibi_busy,ibi_acked,ibi_nacked,ibi_deferred,ibi_arb_lost};
       u_daa.{da_valid,dyn_addr}; u_pfsm.{state_idle,state_ignore,priv_write_done,priv_read_req};
       u_err.{in_error,te_code}; u_ccc.{ccc_event,enthdr_seen→in_hdr_quiesce}; u_rf.proto_err_seen;
       u_fe.{bus_busy,bus_free,bus_available,bus_idle}; u_daa.daa_done; u_ibi.ibi_done
  out: Avalon agent bus(top); app_wr_*/app_rd_idx→u_rf;
       rx_pop→u_rxfifo.rd_en; tx_push/tx_wr_data→u_txfifo;
       core_en,accept_en,ibi_en_app,soft_reset,static_addr_en,prn_send_en,flush_rx,flush_tx→core;
       ibi_request,mdb,mdb_is_prn→u_ibi; irq→top

RESET GEN  (u_rstgen : small always-on glue inside top — NOT a separate slice)
  in : u_hdr.trp_trigger, u_rf.{reset_action,escalation_armed}, u_av.soft_reset
  out: periph_reset, whole_reset → u_rf,u_daa and core reset fan-out
       (always-on retention for escalation_armed/reset_action lives in u_rf per §1.10/2.3)
```

---

## 5. Naming decisions every implementer must honor

- **N-1 (arbitration locality):** `i3c_bit_engine` has **no** `arb_lost` port. Arbitration-loss is computed inside `i3c_daa` (`arb_lost`) and `i3c_ibi` (`ibi_arb_lost`) from `sda_sync` at `scl_rising` vs the bit each is driving. Read data is push-pull and never arbitrated. (Supersedes the architecture §1.3 sketch.)
- **N-2 (edge-strobe names):** use the front-end's exact output names — `scl_rising`, `scl_falling`, `sda_rising`, `sda_falling` (NOT `scl_rising_stb`/`sda_fall`). START/Sr/STOP are `start_stb`/`rstart_stb`/`stop_stb`.
- **N-3 (SDA drive ports):** every driver names its pair `<src>_oe`/`<src>_o` matching the SDA-mux ownership table (§0). No module instantiates the mux; `i3c_target_top` does the wiring. Standalone proofs treat the resolved `sda_oe` as a free input and `assume` `$onehot0` of the drivers it models.
- **N-4 (read-data byte source mux):** the bit engine's `tx_byte` comes from `i3c_protocol_fsm`, which muxes between the **TX FIFO** (private read) and **`i3c_ccc.ccc_resp_byte`** (GET* CCC response, FIFO-bypassed per B-1/K7). GET* responses never enter the FIFO.
- **N-5 (TX FIFO read-port sharing):** `i3c_fifo` (TX) has a single read port shared by private-read (via `i3c_protocol_fsm.tx_pop`) and IBI payload (via `i3c_ibi.pl_pop`); these are mutually exclusive in time (a private read and an IBI never run concurrently). Top ORs the two `rd_en`/pop strobes.
- **N-6 (DA ownership):** only `i3c_daa` drives `dyn_addr`/`da_valid`; all others consume them read-only (incl. the Avalon DYN_ADDR/STATUS mirror).
- **N-7 (ACK ownership split):** the **address/CCC** ACK is driven by `i3c_protocol_fsm` on `SDA_ACK`; the **DAA accept** ACK is driven by `i3c_daa` on `SDA_DAA`. They never overlap (different bus phases).
- **N-8 (clk/rst naming):** ports are exactly `clk` and `rst_n` on every core block; the Avalon block's clock is also named `clk` at the module boundary (top connects it to `avl_clk`). Top's Avalon-domain inputs are `avl_clk`/`avl_rst_n`.
- **N-9 (FIFO field packing):** use `i3c_pkg::RXF_*`/`TXF_*` offsets; RX word width `RX_FIFO_W=11`, TX width `TX_FIFO_W=9` (added to the package for this contract).
- **N-10 (reset glue):** `i3c_target_top` contains the tiny `periph_reset`/`whole_reset` escalation glue; `escalation_armed`/`reset_action` retention lives in `i3c_regfile`'s always-on sub-domain. There is no separate `i3c_error_recovery` reset register.
