// ============================================================================
// i3c_daa.sv  -  Dynamic Address Assignment / address lifecycle (architecture §1.7)
//
// Owns dyn_addr / da_valid (interfaces.md N-6). Responsibilities:
//   * ENTDAA participation gated by !da_valid (a Target that already holds a DA
//     does NOT respond / does NOT drive during the round).            [C8]
//   * After ACKing Sr+7'h7E/R it drives its 64-bit {PID[47:0],BCR,DCR} payload
//     MSB-first, OPEN-DRAIN, with per-bit arbitration (drive Low for 0, release
//     for 1; on release-but-sampled-Low it has lost -> latch arb_lost, go quiet).
//   * Receives the assigned 7-bit DA + odd-parity PAR; ACKs (drive Low) and
//     latches the DA iff PAR == ~(^DA[6:0]); else passive NACK and re-arms with
//     the SAME PID for the next round.                                [T5]
//   * Clean STOP exit from any phase (no deadlock); aborted/re-armed rounds.
//   * Loads DA from SETDASA / SETAASA (param STATIC_ADDR_EN) / SETNEWDA.
//   * RSTDAA / whole-target reset clear da_valid.                     [C9]
//   * dyn_addr / da_valid change ONLY via those enumerated events.    [A4]
//
// SDA drive model (design_decisions §3): open-drain only here -> daa_o is tied 0;
// daa_oe=1 drives Low (ACK / payload-0-bit), daa_oe=0 releases (payload-1-bit /
// NACK). Push-pull is never used in DAA (R-DAA-07).
//
// Standalone formal: neighbour strobes (SCL edges, START/Sr/STOP, byte_done,
// CCC decode strobes) are free inputs constrained by realistic `assume`s; every
// assume is recorded in the result for the integration assume-ledger.
// ============================================================================
`ifndef I3C_DAA_SV
`define I3C_DAA_SV
`include "i3c_pkg.sv"

module i3c_daa #(
  parameter bit STATIC_ADDR_EN = 1'b1     // enable SETDASA / SETAASA static load
) (
  input  logic        clk,
  input  logic        rst_n,
  // bus event strobes (front-end / bit engine)
  input  logic        scl_rising,
  input  logic        scl_falling,
  input  logic        sda_sync,
  input  logic        start_stb,
  input  logic        rstart_stb,
  input  logic        stop_stb,
  input  logic [3:0]  bit_cnt,
  input  logic        byte_done,
  input  logic [7:0]  rx_byte,
  // identity (regfile) - the DAA payload source
  input  logic [47:0] pid,
  input  logic [7:0]  bcr,
  input  logic [7:0]  dcr,
  // CCC decode strobes
  input  logic        entdaa_start,    // ENTDAA broadcast accepted (one round)
  input  logic        entdaa_active,   // CCC-tracked ENTDAA round active
  input  logic        rstdaa,          // RSTDAA -> clear DA
  input  logic        setdasa_load,    // SETDASA static load
  input  logic        setaasa_load,    // SETAASA static load
  input  logic        setnewda_load,   // SETNEWDA change DA
  input  logic [6:0]  load_addr,       // DA value for SET*DASA / SETNEWDA
  input  logic        whole_reset,     // whole-target reset -> clear DA
  // dynamic-address fan-out (owned here)
  output logic [6:0]  dyn_addr,
  output logic        da_valid,
  output logic        daa_active,      // DAA round in progress (PFSM routing)
  output logic        daa_done,        // DA latched this round (INT da_changed)
  output logic        daa_oe,          // -> src_oe[SDA_DAA]
  output logic        daa_o,           // -> src_o[SDA_DAA]
  output logic        arb_lost,        // lost ENTDAA arbitration this round
  output logic        par_err,         // DA odd-parity mismatch (TE3 source)
  output logic        te4_event,       // non-{7E,R} header after Sr in DAA (TE4)
  output logic        rxda_enter       // pulse: payload done -> re-align bit framing for DA byte (FINDING-SIM-3)
);

  // -------------------------------------------------------------------------
  // DAA round FSM
  // -------------------------------------------------------------------------
  localparam logic [2:0] S_IDLE  = 3'd0;  // not in a round
  localparam logic [2:0] S_HDR   = 3'd1;  // await 7E/R header byte (participating)
  localparam logic [2:0] S_ACK7E = 3'd2;  // drive ACK Low for 7E/R
  localparam logic [2:0] S_PLD   = 3'd3;  // drive 64-bit payload w/ arbitration
  localparam logic [2:0] S_RXDA  = 3'd4;  // receive assigned DA + PAR byte
  localparam logic [2:0] S_ACKDA = 3'd5;  // ACK (latch) or NACK (re-arm) the DA
  localparam logic [2:0] S_WAIT  = 3'd6;  // passive: lost / done / TE4 -> await STOP

  logic [2:0] state;
  logic [6:0] payload_idx;              // 0..63 payload bit index
  logic       participating;           // engaged in this round (entered with !da_valid)
  logic       da_ack_pending;          // S_ACKDA should ACK (parity was good)

  // ---- payload word: {PID[47:0], BCR[7:0], DCR[7:0]} MSB-first ---------------
  logic [63:0] pl_word;
  logic [6:0]  pl_sel;
  logic        pl_bit;
  assign pl_word = {pid, bcr, dcr};
  assign pl_sel  = 7'd63 - payload_idx;          // idx0 -> bit63 = pid[47] (MSb first)
  assign pl_bit  = pl_word[pl_sel];

  // ---- combinational decode -------------------------------------------------
  wire is_7e_read = (rx_byte == 8'hFD);          // {7'h7E, RnW=READ}
  wire dec_par_ok = (rx_byte[0] == ~(^rx_byte[7:1]));   // odd parity on DA[6:0]

  // Pulse exactly when the 64th payload bit is clocked and we move to S_RXDA, so
  // the shared bit engine restarts byte assembly for the assigned-address byte
  // (the 64-bit payload is not a multiple of 9, so framing would otherwise drift).
  assign rxda_enter = (state == S_PLD) && scl_rising && (payload_idx == 7'd63) &&
                      !(pl_bit && !sda_sync);

  // ---- effective DA-mutating events (priority order matches the always_ff) --
  wire ev_dasa  = STATIC_ADDR_EN && setdasa_load && !da_valid;   // adopt static
  wire ev_aasa  = STATIC_ADDR_EN && setaasa_load && !da_valid;   // adopt static
  wire ev_newda = setnewda_load && da_valid;                     // change existing
  wire ev_entdaa_win = (state == S_RXDA) && byte_done && dec_par_ok; // ENTDAA latch

  // -------------------------------------------------------------------------
  // SDA drive (open-drain only): daa_o tied 0; daa_oe=1 => drive Low
  // -------------------------------------------------------------------------
  always_comb begin
    daa_oe = 1'b0;
    if (participating && !arb_lost) begin
      case (state)
        S_ACK7E: daa_oe = 1'b1;                 // ACK the 7E/R header (Low)
        S_PLD:   daa_oe = (pl_bit == 1'b0);     // open-drain: drive Low only for 0
        S_ACKDA: daa_oe = da_ack_pending;       // ACK the assigned DA (Low) if parity ok
        default: daa_oe = 1'b0;
      endcase
    end
  end
  assign daa_o = 1'b0;                           // never push-pull in DAA (R-DAA-07)

  // -------------------------------------------------------------------------
  // Status / error pulses
  // -------------------------------------------------------------------------
  assign daa_active = (state != S_IDLE) || entdaa_active;
  assign par_err    = (state == S_RXDA) && byte_done && !dec_par_ok;   // [T5/TE3]
  assign te4_event  = (state == S_HDR)  && byte_done && !is_7e_read;   // [TE4]

  // -------------------------------------------------------------------------
  // Dynamic-address register : changes ONLY here, ONLY via enumerated events [A4]
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      da_valid <= 1'b0;
      dyn_addr <= 7'd0;
    end else if (whole_reset) begin
      da_valid <= 1'b0;                          // whole reset -> defaults
      dyn_addr <= 7'd0;
    end else if (rstdaa) begin
      da_valid <= 1'b0;                          // [C9] clear DA, keep value
    end else if (ev_dasa) begin
      da_valid <= 1'b1;
      dyn_addr <= load_addr;
    end else if (ev_aasa) begin
      da_valid <= 1'b1;
      dyn_addr <= load_addr;
    end else if (ev_newda) begin
      dyn_addr <= load_addr;                     // da_valid already 1
    end else if (ev_entdaa_win) begin
      da_valid <= 1'b1;
      dyn_addr <= rx_byte[7:1];                  // assigned DA = byte[7:1]
    end
  end

  // DA-changed pulse (INT da_changed)
  always_ff @(posedge clk) begin
    if (!rst_n) daa_done <= 1'b0;
    else        daa_done <= ev_dasa || ev_aasa || ev_newda || ev_entdaa_win;
  end

  // -------------------------------------------------------------------------
  // Round FSM + arbitration + payload index
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      payload_idx    <= 7'd0;
      arb_lost       <= 1'b0;
      da_ack_pending <= 1'b0;
      participating  <= 1'b0;
    end else if (whole_reset) begin
      state          <= S_IDLE;
      payload_idx    <= 7'd0;
      arb_lost       <= 1'b0;
      da_ack_pending <= 1'b0;
      participating  <= 1'b0;
    end else begin
      case (state)
        // -------------------------------------------------------------------
        S_IDLE: begin
          arb_lost       <= 1'b0;
          payload_idx    <= 7'd0;
          da_ack_pending <= 1'b0;
          if (entdaa_start) begin
            participating <= !da_valid;          // [C8] participate iff no DA
            state         <= da_valid ? S_WAIT : S_HDR;
          end else begin
            participating <= 1'b0;
          end
        end
        // -------------------------------------------------------------------
        S_HDR: begin
          if (stop_stb)        state <= S_IDLE;
          else if (byte_done)  state <= is_7e_read ? S_ACK7E : S_WAIT; // TE4 -> wait
        end
        // -------------------------------------------------------------------
        S_ACK7E: begin
          if (stop_stb)         state <= S_IDLE;
          else if (scl_rising) begin            // ACK sampled -> start payload
            state       <= S_PLD;
            payload_idx <= 7'd0;
          end
        end
        // -------------------------------------------------------------------
        S_PLD: begin
          if (stop_stb)            state <= S_IDLE;
          else if (rstart_stb)     state <= S_WAIT;       // mid-payload abort
          else if (scl_rising) begin
            if (pl_bit && !sda_sync) begin                // released 1, saw 0 -> lost
              arb_lost <= 1'b1;
              state    <= S_WAIT;
            end else if (payload_idx == 7'd63) begin
              state    <= S_RXDA;                         // 64 bits driven, win so far
            end else begin
              payload_idx <= payload_idx + 7'd1;
            end
          end
        end
        // -------------------------------------------------------------------
        S_RXDA: begin
          if (stop_stb)        state <= S_IDLE;
          else if (byte_done) begin
            da_ack_pending <= dec_par_ok;                 // ACK iff odd parity ok
            state          <= S_ACKDA;
          end
        end
        // -------------------------------------------------------------------
        S_ACKDA: begin
          if (stop_stb)         state <= S_IDLE;
          else if (scl_rising)  state <= da_ack_pending ? S_WAIT  // won, await STOP
                                                        : S_HDR;  // NACK -> re-arm (same PID)
        end
        // -------------------------------------------------------------------
        S_WAIT: begin
          if (stop_stb) state <= S_IDLE;
        end
        // -------------------------------------------------------------------
        default: state <= S_IDLE;
      endcase

      // Clean round end (STOP) from any phase: drop participation and clear the
      // per-round working registers (state already routed to S_IDLE above).
      if (stop_stb) begin
        participating  <= 1'b0;
        arb_lost       <= 1'b0;
        payload_idx    <= 7'd0;
        da_ack_pending <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // Formal properties
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (assume-ledger) ------------------------------
  always_ff @(posedge clk) begin
    // SCL edge strobes are never simultaneous (one settled edge per strobe).
    am_scl_excl   : assume (!(scl_rising && scl_falling));
    // Bus conditions are mutually exclusive.
    am_bus_excl   : assume ($onehot0({start_stb, rstart_stb, stop_stb}));
    // byte_done is produced by the bit engine at the RX sample edge.
    am_bd_edge    : assume (!byte_done || scl_rising);
    // CCC issues exactly one ENTDAA-accept per round, only while DAA is idle.
    am_entdaa_idle: assume (!entdaa_start || state == S_IDLE);
    // ENTDAA-accept is a mid-frame CCC decode strobe; it never coincides with a
    // bus framing condition (START/Sr/STOP).
    am_entdaa_bus : assume (!entdaa_start || !(start_stb || rstart_stb || stop_stb));
    // At most one DA-mutating command per cycle (CCC sequences them).
    am_cmd_onehot : assume ($onehot0({entdaa_start, rstdaa, setdasa_load,
                                      setaasa_load, setnewda_load, whole_reset}));
    // PID/BCR/DCR are elaboration constants from the regfile (stable across rounds).
    if (f_past_valid) begin
      am_pid_stable : assume ($stable(pid));
      am_bcr_stable : assume ($stable(bcr));
      am_dcr_stable : assume ($stable(dcr));
    end
  end

  // ---- Structural helper invariants (aid k-induction) -----------------------
  always_ff @(posedge clk) if (rst_n) begin
    // Every round-active state (all but IDLE/WAIT) implies we are participating.
    inv_part_states : assert (!(state == S_HDR  || state == S_ACK7E ||
                                state == S_PLD  || state == S_RXDA  ||
                                state == S_ACKDA) || participating);
    inv_pld_idx     : assert (!(state == S_PLD) || (payload_idx <= 7'd63));
    // arb_lost is only ever set together with the move to S_WAIT, and cleared on
    // STOP/idle -> arb_lost implies we are in the passive wait state.
    inv_arb_wait    : assert (!arb_lost || (state == S_WAIT));
    inv_state_range : assert (state <= S_WAIT);
  end

  // ---- C8 : ENTDAA gating ----------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    // Never drive SDA unless actively participating in the round.
    c8_gate_drive : assert (participating || !daa_oe);
  end
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // ENTDAA while holding a DA -> do NOT participate / never drive this round.
    c8_hasda : assert (!($past(entdaa_start) &&  $past(da_valid)) || !participating);
    // ENTDAA without a DA -> participate (enter the round, engaged).
    c8_part  : assert (!($past(entdaa_start) && !$past(da_valid)) ||
                       (participating && state == S_HDR));
  end

  // ---- C9 : RSTDAA clears DA -------------------------------------------------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    c9_rstdaa : assert (!$past(rstdaa) || !da_valid);
  end

  // ---- A4 : dyn_addr / da_valid change only via enumerated events ------------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    a4_dyn : assert ((dyn_addr == $past(dyn_addr)) ||
                     $past(ev_entdaa_win) || $past(ev_dasa) || $past(ev_aasa) ||
                     $past(ev_newda)      || $past(whole_reset));
    a4_val : assert ((da_valid == $past(da_valid)) ||
                     $past(ev_entdaa_win) || $past(ev_dasa) || $past(ev_aasa) ||
                     $past(ev_newda)      || $past(rstdaa)  || $past(whole_reset));
  end

  // ---- T5 : DAA odd-parity check (combinational) -----------------------------
  always_ff @(posedge clk) if (rst_n) begin
    t5_par : assert (!((state == S_RXDA) && byte_done) ||
                     (par_err == (rx_byte[0] != ~(^rx_byte[7:1]))));
  end

  // ---- ID4 : DAA payload == regfile PID/BCR/DCR, MSB-first, open-drain --------
  always_ff @(posedge clk) if (rst_n) begin
    id4_src     : assert (pl_word == {pid, bcr, dcr});  // payload word = regfile, in order
    id4_payload : assert (!(state == S_PLD) ||
                          (daa_oe == (pl_bit == 1'b0))); // MSb-first, open-drain Low-for-0
    // open-drain discipline: DAA never drives a High (S2), and arb-loss releases (S8)
    s2_od       : assert (!daa_oe || (daa_o == 1'b0));
    s8_arb      : assert (!arb_lost || !daa_oe);
  end

  // ---- Cover : a full DAA round and an aborted / re-armed round --------------
  always_ff @(posedge clk) if (rst_n) begin
    c_participate : cover (participating);
    c_ack7e       : cover (state == S_ACK7E);
    c_payload     : cover ((state == S_PLD) && (payload_idx == 7'd5));
    c_win         : cover (ev_entdaa_win);                       // DA latched
    c_round_full  : cover (da_valid && daa_done);               // full ENTDAA round
    c_par_nack    : cover (par_err);                            // bad-parity NACK
    c_arblost     : cover (arb_lost);                           // lost arbitration
    c_entdaa_act  : cover (entdaa_active);
  end
  always_ff @(posedge clk) if (f_past_valid && rst_n) begin
    c_rearm  : cover ($past(state == S_ACKDA) && !$past(da_ack_pending) &&
                      (state == S_HDR));                         // NACK -> re-arm
    c_abort  : cover (($past(state) != S_IDLE) && (state == S_IDLE) &&
                      $past(stop_stb));                          // STOP aborts round
  end
`endif

endmodule
`endif
