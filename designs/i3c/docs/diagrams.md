# Diagrams

Mermaid diagrams for the formally-verified **MIPI I3C Basic v1.2 SDR + In-Band-Interrupt
Target**. Every block, port name, FSM state, transition guard and bit/byte ordering
below is taken **verbatim from the final RTL** (`rtl/i3c_*.sv`, `rtl/altera/i3c_io_altera.sv`),
i.e. the device-agnostic core after the simulation-driven fixes (FINDING-SIM-1..7).
Where a diagram reflects one of those fixes the relevant tag is called out inline.

Contents:

- [1. Top-level block diagram](#1-top-level-block-diagram)
- [2. Clocking / CDC](#2-clocking--cdc)
- [3. FSM state diagrams](#3-fsm-state-diagrams)
  - [3.1 `i3c_protocol_fsm`](#31-i3c_protocol_fsm-state_e)
  - [3.2 `i3c_daa`](#32-i3c_daa-daa-round-fsm)
  - [3.3 `i3c_ibi`](#33-i3c_ibi-ibi-engine-fsm)
  - [3.4 `i3c_error_recovery`](#34-i3c_error_recovery-sticky-in_error--recovery-class)
- [4. Transaction sequence diagrams](#4-transaction-sequence-diagrams)
- [5. SDA drive-ownership & contention](#5-sda-drive-ownership--contention)

---

## 1. Top-level block diagram

The device-agnostic `i3c_target_top` netlist (the FROZEN connectivity of
`docs/interfaces.md` §4). It shows the pads feeding `i3c_io_altera` →
`i3c_bus_frontend`, the **single-owner `i3c_sda_mux`** fed by every SDA drive source
(`SDA_ACK` / `SDA_TBIT` / `SDA_RDATA` / `SDA_DAA` / `SDA_IBI`, plus the tied-off
`SDA_DBG`), the **registered F-3 self-drive gate** (`sda_oe_gate`, ADAPT-1) plus the
`OE_TAIL` release tail back into the front-end, and the byte datapath
`bus_frontend → bit_engine → framer → protocol_fsm → (ccc / daa / ibi) →
regfile + RX/TX FIFO → avalon_mm → application`. Edges are labelled with the
load-bearing signals.

```mermaid
flowchart TB
  SDA(["SDA pad (inout)"])
  SCL(["SCL pad (input only; Target never drives SCL)"])

  subgraph SYS["sys_clk oversample domain (clk, rst_n)"]
    direction TB
    IO["i3c_io_altera<br/>tri-state pad wrapper"]
    FE["i3c_bus_frontend<br/>2x sync + edges + START/Sr/STOP + bus timers"]
    BE["i3c_bit_engine<br/>RX deserialize / TX read-data serialize"]
    FR["i3c_framer<br/>9th-bit T/ACK + write parity + read T-bit"]
    PF["i3c_protocol_fsm<br/>addr match + ACK + S_* routing"]
    CCC["i3c_ccc<br/>CCC decode + GET responses"]
    DAA["i3c_daa<br/>ENTDAA, owns dyn_addr/da_valid"]
    IBI["i3c_ibi<br/>IBI arb + MDB + payload"]
    ERR["i3c_error_recovery<br/>TE0..TE5 sticky in_error"]
    HDR["i3c_hdr_exit_detector<br/>HDR-Exit + Target-Reset pattern"]
    RF["i3c_regfile<br/>PID/BCR/DCR, MWL/MRL, status, reset-action"]
    MUX["i3c_sda_mux<br/>single owner, lowest-index priority"]
    GATE["sda_oe_gate (1-cycle reg)<br/>ADAPT-1 loop-break"]
  end

  RXF["i3c_fifo RX<br/>wr=sys (rx_push), rd=avl"]
  TXF["i3c_fifo TX<br/>wr=avl, rd=sys (tx_pop OR ibi_pl_pop)"]

  subgraph AVL["Avalon clock domain (clk_avl, default = clk)"]
    direction TB
    AV["i3c_avalon_mm<br/>register + FIFO ports + irq"]
    APP(["Application (Avalon-MM master)"])
  end

  SCL -->|"scl_i"| IO
  SDA <-->|"sda_i / sda_oe,sda_o"| IO
  IO -->|"fe_sda_i, fe_scl_i"| FE

  PF -->|"ack_oe,ack_o (SDA_ACK)"| MUX
  FR -->|"tbit_oe,tbit_o (SDA_TBIT)"| MUX
  BE -->|"rdata_oe,rdata_o (SDA_RDATA)"| MUX
  DAA -->|"daa_oe,daa_o (SDA_DAA)"| MUX
  IBI -->|"ibi_oe,ibi_o (SDA_IBI)"| MUX
  ERR -.->|"drive_inhibit masks src_oe (S3)"| MUX
  MUX -->|"sda_oe,sda_o"| IO
  MUX --> GATE
  GATE -.->|"sda_oe_gate, + OE_TAIL tail (F-3)"| FE

  FE -->|"sda_sync, scl edges, START/Sr/STOP, bus_*"| BE
  BE -->|"rx_byte, byte_done, bit_cnt, sda_bit"| FR
  BE -->|"rx_byte, byte_done"| PF
  FR -->|"ack_slot, tbit_slot, parity_err"| PF
  PF -->|"phase, match_7e, match_da, is_read"| CCC
  CCC -->|"ccc_ack, ccc_resp_byte, getstatus_seg"| PF
  CCC -->|"entdaa_start, rstdaa, set*_load"| DAA
  DAA -->|"dyn_addr, da_valid, daa_active"| PF
  DAA -->|"rxda_enter = bit_resync"| BE
  DAA -->|"dyn_addr, da_valid"| IBI
  PF -->|"post_rstart"| IBI

  RF -->|"pid,bcr,dcr,mwl,mrl,getstatus,getcaps"| CCC
  RF -->|"pid,bcr,dcr"| DAA
  RF -->|"ibi_en"| IBI
  ERR -->|"in_error, ack_inhibit"| PF
  ERR -->|"exit_en (err_recoverable)"| HDR
  HDR -->|"hdr_exit_detected, trp_trigger"| ERR

  PF -->|"rx_wdata"| RXF
  TXF -->|"tx_byte, tx_last"| PF
  TXF -->|"pl_byte"| IBI
  RXF --> AV
  AV --> TXF
  AV <-->|"avs_* + irq"| APP
  IBI -->|"ibi_busy/acked/nacked/done"| AV
```

> Notes grounded in `rtl/i3c_target_top.sv`: the TX FIFO read port is **shared (N-5)**
> between the private-read pop (`pf_tx_pop`) and the IBI payload pop (`ibi_pl_pop`).
> The mux mask is `if (err_drive_inhibit) src_oe = '0;`. `SDA_DBG` is tied `0/0`.
> Under `FORMAL` the pad is replaced by an abstract wired-AND bus (see §5).

---

## 2. Clocking / CDC

The Target treats SDA/SCL as **asynchronous inputs** and runs all logic on a single
free-running `sys_clk` (`clk`). This flowchart traces the only async crossing — the
`SYNC_STAGES` (=2) FF synchronizers in `i3c_bus_frontend` — into 1-cycle **edge
strobes** that drive the entire `sys_clk` core (which never uses SCL as a clock), and
the optional Avalon-clock boundary selected by `clk_avl = AVL_ASYNC ? avl_clk : clk`
(default `AVL_ASYNC = 0`, so `avl_clk` is tied to `clk` and the FIFOs are wired
single-clock, `ASYNC = 0`).

```mermaid
flowchart LR
  subgraph ASYNC["Asynchronous I3C bus inputs"]
    SDAa(["SDA"])
    SCLa(["SCL"])
  end

  subgraph FEED["i3c_bus_frontend (only async crossing)"]
    direction TB
    SY["SYNC_STAGES=2 FF synchronizers<br/>sda_sync, scl_sync (set_false_path in SDC)"]
    ED["edge detect<br/>scl_rising/falling, sda_rising/falling"]
    BC["START / Sr / STOP detect<br/>gated by drive_recent = sda_oe_gate OR OE_TAIL tail (F-3)"]
    TMR["bus timers<br/>bus_free / available / idle"]
  end

  subgraph SYSD["single sys_clk core domain (clk)"]
    CORE["all I3C logic acts on 1-cycle edge strobes<br/>never uses SCL as a clock"]
  end

  CKMUX["clk_avl = AVL_ASYNC ? avl_clk : clk<br/>default 0 ties avl_clk to clk"]
  FIFO["i3c_fifo RX/TX (wired ASYNC=0 single-clock)<br/>clear = flush_rx / flush_tx"]

  subgraph AVLD["Avalon clock domain"]
    AVM["i3c_avalon_mm + irq"]
  end

  SDAa --> SY
  SCLa --> SY
  SY --> ED
  ED --> BC
  ED --> TMR
  ED -->|"1-cycle strobes"| CORE
  BC -->|"start/rstart/stop strobes"| CORE
  TMR -->|"bus_available/idle"| CORE
  CORE <-->|"data + push/pop"| FIFO
  FIFO <--> AVM
  CKMUX -.->|"selects FIFO rd/wr + Avalon clock"| FIFO
  CKMUX -.-> AVM
```

> CDC note (`i3c_bus_frontend.sv`): metastability on `sda_sync`/`scl_sync` is closed by
> SDC (`set_false_path`) plus the ≥3-sample rule, **not** by formal; upper layers are
> proven against the idealized edge strobes. The `i3c_fifo` block supports an
> async (Gray-pointer) mode (`ASYNC=1`), but the top instantiates both FIFOs with
> `ASYNC=0`.

---

## 3. FSM state diagrams

### 3.1 `i3c_protocol_fsm` (state_e)

Top SDR sequencer: arms address capture on (R)START, matches `7'h7E` / the dynamic
address, drives the open-drain address ACK, and routes the frame to write / read /
CCC / DAA. States and guards are the `state_e` enum and the `next_state` case in
`rtl/i3c_protocol_fsm.sv`.

```mermaid
stateDiagram-v2
  [*] --> S_IDLE
  S_IDLE : S_IDLE  wait for START (no drive)
  S_ADDR : S_ADDR  capture address byte (phase PH_ADDR)
  S_ACK : S_ACK  drive open-drain ACK (phase PH_ADDR)
  S_WRITE : S_WRITE  private/CCC write, push RX FIFO (phase PH_DATA)
  S_READ : S_READ  private read / GET response (phase PH_DATA)
  S_CCC : S_CCC  CCC code + data (phase PH_DATA)
  S_DAA : S_DAA  7E and R inside ENTDAA, i3c_daa drives ACK
  S_IGNORE : S_IGNORE  no match or NACK, release SDA

  S_IDLE --> S_ADDR : start_stb
  S_ADDR --> S_ACK : byte_done and want_ack
  S_ADDR --> S_DAA : byte_done and 7E and rnw and daa_active
  S_ADDR --> S_IGNORE : byte_done and no match
  S_ACK --> S_CCC : ninth_fell, route_q = S_CCC
  S_ACK --> S_READ : ninth_fell, route_q = S_READ
  S_ACK --> S_WRITE : ninth_fell, route_q = S_WRITE
  S_READ --> S_IGNORE : read_abort
  note right of S_READ
    read_done_q deasserts tx_drive_en after the final read
    T-bit (no more data, T=0) so the Controller can form a
    STOP/Sr (FINDING-SIM-5). The state stays S_READ until then.
    read_abort = Sr after a continue-T (RD-ABORT-01).
  end note
  note left of S_IDLE
    Global (every state): stop_stb returns to S_IDLE (F4);
    start_stb or rstart_stb re-arms to S_ADDR (F2/F3).
    post_rstart is sticky after Sr until the next START/STOP.
    is_read uses the LIVE rnw at S_ADDR and byte_done (FINDING-SIM-6).
  end note
```

### 3.2 `i3c_daa` (DAA round FSM)

ENTDAA participation (only when `!da_valid`, [C8]), 64-bit `{PID,BCR,DCR}` open-drain
arbitration, DA + odd-parity PAR capture, ACK/latch or NACK/re-arm. States are the
`S_*` localparams and the round-FSM case in `rtl/i3c_daa.sv`. The `rxda_enter` pulse
drives the bit engine's `bit_resync` when entering `S_RXDA` so the shared 9-bit
framing re-aligns after the non-multiple-of-9 payload (FINDING-SIM-3).

```mermaid
stateDiagram-v2
  [*] --> S_IDLE
  S_IDLE : S_IDLE  not in a round
  S_HDR : S_HDR  await Sr+7E/R header (participating)
  S_ACK7E : S_ACK7E  drive ACK Low for 7E/R
  S_PLD : S_PLD  drive 64-bit PID,BCR,DCR MSb-first, arbitrate
  S_RXDA : S_RXDA  receive assigned DA + PAR byte
  S_ACKDA : S_ACKDA  ACK+latch DA (parity ok) or NACK
  S_WAIT : S_WAIT  passive (lost / done / TE4), await STOP

  S_IDLE --> S_HDR : entdaa_start and not da_valid
  S_IDLE --> S_WAIT : entdaa_start and da_valid
  S_HDR --> S_ACK7E : byte_done and rx_byte == 0xFD
  S_HDR --> S_WAIT : byte_done and not 7E/R header (TE4)
  S_ACK7E --> S_PLD : scl_rising
  S_PLD --> S_PLD : scl_rising, payload_idx below 63
  S_PLD --> S_RXDA : scl_rising and payload_idx == 63
  S_PLD --> S_WAIT : arb_lost or rstart_stb
  S_RXDA --> S_ACKDA : byte_done
  S_ACKDA --> S_WAIT : scl_rising and parity_ok
  S_ACKDA --> S_HDR : scl_rising and not parity_ok
  note right of S_PLD
    Per bit: drive Low for a 0, release for a 1; a released 1
    sampled as 0 is arb_lost (released-1 sampled-0 -> S_WAIT).
    On entering S_RXDA, rxda_enter pulses bit_resync (FINDING-SIM-3).
  end note
  note left of S_IDLE
    Global: stop_stb returns to S_IDLE from any phase (clean
    abort, DAA-ABORT-01); whole_reset also returns to S_IDLE.
    daa_o is tied 0 (open-drain only, R-DAA-07).
  end note
```

### 3.3 `i3c_ibi` (IBI engine FSM)

Gated request (`capable = bcr[1] and ibi_en and ibi_en_app and da_valid`), open-drain
header arbitration of `{dyn_addr, RnW=1}`, ACK/NACK sampling, then push-pull MDB +
optional payload with End-of-Data T-bits. States are the `ST_*` localparams and main
case in `rtl/i3c_ibi.sv` (`bcr[2]` = MDB present).

```mermaid
stateDiagram-v2
  [*] --> ST_IDLE
  ST_IDLE : ST_IDLE  no request
  ST_WAIT : ST_WAIT  await Bus-Available plain START
  ST_ARB : ST_ARB  open-drain header arb, dyn_addr+RnW=1, MSb-first
  ST_ACK : ST_ACK  sample controller ACK/NACK (9th bit)
  ST_PRE : ST_PRE  ACK-to-MDB low-drive handoff (F-5)
  ST_DATA : ST_DATA  push-pull byte, MDB then payload
  ST_TBIT : ST_TBIT  push-pull End-of-Data T-bit

  ST_IDLE --> ST_WAIT : ibi_request and capable
  ST_WAIT --> ST_IDLE : not capable
  ST_WAIT --> ST_ARB : start_stb and not post_rstart and bus_available
  ST_ARB --> ST_WAIT : addr-bit loss, ibi_arb_lost
  ST_ARB --> ST_WAIT : RnW-bit loss, ibi_deferred
  ST_ARB --> ST_ACK : scl_rising and bit_idx == 7
  ST_ACK --> ST_PRE : scl_rising and ACK and bcr2
  ST_ACK --> ST_IDLE : scl_rising and ACK and not bcr2
  ST_ACK --> ST_IDLE : scl_rising and NACK, ibi_nacked
  ST_PRE --> ST_DATA : scl_falling
  ST_DATA --> ST_TBIT : scl_rising and bit_idx == 7
  ST_TBIT --> ST_DATA : scl_rising and more_data
  ST_TBIT --> ST_IDLE : scl_rising and not more_data, ibi_done
  note right of ST_IDLE
    Global: stop_stb or rstart_stb in ACK/PRE/DATA/TBIT aborts
    to ST_IDLE; in ARB it backs off to ST_WAIT. Total payload
    bounded by max_ibi_payload (I9). ibi_addr == dyn_addr (I3).
  end note
```

### 3.4 `i3c_error_recovery` (sticky in_error + recovery class)

Not a free-running FSM but a sticky `in_error` flag with a latched recovery **class**
(`recov_class`) that selects which bus event clears it (`clear_event` in
`rtl/i3c_error_recovery.sv`). While in error, both `ack_inhibit` and `drive_inhibit`
are asserted (E3/S3) and every `te*_event` pulses `proto_err_set`.

```mermaid
stateDiagram-v2
  [*] --> NORMAL
  NORMAL : NORMAL  in_error = 0
  ERR_HDR : IN_ERROR class RC_HDR (TE0 / TE1)
  ERR_DISCARD : IN_ERROR class RC_DISCARD (TE2 / TE5)
  ERR_NACKDAA : IN_ERROR class RC_NACKDAA (TE3 / TE4)

  NORMAL --> ERR_HDR : te0_event or te1_event
  NORMAL --> ERR_DISCARD : te2_event or te5_event
  NORMAL --> ERR_NACKDAA : te3_event or te4_event
  ERR_HDR --> NORMAL : stop_stb or hdr_exit_detected
  ERR_DISCARD --> NORMAL : stop_stb or rstart_stb or hdr_exit_detected
  ERR_NACKDAA --> NORMAL : stop_stb or rstart_stb or hdr_exit_detected
  note right of NORMAL
    in_error is sticky; priority TE0, TE1, TE2, TE3, TE4, TE5
    latches the class/code. Only RC_HDR drives err_recoverable
    (enables the HDR-Exit detector). Clear has priority over a
    new event, so recovery is never starved (no hang).
  end note
```

> Companion `i3c_hdr_exit_detector` is a shared SDA-transition counter (not a
> multi-state FSM): 4 SDA falls with SCL Low → `hdr_exit_detected`; 14 transitions
> ending SDA-High → `trp_body_valid`; then `body → Sr → STOP` → `trp_trigger`
> (drives the Target-Reset escalation glue in `i3c_target_top`).

---

## 4. Transaction sequence diagrams

Participants are **Controller**, the **SDA bus** (abstract wired-AND with pull-up),
the **Target core**, and the **Application** (Avalon-MM). Bit/byte ordering follows
the RTL: SDA sampled on SCL rising, MSb-first; the 9th bit is an ACK in `PH_ADDR` and
a T-bit in `PH_DATA`.

### 4.1 Dynamic Address Assignment via ENTDAA

Includes the 64-bit open-drain payload, the `rxda_enter`/`bit_resync` re-frame, and
the assigned-DA + odd-parity PAR capture.

```mermaid
sequenceDiagram
  participant C as Controller
  participant B as SDA bus
  participant T as Target core
  participant A as Application Avalon
  Note over C,T: Target holds no DA da_valid = 0 so it participates
  C->>B: START + 7E/W
  T->>B: ACK 7E open-drain Low, i3c_protocol_fsm SDA_ACK
  C->>B: ENTDAA code 0x07 + T-bit
  Note over T: i3c_ccc entdaa_start, i3c_daa S_IDLE to S_HDR
  C->>B: Sr + 7E/R
  T->>B: ACK 7E/R S_ACK7E, daa_oe Low
  loop 64 payload bits MSb-first, open-drain S_PLD
    T->>B: drive Low for 0, release for 1, per-bit arbitration
    Note over T,B: released-1 sampled-0 means arb_lost to S_WAIT
  end
  Note over T,B: payload_idx 63 to S_RXDA pulses rxda_enter to bit_resync FINDING-SIM-3
  C->>B: assigns 7-bit DA + odd-parity PAR S_RXDA
  alt PAR matches odd parity of DA
    T->>B: ACK and latch dyn_addr, da_valid=1 S_ACKDA to S_WAIT
    T->>A: daa_done pulse INT da_changed
  else PAR bad TE3
    T->>B: NACK, keep PID, re-arm S_ACKDA to S_HDR
  end
  C->>B: STOP
  Note over T: S_WAIT to S_IDLE clean exit, DAA-ABORT-01
```

### 4.2 SDR private write (Controller to Target)

```mermaid
sequenceDiagram
  participant C as Controller
  participant B as SDA bus
  participant T as Target core
  participant A as Application Avalon
  Note over A: accept_en = 1 and RX FIFO has space rx_can_accept
  C->>B: START + DA/W
  Note over T: match_da, S_ADDR to S_ACK want_ack
  T->>B: ACK open-drain Low, SDA_ACK
  loop each data byte
    C->>B: 8 data bits MSb-first + odd-parity T-bit
    Note over T: Target never drives a write byte WR-NODRIVE-01
    alt parity ok
      T->>A: push byte to RX FIFO rx_push in S_WRITE
    else parity error TE2
      Note over T: byte not committed, i3c_error_recovery in_error
    end
  end
  C->>B: STOP or Sr
  T->>A: priv_write_done INT
```

### 4.3 SDR private read with T-bit (Target to Controller)

Includes the `tx_first` MSb hold (FINDING-SIM-4) and the `read_done_q` termination
(FINDING-SIM-5).

```mermaid
sequenceDiagram
  participant C as Controller
  participant B as SDA bus
  participant T as Target core
  participant A as Application Avalon
  Note over A: TX FIFO preloaded, accept_en = 1 and TX not empty
  C->>B: START + DA/R
  T->>B: ACK open-drain Low, SDA_ACK
  Note over T: S_ACK to S_READ, priv_read_req INT, tx_load to bit engine
  loop each read byte bounded by MRL
    Note over T: tx_first holds the loaded MSb across its first scl_falling FINDING-SIM-4
    T->>B: 8 data bits push-pull MSb-first i3c_bit_engine SDA_RDATA
    alt more data follows
      T->>B: read T-bit = 1 driven on scl_falling, released on scl_rising SDA_TBIT
    else last byte
      T->>B: read T-bit = 0 driven on scl_falling, then read_done_q releases SDA
      Note over T: tx_drive_en deasserts so Controller can form STOP/Sr FINDING-SIM-5
    end
  end
  opt Controller abort after a continue-T
    C->>B: Sr at scl_falling, read_abort, S_READ to S_IGNORE RD-ABORT-01
  end
  C->>B: STOP
```

### 4.4 Direct CCC: GETSTATUS (Format-1)

7E+W, code, Sr, DA+R with `is_read` driven live (FINDING-SIM-6), then the FIFO-bypassed
response. The B-1 bypass means the directed-GET ACK is **not** gated by
`accept_en`/FIFO/pending-error, so the mandatory status read never deadlocks.

```mermaid
sequenceDiagram
  participant C as Controller
  participant B as SDA bus
  participant T as Target core
  participant A as Application Avalon
  C->>B: START + 7E/W
  T->>B: ACK 7E open-drain Low
  C->>B: GETSTATUS code 0x90 + T-bit
  Note over T: i3c_ccc latches code, asserts ccc_getstatus_seg
  C->>B: Sr + DA/R
  Note over T: is_read uses the LIVE rnw at S_ADDR and byte_done FINDING-SIM-6
  T->>B: ACK B-1 bypass, not gated by accept_en/FIFO
  Note over T: S_READ, read_from_ccc, source = ccc_resp_byte FIFO-bypassed
  T->>B: getstatus_word 15..8 push-pull + T-bit = 1 more
  T->>B: getstatus_word 7..0 push-pull + T-bit = 0 last
  C->>B: STOP or Sr
  Note over T,A: getstatus_rd pulse, regfile clears sticky proto_err read-to-clear
  Note over T: FINDING-SIM-7 FIXED multi-byte GET reloads each byte at ninth_fell; GETPID returns all six PID bytes
```

### 4.5 In-Band Interrupt (IBI) with arbitration + MDB

```mermaid
sequenceDiagram
  participant C as Controller
  participant B as SDA bus
  participant T as Target core
  participant A as Application Avalon
  A->>T: ibi_request + MDB IBI_CTRL
  Note over T: capable = bcr1 and ibi_en and ibi_en_app and da_valid, then ST_IDLE to ST_WAIT busy
  C->>B: Bus Available, then plain START not after Sr
  Note over T: ST_WAIT to ST_ARB
  T->>B: header dyn_addr + RnW=1, MSb-first, open-drain arbitration
  alt lost on an address bit
    Note over T: ibi_arb_lost, release, back off to ST_WAIT
  else lost on the RnW bit Private Write won
    Note over T: ibi_deferred, Controller wins, ST_WAIT
  else won full header
    C->>B: ACK or NACK on the 9th bit ST_ACK
    alt Controller ACK and bcr2 MDB present
      T->>B: drive Low ST_PRE, then push-pull MDB ST_DATA + T-bit ST_TBIT
      loop optional extra payload up to max_ibi_payload
        T->>B: payload byte push-pull + T-bit T=1 more, T=0 last
      end
      T->>A: ibi_done INT
    else Controller ACK and not bcr2
      Note over T: frame ends after ACK, no payload ST_IDLE
    else Controller NACK
      Note over T: ibi_nacked, release, ST_IDLE INT ibi_nacked
    end
  end
```

---

## 5. SDA drive-ownership & contention

Every internal SDA driver exposes an `(oe, o)` request pair; all feed the single
`i3c_sda_mux`, masked by `drive_inhibit` (S3). The resolved `(sda_oe, sda_o)` is the
only signal reaching the pad; a **registered** copy (`sda_oe_gate`, ADAPT-1) extended
by `OE_TAIL` (=4) cycles feeds the front-end's F-3 gate so the Target never mistakes
its own drive (or its pull-up release transient, FINDING-SIM-1) for a bus condition.
On the bus the line resolves wired-AND against the pull-up and a free Controller
driver. The integration safety properties in `rtl/i3c_target_top.sv` are annotated:
**F-1** (contention monitor), **F-2** (`onehot0(f_src_req)`, single owner) and **F-3**
(self-drive gate, also `a_f3_top`).

```mermaid
flowchart TB
  subgraph SRC["SDA drive-request sources (oe, o) - i3c_target_top src_oe/src_o"]
    direction TB
    A0["SDA_ACK=0 : i3c_protocol_fsm ack_oe/ack_o<br/>open-drain Low or release (ACK)"]
    A1["SDA_TBIT=1 : i3c_framer tbit_oe/tbit_o<br/>push-pull read T-bit"]
    A2["SDA_RDATA=2 : i3c_bit_engine rdata_oe/rdata_o<br/>push-pull read data"]
    A3["SDA_DAA=3 : i3c_daa daa_oe/daa_o<br/>open-drain payload + ACK (daa_o tied 0)"]
    A4["SDA_IBI=4 : i3c_ibi ibi_oe/ibi_o<br/>open-drain arb + push-pull MDB/payload"]
    A5["SDA_DBG=5 : tied 0/0 (not in f_src_req)"]
  end

  INH["err_drive_inhibit (S3)<br/>forces src_oe = 0 while in_error"]
  MUX["i3c_sda_mux<br/>lowest-index priority resolve"]
  RES["resolved sda_oe, sda_o"]
  GATE["sda_oe_gate (1-cycle reg, ADAPT-1)<br/>+ OE_TAIL=4 release tail (FINDING-SIM-1)"]
  PAD["pad / abstract wired-AND"]
  WAND["wired-AND bus (open-drain)<br/>Low if any driver pulls Low, else pull-up High"]
  PU["pull-up resistor"]
  CTL["free Controller driver (f_ctl_oe, f_ctl_o)"]
  FE["i3c_bus_frontend (samples sda_i)"]

  A0 --> MUX
  A1 --> MUX
  A2 --> MUX
  A3 --> MUX
  A4 --> MUX
  A5 -.-> MUX
  INH -.->|"mask"| MUX
  MUX --> RES
  RES --> PAD
  RES --> GATE
  PAD --> WAND
  PU --> WAND
  CTL --> WAND
  WAND -->|"sda_i then sda_sync"| FE
  GATE -.->|"F-3 gate: suppress self START/Sr/STOP for OE_TAIL cycles"| FE

  F1["F-1 contention monitor (top)<br/>assert not (sda_oe and f_ctl_oe and opposite values)"]
  F2["F-2 single owner (top)<br/>assert onehot0(f_src_req)"]
  F3["F-3 self-drive gate (front-end + top a_f3_top)"]
  F1 -.->|"audits"| WAND
  F2 -.->|"audits"| MUX
  F3 -.->|"audits"| GATE
```

> Grounded in the `FORMAL` block of `rtl/i3c_target_top.sv`:
> `f_src_req = {ibi_oe, daa_oe, be_rdata_oe, fr_tbit_oe, pf_ack_oe}` (5 bits; `SDA_DBG`
> excluded). `a_contention = !(sda_oe && f_ctl_oe && (sda_o != f_ctl_o))` (F-1),
> `a_single_owner = $onehot0(f_src_req)` (F-2), `a_f3_top = !sda_oe ||
> !(start_stb || rstart_stb || stop_stb)`. Controller-environment assumes CA1/CA2/CA3
> keep a legal Controller released during the Target's push-pull read and active IBI,
> and never hard-High while the Target pulls open-drain Low.
