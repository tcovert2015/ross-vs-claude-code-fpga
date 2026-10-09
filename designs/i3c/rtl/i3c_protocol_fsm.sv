// ============================================================================
// i3c_protocol_fsm.sv  -  Top SDR sequencer (architecture §1.6, Slice 3)
//
// Responsibilities (docs/architecture.md §1.6, docs/interfaces.md §2.6):
//   * On START / Sr re-arm address capture (R-ADDR-04 / R-FMT-04); on STOP/Sr
//     cancel the in-progress capture (R-RS-01).
//   * Match 7'h7E (I3C Broadcast, ADR-7E-01) and the assigned Dynamic Address
//     (ADR-DA-01; comparator gated by da_valid so a DA never matches before it is
//     assigned). The address is the first byte after ANY (R)START.
//   * Route the matched frame:
//       7E / W            -> CCC frame              (ADR-CCC-ENTRY-01)
//       7E / R (in DAA)   -> i3c_daa (DAA owns ACK on SDA_DAA, N-7)
//       DA / W            -> private write          (push to RX FIFO)
//       DA / R            -> private read           (drive read data via bit engine)
//       DA + directed CCC -> CCC handler            (SET data / GET response)
//   * OWN the address-slot ACK driver (SDA_ACK). ACK = open-drain drive-Low only
//     (ACK-OD-01 / K5); passive NACK = release SDA.
//   * Gate the private R/W ACK by accept_en (+ FIFO space / TX data) and the error
//     inhibits; BUT a GETSTATUS / identity-GET segment BYPASSES accept_en / FIFO /
//     pending-error (critique B-1) so the mandatory status read never deadlocks.
//   * No match / NACK -> IGNORE: release SDA, await the next Sr/STOP (ADR-IGN-01).
//
// Proven STANDALONE (Slice 3). Neighbour signals (framer slots, bit-engine byte
// events, bus-condition strobes, DAA/CCC/error flags) are driven as free inputs
// constrained by the assume-ledger documented in the formal section below.
// ============================================================================
`ifndef I3C_PROTOCOL_FSM_SV
`define I3C_PROTOCOL_FSM_SV
`include "i3c_pkg.sv"

module i3c_protocol_fsm (
  input  logic        clk,
  input  logic        rst_n,
  // ---- bus conditions (front-end) ----
  input  logic        start_stb,
  input  logic        rstart_stb,
  input  logic        stop_stb,
  input  logic        scl_rising,
  input  logic        scl_falling,
  input  logic        bus_available,
  // ---- bit engine ----
  input  logic [7:0]  rx_byte,
  input  logic        byte_done,
  input  logic [3:0]  bit_cnt,
  // ---- framer slot flags / errors ----
  input  logic        ack_slot,
  input  logic        tbit_slot,
  input  logic        ninth_slot,
  input  logic        parity_err,
  input  logic        read_abort,
  // ---- dynamic address (i3c_daa, read-only; N-6) ----
  input  logic        da_valid,
  input  logic [6:0]  dyn_addr,
  input  logic        daa_active,
  // ---- application / control gates ----
  input  logic        accept_en,      // CTRL[1]
  input  logic        core_en,        // CTRL[0]
  input  logic        rx_can_accept,  // RX FIFO not full
  // ---- CCC layer ----
  input  logic        ccc_ack,            // CCC wants ACK at directed address
  input  logic        ccc_getstatus_seg,  // segment is GETSTATUS/identity-GET (B-1)
  input  logic        ccc_resp_valid,
  input  logic [7:0]  ccc_resp_byte,
  input  logic        ccc_resp_last,
  // ---- TX FIFO (private read source) ----
  input  logic        tx_empty,
  input  logic [7:0]  tx_byte,
  input  logic        tx_last,
  // ---- error-recovery inhibits ----
  input  logic        in_error,
  input  logic        ack_inhibit,
  input  logic        in_hdr_quiesce,
  // ---- outputs ----
  output logic [1:0]  phase,
  output logic        state_idle,
  output logic        state_ignore,
  output logic        match_7e,
  output logic        match_da,
  output logic        is_broadcast,
  output logic        is_read,
  output logic        addr_capture_armed,
  output logic        post_rstart,
  output logic        ack_oe,
  output logic        ack_o,
  output logic        tx_load,
  output logic [7:0]  tx_byte_out,
  output logic        tx_drive_en,
  output logic        more_read_data,
  output logic        tx_pop,
  output logic        rx_push,
  output logic [10:0] rx_wdata,
  output logic        to_ccc,
  output logic        priv_write_done,
  output logic        priv_read_req
);

  // --------------------------------------------------------------------------
  // FSM states
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,  // bus quiescent, waiting for START
    S_ADDR   = 3'd1,  // capturing the address byte (phase = PH_ADDR)
    S_ACK    = 3'd2,  // address ACK 9th-bit slot (phase = PH_ADDR), driving ACK
    S_WRITE  = 3'd3,  // private write data (phase = PH_DATA)
    S_READ   = 3'd4,  // private read / directed-GET data (phase = PH_DATA)
    S_CCC    = 3'd5,  // CCC code/data following a 7E/W or directed SET
    S_DAA    = 3'd6,  // 7E/R inside ENTDAA -> i3c_daa drives
    S_IGNORE = 3'd7   // no-match / NACK -> release, wait for Sr/STOP
  } state_e;

  state_e state, next_state, route_q;

  // Latched address attributes (valid from S_ACK through the data phase).
  logic m7e_q, mda_q, rnw_q, bcast_q, read_from_ccc_q;

  // sticky frame context
  logic frame_is_ccc_q;   // a CCC frame is open (7E/W ... [Sr ... DA])
  logic ninth_q;          // ninth_slot delayed (for falling-edge detect)

  // --------------------------------------------------------------------------
  // Combinational address decode (live on rx_byte during the address slot).
  //   I3C/I2C address byte: rx_byte[7:1] = 7-bit address, rx_byte[0] = RnW.
  // --------------------------------------------------------------------------
  wire [6:0] addr7 = rx_byte[7:1];
  wire       rnw   = rx_byte[0];

  assign match_7e = (addr7 == i3c_pkg::I3C_BROADCAST_ADDR);
  assign match_da = da_valid && (addr7 == dyn_addr);   // A2: gated by da_valid

  // Master enable + error inhibits: no ACK / no drive unless cleanly enabled.
  wire enabled = core_en && !in_error && !ack_inhibit && !in_hdr_quiesce;

  // Is the matched DA part of a CCC segment? (directed CCC, incl. GETSTATUS B-1)
  wire ccc_seg = frame_is_ccc_q || ccc_getstatus_seg;

  // Private-transfer application gate (R-ACK-02). Read needs TX data; write needs
  // RX space. CCC segments DO NOT use this gate (B-1 bypass / CCC owns readiness).
  wire da_priv_gate = accept_en && (rnw ? !tx_empty : rx_can_accept);

  // ACK decision evaluated at the address byte boundary.
  //   7E/W  -> always ACK (ACK-7E-01)            7E/R -> never our ACK (DAA owns it)
  //   DA    -> CCC seg : ACK iff ccc_ack (getstatus already bypasses gating)
  //            private : ACK iff da_priv_gate
  wire want_ack = enabled && (
                    (match_7e && !rnw) ||
                    (match_da && (ccc_seg ? ccc_ack : da_priv_gate))
                  );

  // ninth_slot falling edge ends the ACK slot -> advance to the data phase.
  wire ninth_fell = ninth_q && !ninth_slot;

  // --------------------------------------------------------------------------
  // Next-state logic
  // --------------------------------------------------------------------------
  always_comb begin
    next_state = state;
    if (stop_stb)                      next_state = S_IDLE;          // F4
    else if (start_stb || rstart_stb)  next_state = S_ADDR;          // F2/F3 re-arm
    else begin
      unique case (state)
        S_IDLE: ; // wait
        S_ADDR: begin
          if (byte_done) begin
            if (want_ack)                                 next_state = S_ACK;
            else if (match_7e && rnw && daa_active && enabled)
                                                          next_state = S_DAA;
            else                                          next_state = S_IGNORE;
          end
        end
        S_ACK: begin
          if (ninth_fell) next_state = route_q;
        end
        S_WRITE: ;                              // commit data; stay until Sr/STOP
        S_READ:  if (read_abort) next_state = S_IGNORE;  // controller aborted read
        S_CCC:   ;
        S_DAA:   ;
        S_IGNORE:;
        default: next_state = S_IDLE;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // State + latched attributes
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= S_IDLE;
      route_q         <= S_IGNORE;
      m7e_q           <= 1'b0;
      mda_q           <= 1'b0;
      rnw_q           <= 1'b0;
      bcast_q         <= 1'b0;
      read_from_ccc_q <= 1'b0;
    end else begin
      state <= next_state;

      // Latch address attributes on every captured address byte (ACK or NACK).
      if (state == S_ADDR && byte_done) begin
        m7e_q   <= match_7e;
        mda_q   <= match_da;
        rnw_q   <= rnw;
        bcast_q <= match_7e;
      end

      // Latch the routed data state only for an ACKed frame (enters S_ACK).
      if (state == S_ADDR && byte_done && want_ack) begin
        route_q <= state_e'((match_7e && !rnw)            ? S_CCC  : // broadcast CCC
                            (match_da && ccc_seg && !rnw) ? S_CCC  : // directed SET
                            (match_da && rnw)             ? S_READ : // private read / GET
                                                            S_WRITE);// private write (explicit cast: strict iverilog)
        read_from_ccc_q <= (match_da && ccc_seg && rnw);      // GET response source
      end
    end
  end

  // --------------------------------------------------------------------------
  // post_rstart : a Sr occurred this frame (S4 / IBI gate). Cleared on START/STOP.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n)            post_rstart <= 1'b0;
    else if (start_stb)    post_rstart <= 1'b0;
    else if (stop_stb)     post_rstart <= 1'b0;
    else if (rstart_stb)   post_rstart <= 1'b1;
  end

  // --------------------------------------------------------------------------
  // frame_is_ccc : sticky CCC-frame context. Set when a 7E/W broadcast header is
  // ACKed; persists across Sr (directed CCC re-addressing); cleared on START/STOP.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n)                          frame_is_ccc_q <= 1'b0;
    else if (start_stb || stop_stb)      frame_is_ccc_q <= 1'b0;
    else if (state == S_ADDR && byte_done && match_7e && !rnw && enabled)
                                         frame_is_ccc_q <= 1'b1;
  end

  // ninth_slot delayed
  always_ff @(posedge clk) begin
    if (!rst_n) ninth_q <= 1'b0;
    else        ninth_q <= ninth_slot;
  end

  // --------------------------------------------------------------------------
  // Phase output (drives framer/bit-engine 9th-bit role).
  // --------------------------------------------------------------------------
  always_comb begin
    unique case (state)
      S_ADDR, S_ACK:          phase = i3c_pkg::PH_ADDR;
      S_WRITE, S_READ, S_CCC: phase = i3c_pkg::PH_DATA;
      default:                phase = i3c_pkg::PH_IDLE;  // IDLE / DAA / IGNORE
    endcase
  end

  // --------------------------------------------------------------------------
  // Address-slot ACK driver (SDA_ACK). Open-drain: drive Low or release only.
  // Driven only in S_ACK (which is entered only on a matched+gated ACK decision),
  // during the framer ACK slot, while cleanly enabled.
  // --------------------------------------------------------------------------
  assign ack_oe = (state == S_ACK) && ack_slot && enabled;
  assign ack_o  = 1'b0;                       // ACK-OD-01 : never drive High (K5)

  // --------------------------------------------------------------------------
  // Decoded status / routing outputs
  // --------------------------------------------------------------------------
  assign state_idle         = (state == S_IDLE);
  assign state_ignore       = (state == S_IGNORE);
  assign addr_capture_armed = (state == S_ADDR);     // F2
  // Use the LIVE RnW at the address byte_done (when the CCC ACK decision is made);
  // rnw_q only updates the cycle after, so it would be stale exactly when the CCC
  // handler evaluates dir_ok for a directed GET (FINDING-SIM-6). Latched value is
  // identical during the data phase, so downstream consumers are unaffected.
  assign is_read            = (state == S_ADDR && byte_done) ? rnw : rnw_q;
  assign is_broadcast       = bcast_q;
  assign to_ccc             = frame_is_ccc_q;        // F5

  // --------------------------------------------------------------------------
  // Private-write / CCC-write commit to RX FIFO (parity-clean bytes only).
  // --------------------------------------------------------------------------
  assign rx_push = ((state == S_WRITE) || (state == S_CCC)) && byte_done && !parity_err;
  always_comb begin
    rx_wdata                       = '0;
    rx_wdata[7:0]                  = rx_byte;
    rx_wdata[i3c_pkg::RXF_VALID]   = 1'b1;
    rx_wdata[i3c_pkg::RXF_LAST]    = 1'b0;      // STOP/Sr boundary handled downstream
    rx_wdata[i3c_pkg::RXF_IS_CCC]  = (state == S_CCC);
  end

  // --------------------------------------------------------------------------
  // Private-read / directed-GET read datapath (to bit engine / framer).
  //   tx_byte_out muxes TX FIFO (private read) vs ccc_resp_byte (GET, B-1/N-4).
  // --------------------------------------------------------------------------
  // FINDING-SIM-5: after the final read T-bit (no more data, T=0), the Target must
  // RELEASE SDA so the Controller can form a STOP/Sr; otherwise it would keep driving
  // S_READ forever and the read could only end via a Repeated-START abort.
  logic read_done_q;
  always_ff @(posedge clk) begin
    if (!rst_n)                              read_done_q <= 1'b0;
    else if (state != S_READ)                read_done_q <= 1'b0;   // reset off the read
    else if (ninth_fell && !more_read_data)  read_done_q <= 1'b1;   // last T-bit completed
  end

  assign tx_byte_out    = read_from_ccc_q ? ccc_resp_byte : tx_byte;
  // Drive read DATA bits only; RELEASE during the 9th (T-bit) slot so the framer owns
  // the read T-bit (i3c_framer.tbit_oe). Without the !ninth_slot gate the bit engine's
  // push-pull fill and the framer's T-bit would both drive SDA in the 9th slot -- a
  // single-owner violation, and on the final byte the fill '1' fights the framer's T=0.
  assign tx_drive_en    = (state == S_READ) && !read_done_q && !ninth_slot;
  assign more_read_data = (state == S_READ) &&
                          (read_from_ccc_q ? (ccc_resp_valid && !ccc_resp_last)
                                           : (!tx_empty && !tx_last));
  // Reload the next read byte at ninth_fell (after the current byte's T-bit slot),
  // the SAME bit-phase as the first byte's load at S_ACK->S_READ. Loading at byte_done
  // (the 8th-bit rising, mid-byte) was one slot too early and dropped the reloaded
  // byte's MSb -> 2nd+ bytes shifted (FINDING-SIM-7).
  assign tx_load        = ((state == S_ACK) && (next_state == S_READ)) ||
                          ((state == S_READ) && ninth_fell && more_read_data);
  assign tx_pop         = (state == S_READ) && !read_from_ccc_q && byte_done && !tx_empty;

  // --------------------------------------------------------------------------
  // Application interrupt pulses
  // --------------------------------------------------------------------------
  assign priv_read_req   = (state == S_ACK) && (next_state == S_READ) && !read_from_ccc_q;
  assign priv_write_done = (state == S_WRITE) && (stop_stb || rstart_stb);

  // ==========================================================================
  // Formal properties (Slice 3) - open-source yosys SVA subset:
  // immediate asserts in clocked blocks; boolean implication (!a||b); $past etc.
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (assume-ledger; discharge at integration) -----
  always_ff @(posedge clk) if (rst_n) begin
    // AL-1 bus-condition strobes are mutually exclusive (front-end guarantee).
    au_evt_excl1 : assume (!(start_stb  && rstart_stb));
    au_evt_excl2 : assume (!(start_stb  && stop_stb));
    au_evt_excl3 : assume (!(rstart_stb && stop_stb));
    // AL-2 a byte boundary and a bus condition never coincide (idealized edge
    //      model: byte_done is at scl_rising; START/Sr/STOP are SDA edges).
    au_byte_noevt: assume (!(byte_done && (start_stb || rstart_stb || stop_stb)));
    // AL-3 framer slot flags are exactly the 9th-bit role selected by our phase.
    au_ack_slot  : assume (ack_slot  == (ninth_slot && (phase == i3c_pkg::PH_ADDR)));
    au_tbit_slot : assume (tbit_slot == (ninth_slot && (phase == i3c_pkg::PH_DATA)));
    // AL-4 the 8th-bit-done pulse and the 9th-bit slot do not coincide.
    au_ninth     : assume (!(byte_done && ninth_slot));
    // AL-5 an assigned DA is never a restricted address (R-TE0-04), so 7E and DA
    //      never match the same byte -> deterministic routing.
    au_da_legal  : assume (!da_valid || !i3c_pkg::is_restricted_addr(dyn_addr));
  end

  // =========================== §4.C Address matching =========================
  always_ff @(posedge clk) if (rst_n) begin
    // A1: a captured 7E address always matches (and only 7E does).
    a_a1_match7e  : assert (match_7e == (addr7 == i3c_pkg::I3C_BROADCAST_ADDR));
    // A2: a DA never matches before assignment.
    a_a2_da_valid : assert (!match_da || da_valid);
    // A2b: match_da tracks the current dynamic address.
    a_a2b_da_track: assert (!match_da || (addr7 == dyn_addr));
    // 7E and DA are mutually exclusive (legal-DA assumption).
    a_excl_match  : assert (!(match_7e && match_da));
  end

  // A3: no-match address -> IGNORE on the next cycle, and no ACK.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    a_a3_ignore : assert ( !($past(state == S_ADDR) && $past(byte_done) &&
                             !$past(match_7e) && !$past(match_da))
                           || (state == S_IGNORE) );
  end

  // =========================== §4.D ACK / NACK ===============================
  always_ff @(posedge clk) if (rst_n) begin
    // K5 : ACK bit is open-drain - never drive High.
    a_k5_od       : assert (!ack_oe || !ack_o);
    // K8a: the ACK driver is asserted only in the address ACK state.
    a_k8_state    : assert (!ack_oe || (state == S_ACK));
    // K8b: S_ACK is reachable only via a 7E/W or a DA match (no false ACK).
    a_k8_match    : assert (!(state == S_ACK) || (m7e_q && !rnw_q) || mda_q);
    // S3 : in IGNORE / error / quiesce the ACK driver is released.
    a_s3_quiet    : assert (!(state_ignore || in_error || in_hdr_quiesce) || !ack_oe);

    // K1 : ACK the 7E broadcast header (open-drain Low) when in the ACK slot.
    a_k1_ack7e    : assert ( !((state == S_ACK) && ack_slot && m7e_q && !rnw_q && enabled)
                             || (ack_oe && !ack_o) );
    // K3-decision : matched private DA + accept_en (+FIFO/TX, enabled) -> ACK.
    a_k3_ack_da   : assert ( !(state == S_ADDR && byte_done && match_da &&
                               !frame_is_ccc_q && !ccc_getstatus_seg &&
                               accept_en && enabled &&
                               (rnw ? !tx_empty : rx_can_accept))
                             || want_ack );
    // K2-decision : matched private DA without accept_en -> passive NACK.
    a_k2_nack     : assert ( !(state == S_ADDR && byte_done && match_da &&
                               !frame_is_ccc_q && !ccc_getstatus_seg && !accept_en)
                             || !want_ack );
  end

  // K4 : passive-NACKed private DA -> IGNORE next cycle and SDA released.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    a_k4_nack_ign : assert ( !($past(state == S_ADDR) && $past(byte_done) &&
                               $past(match_da) && !$past(frame_is_ccc_q) &&
                               !$past(ccc_getstatus_seg) && !$past(accept_en))
                             || (state_ignore && !ack_oe) );
  end

  // ===================== critique B-1 : GETSTATUS ACK bypass =================
  always_ff @(posedge clk) if (rst_n) begin
    // B-1 : a GETSTATUS/identity-GET segment ACKs on ccc_ack independent of
    //       accept_en / FIFO / TX-empty (so the mandatory read never deadlocks).
    a_b1_getstatus: assert ( !(state == S_ADDR && byte_done && match_da &&
                               ccc_getstatus_seg && ccc_ack && enabled)
                             || want_ack );
  end

  // =========================== §4.B Protocol framing =========================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // F2 : (START || Sr) -> address capture armed next cycle.
    a_f2_arm    : assert ( !($past(start_stb) || $past(rstart_stb)) || addr_capture_armed );
    // F3a: STOP during address capture -> capture cancelled (back to IDLE).
    a_f3_stop   : assert ( !($past(state == S_ADDR) && $past(stop_stb)) || state_idle );
    // F3b: Sr during address capture -> re-armed and post_rstart set.
    a_f3_rstart : assert ( !($past(state == S_ADDR) && $past(rstart_stb))
                           || (addr_capture_armed && post_rstart) );
    // F4 : clean STOP -> IDLE.
    a_f4_stop   : assert ( !$past(stop_stb) || state_idle );
    // F5 : 7E/W with a completed first byte -> CCC frame active next cycle.
    a_f5_ccc    : assert ( !($past(state == S_ADDR) && $past(byte_done) &&
                             $past(match_7e) && !$past(rnw) && $past(enabled))
                           || to_ccc );
    // F6 : extra CCC bytes do not drop the CCC-frame context (surplus tolerated).
    a_f6_extra  : assert ( !($past(state == S_CCC) && $past(frame_is_ccc_q) &&
                             !$past(start_stb) && !$past(stop_stb))
                           || frame_is_ccc_q );
    // F7 : premature STOP during a CCC/data phase -> IDLE and SDA released.
    a_f7_prem   : assert ( !($past(stop_stb) &&
                             ($past(state == S_CCC) || $past(state == S_WRITE) ||
                              $past(state == S_READ)))
                           || (state_idle && !ack_oe) );
  end

  // ===================== misc structural / routing invariants ================
  always_ff @(posedge clk) if (rst_n) begin
    // phase encodes the FSM 9th-bit role consistently.
    a_phase_addr : assert ( !((state == S_ADDR) || (state == S_ACK)) || (phase == i3c_pkg::PH_ADDR) );
    a_phase_data : assert ( !((state == S_WRITE) || (state == S_READ) || (state == S_CCC))
                            || (phase == i3c_pkg::PH_DATA) );
    a_phase_idle : assert ( !((state == S_IDLE) || (state == S_DAA) || (state == S_IGNORE))
                            || (phase == i3c_pkg::PH_IDLE) );
    // RX FIFO push only during a committed data phase.
    a_rx_phase   : assert ( !rx_push || (state == S_WRITE) || (state == S_CCC) );
    // never push a parity-corrupted byte.
    a_rx_clean   : assert ( !rx_push || !parity_err );
    // read drive only while privately/CCC reading.
    a_rd_phase   : assert ( !tx_drive_en || (state == S_READ) );
    // TX pop only on a private (non-CCC) read byte.
    a_txpop      : assert ( !tx_pop || ((state == S_READ) && !read_from_ccc_q) );
  end

  // ---- Reachability covers --------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_ack_7e      : cover (ack_oe && m7e_q && !rnw_q);                 // ACK 7E
    c_ack_da_priv : cover (ack_oe && mda_q && !frame_is_ccc_q);        // ACK private DA
    c_nack_priv   : cover (state_ignore && mda_q && !frame_is_ccc_q);  // passive NACK
    c_getstatus   : cover (want_ack && match_da && ccc_getstatus_seg && !accept_en); // B-1
    c_ccc_frame   : cover (to_ccc);                                    // CCC frame
    c_priv_write  : cover (state == S_WRITE);
    c_priv_read   : cover (state == S_READ);
    c_directed_rd : cover ((state == S_READ) && read_from_ccc_q);      // directed GET
    c_daa         : cover (state == S_DAA);                            // 7E/R in DAA
    c_ignore      : cover (state_ignore);
    c_rstart      : cover (post_rstart && (state == S_ADDR));          // re-armed after Sr
    c_wr_done     : cover (priv_write_done);
    c_rd_req      : cover (priv_read_req);
    c_rx_push     : cover (rx_push);
    // a full minimal private write: START -> ACK -> WRITE -> STOP -> IDLE
    c_full_write  : cover (state_idle && f_past_valid && $past(state == S_WRITE));
  end
`endif

endmodule
`endif
