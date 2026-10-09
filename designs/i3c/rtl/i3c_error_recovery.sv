// ============================================================================
// i3c_error_recovery.sv  -  SDR Target error detection + recovery FSM
//
// Architecture §1.11. Detects the SDR Target Error Types (Table 43):
//   TE0  restricted-address / 7E-R header outside ENTDAA   (ERR-TE0-01/02)
//   TE1  CCC-code parity error                             (ERR-TE1-01)
//   TE2  write-data parity error                           (ERR-TE2-01)
//   TE3  DAA assigned-address PAR error                    (ERR-TE3-01)
//   TE4  non-{7E,R} header after Sr during ENTDAA          (ERR-TE4-01)
//   TE5  illegally-formatted CCC                           (ERR-TE5-01)
//   TE6  optional read-back monitoring (NOT implemented v1, OQ-13 / §6.6)
//
// Recovery arcs to bus-idle (no-hang, SAFE-09 / ERR-REC-RESYNC-01):
//   TE0/TE1  (class HDR)     -> ignore until HDR-Exit Pattern or STOP
//   TE2/TE5  (class DISCARD) -> discard until STOP or Repeated START
//   TE3/TE4  (class NACKDAA) -> NACK then wait for Sr (replay) / STOP
// A STOP or HDR-Exit always returns to idle regardless of class (CE2, SAFE-09).
//
// `in_error` is sticky; while in error the block forbids ACK and any SDA drive
// (ack_inhibit / drive_inhibit) so the Target never falsely ACKs or corrupts
// application state. Each detected error pulses `proto_err_set` (the sticky
// GETSTATUS Protocol-Error bit and its read-to-clear live in i3c_regfile).
//
// Liveness ("never permanently hang") is NOT asserted as safety (critique F-6):
// we prove the bounded-safety recovery arcs (recovery event => leave error) and
// provide cover witnesses that idle is reachable after every TE.
// ============================================================================
`ifndef I3C_ERROR_RECOVERY_SV
`define I3C_ERROR_RECOVERY_SV
`include "i3c_pkg.sv"

module i3c_error_recovery (
  input  logic       clk,
  input  logic       rst_n,
  // bus conditions / edge strobes (front-end)
  input  logic       start_stb,
  input  logic       rstart_stb,
  input  logic       stop_stb,
  input  logic       scl_rising,
  input  logic       scl_falling,
  // assembled byte / framing context
  input  logic [7:0] rx_byte,             // address/CCC byte (TE0 restricted LUT)
  input  logic       byte_done,           // byte boundary
  input  logic [1:0] phase,               // i3c_pkg::phase_e
  input  logic       match_7e,            // address == 7E   (context)
  input  logic       match_da,            // address == DA   (context)
  input  logic       is_read,             // captured RnW    (context)
  input  logic       da_valid,            // DA assigned
  input  logic       daa_active,          // inside ENTDAA (masks TE0, enables TE4)
  // error sources from neighbours
  input  logic       parity_err,          // TE2  (framer write-data parity)
  input  logic       par_err,             // TE3  (daa assigned-address PAR)
  input  logic       te4_event,           // TE4  (daa non-{7E,R} after Sr)
  input  logic       ccc_code_parity_err, // TE1  (ccc code parity)
  input  logic       ccc_illegal_format,  // TE5  (ccc malformed framing)
  input  logic       ccc_supported,       // E7 classify split (unsupported != TE5)
  input  logic       hdr_exit_detected,   // HDR-Exit recovery event
  // outputs
  output logic       in_error,            // recovery active (STATUS[3])
  output logic       err_recoverable,     // enables HDR-Exit detector (exit_en)
  output logic       ack_inhibit,         // forbid ACK while in error
  output logic       drive_inhibit,       // forbid any SDA drive (S3)
  output logic       proto_err_set,       // set sticky proto-err (to regfile)
  output logic [3:0] te_code              // last TE code (STATUS[10:7])
);

  // --------------------------------------------------------------------------
  // TE code encoding (STATUS[10:7]) and recovery-class encoding
  // --------------------------------------------------------------------------
  localparam logic [3:0] TE0_CODE = 4'd0;
  localparam logic [3:0] TE1_CODE = 4'd1;
  localparam logic [3:0] TE2_CODE = 4'd2;
  localparam logic [3:0] TE3_CODE = 4'd3;
  localparam logic [3:0] TE4_CODE = 4'd4;
  localparam logic [3:0] TE5_CODE = 4'd5;
  localparam logic [3:0] TE_NONE  = 4'hF;   // no error latched since reset

  localparam logic [1:0] RC_HDR     = 2'd0; // TE0/TE1 -> HDR-Exit / STOP
  localparam logic [1:0] RC_DISCARD = 2'd1; // TE2/TE5 -> STOP / Sr
  localparam logic [1:0] RC_NACKDAA = 2'd2; // TE3/TE4 -> NACK then Sr / STOP

  // --------------------------------------------------------------------------
  // TE0 restricted-address LUT (ERR-TE0-01).  Header {addr,rnw} is TE0 when:
  //   addr in restricted-set, addr != 7E, RnW == Write   (7F/7C/7A/76/6E/5E/3E W)
  //   OR addr == 7E, RnW == Read                          (7E/R)
  // --------------------------------------------------------------------------
  function automatic logic te0_restricted(input logic [7:0] b);
    logic [6:0] a;
    logic       rnw;
    begin
      a   = b[7:1];
      rnw = b[0];
      te0_restricted =
        (i3c_pkg::is_restricted_addr(a) && (a != i3c_pkg::I3C_BROADCAST_ADDR)
                                        && (rnw == i3c_pkg::RNW_WRITE))
        || ((a == i3c_pkg::I3C_BROADCAST_ADDR) && (rnw == i3c_pkg::RNW_READ));
    end
  endfunction

  // --------------------------------------------------------------------------
  // Per-type detection events (1-cycle).  TE0/TE1/TE2/TE5 only outside ENTDAA;
  // TE3/TE4 only inside ENTDAA (enforced at the neighbours, see assume-ledger).
  // --------------------------------------------------------------------------
  logic te0_event, te1_event, te2_event, te3_event, te4_event_i, te5_event;
  logic te_event;

  assign te0_event   = byte_done && (phase == i3c_pkg::PH_ADDR)
                       && da_valid && !daa_active && te0_restricted(rx_byte);
  assign te1_event   = ccc_code_parity_err;
  assign te2_event   = parity_err;
  assign te3_event   = par_err;
  assign te4_event_i = te4_event;
  assign te5_event   = ccc_illegal_format;

  assign te_event = te0_event | te1_event | te2_event
                  | te3_event | te4_event_i | te5_event;

  // --------------------------------------------------------------------------
  // Priority classify (TE0 > TE1 > TE2 > TE3 > TE4 > TE5).  Mutually-exclusive
  // in time at integration; the encoder makes the latch deterministic anyway.
  // --------------------------------------------------------------------------
  logic [1:0] recov_class;
  logic [3:0] te_code_next;
  logic [1:0] rc_next;
  always_comb begin
    te_code_next = te_code;       // hold last code unless a new error fires
    rc_next      = recov_class;
    if      (te0_event)   begin te_code_next = TE0_CODE; rc_next = RC_HDR;     end
    else if (te1_event)   begin te_code_next = TE1_CODE; rc_next = RC_HDR;     end
    else if (te2_event)   begin te_code_next = TE2_CODE; rc_next = RC_DISCARD; end
    else if (te3_event)   begin te_code_next = TE3_CODE; rc_next = RC_NACKDAA; end
    else if (te4_event_i) begin te_code_next = TE4_CODE; rc_next = RC_NACKDAA; end
    else if (te5_event)   begin te_code_next = TE5_CODE; rc_next = RC_DISCARD; end
  end

  // --------------------------------------------------------------------------
  // Recovery (clear) event.  STOP and HDR-Exit always recover (CE2 / SAFE-09);
  // Sr (Repeated START) additionally recovers the DISCARD and NACKDAA classes.
  // --------------------------------------------------------------------------
  logic clear_event;
  assign clear_event = stop_stb || hdr_exit_detected
                     || (((recov_class == RC_DISCARD) || (recov_class == RC_NACKDAA))
                         && rstart_stb);

  // --------------------------------------------------------------------------
  // Sticky in_error FSM.  First error latches the class/code; while in error
  // the bus is ignored (no reclassification) until a recovery event clears it.
  // Clear has priority over a (physically non-coincident) new event so a
  // recovery condition can never be starved (no-hang).
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_error    <= 1'b0;
      recov_class <= RC_HDR;
      te_code     <= TE_NONE;
    end else if (in_error) begin
      if (clear_event) in_error <= 1'b0;     // recover to idle; te_code retained
    end else if (te_event) begin
      in_error    <= 1'b1;
      recov_class <= rc_next;
      te_code     <= te_code_next;
    end
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign ack_inhibit     = in_error;                              // E3 NACK while in error
  assign drive_inhibit   = in_error;                              // E3 S3 quiet
  assign err_recoverable = in_error && (recov_class == RC_HDR);   // HDR-EXIT-04 (TE0/TE1)
  assign proto_err_set   = te_event;                              // E10 set (sticky in regfile)

`ifdef FORMAL
  // ------------------------------------------------------------------------
  // Explicit 8-code TE0 LUT used to cross-check te0_restricted() (E1).
  //   7F/W=FE 7C/W=F8 7A/W=F4 76/W=EC 6E/W=DC 5E/W=BC 3E/W=7C 7E/R=FD
  // ------------------------------------------------------------------------
  function automatic logic f_te0_lut(input logic [7:0] b);
    f_te0_lut = (b == 8'hFE) || (b == 8'hF8) || (b == 8'hF4) || (b == 8'hEC)
             || (b == 8'hDC) || (b == 8'hBC) || (b == 8'h7C) || (b == 8'hFD);
  endfunction

  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- environment assumptions (assume-ledger; discharged at integration) ----
  always_ff @(posedge clk) if (rst_n) begin
    // Bus conditions are mutually exclusive (i3c_bus_frontend: p_excl/p_no_startstop)
    m_excl_ss  : assume (!(start_stb  && stop_stb));
    m_excl_sr  : assume (!(start_stb  && rstart_stb));
    m_excl_rs  : assume (!(rstart_stb && stop_stb));
    m_scl_edge : assume (!(scl_rising && scl_falling));         // front-end p_scl_edge
    // TE source / ENTDAA-context separation (guaranteed by i3c_daa / i3c_ccc):
    m_te3_daa  : assume (!par_err              || daa_active);  // TE3 only inside DAA
    m_te4_daa  : assume (!te4_event            || daa_active);  // TE4 only inside DAA
    m_te1_ndaa : assume (!ccc_code_parity_err  || !daa_active); // TE1 only outside DAA
    m_te2_ndaa : assume (!parity_err           || !daa_active); // TE2 only outside DAA
    m_te5_ndaa : assume (!ccc_illegal_format   || !daa_active); // TE5 only outside DAA
  end

  // ---- combinational safety ----
  always_ff @(posedge clk) if (rst_n) begin
    // E1  detector LUT is exactly the 8 restricted header codes
    a_e1_lut    : assert (te0_restricted(rx_byte) == f_te0_lut(rx_byte));
    // E2  TE0 is masked while inside ENTDAA
    a_e2_mask   : assert (!daa_active || !te0_event);
    // E3  while in error: forbid ACK and forbid SDA drive
    a_e3_ackq   : assert (!in_error || ack_inhibit);
    a_e3_drvq   : assert (!in_error || drive_inhibit);
    a_inh_eq    : assert ((ack_inhibit == in_error) && (drive_inhibit == in_error));
    // E7  ccc_supported is NOT a trigger: te_event excludes the unsupported flag
    //     (te_event is exactly the OR of the six real TE sources)
    a_e7_split  : assert (te_event ==
                          (te0_event | te1_event | te2_event
                           | te3_event | te4_event_i | te5_event));
    // E10 set: every detected protocol error pulses proto_err_set
    a_e10_set   : assert (proto_err_set == te_event);
    // err_recoverable enabled only for TE0/TE1 (HDR class) while in error
    a_errrec    : assert (!err_recoverable || (in_error && (recov_class == RC_HDR)));
    // classification LUT (E1/E5/E6/E7 mapping) by priority
    a_map_te0   : assert (!te0_event   || ((te_code_next == TE0_CODE) && (rc_next == RC_HDR)));
    a_map_te1   : assert (!(te1_event && !te0_event)
                          || ((te_code_next == TE1_CODE) && (rc_next == RC_HDR)));
    a_map_te2   : assert (!(te2_event && !te0_event && !te1_event)
                          || ((te_code_next == TE2_CODE) && (rc_next == RC_DISCARD)));
    a_map_te3   : assert (!(te3_event && !te0_event && !te1_event && !te2_event)
                          || ((te_code_next == TE3_CODE) && (rc_next == RC_NACKDAA)));
    a_map_te4   : assert (!(te4_event_i && !te0_event && !te1_event && !te2_event && !te3_event)
                          || ((te_code_next == TE4_CODE) && (rc_next == RC_NACKDAA)));
    a_map_te5   : assert (!(te5_event && !te0_event && !te1_event && !te2_event
                            && !te3_event && !te4_event_i)
                          || ((te_code_next == TE5_CODE) && (rc_next == RC_DISCARD)));
  end

  // ---- 1-step temporal safety ----
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // E1  a fresh TE0 raises in_error and latches TE0 (top priority -> unconditional)
    a_e1_set    : assert (!($past(te0_event) && !$past(in_error))
                          || (in_error && (te_code == TE0_CODE)
                              && (recov_class == RC_HDR)));
    // generic: any fresh error latches in_error with the priority-resolved code/class
    a_latch     : assert (!($past(te_event) && !$past(in_error))
                          || (in_error
                              && (te_code     == $past(te_code_next))
                              && (recov_class == $past(rc_next))));
    // E5  TE3 (DAA PAR) -> NACK (inhibits) + NACKDAA class
    a_e5_te3    : assert (!($past(te3_event) && !$past(in_error)
                            && !$past(te0_event) && !$past(te1_event) && !$past(te2_event))
                          || (in_error && ack_inhibit && drive_inhibit
                              && (te_code == TE3_CODE) && (recov_class == RC_NACKDAA)));
    // E6  TE4 -> NACK + NACKDAA class
    a_e6_te4    : assert (!($past(te4_event_i) && !$past(in_error)
                            && !$past(te0_event) && !$past(te1_event)
                            && !$past(te2_event) && !$past(te3_event))
                          || (in_error && ack_inhibit
                              && (te_code == TE4_CODE) && (recov_class == RC_NACKDAA)));
    // E3/E8  HDR-Exit while in error -> idle next cycle
    a_e8_hdr    : assert (!($past(in_error) && $past(hdr_exit_detected)) || !in_error);
    // E8  STOP while in error -> idle next cycle
    a_e8_stop   : assert (!($past(in_error) && $past(stop_stb)) || !in_error);
    // E8/E4  any recovery (clear) event while in error -> idle next cycle (no hang)
    a_e8_clr    : assert (!($past(in_error) && $past(clear_event)) || !in_error);
    // E4  DISCARD class: STOP or Sr returns to idle
    a_e4_disc   : assert (!($past(in_error) && ($past(recov_class) == RC_DISCARD)
                            && ($past(stop_stb) || $past(rstart_stb))) || !in_error);
    // te_code holds (status latch) while no new error is latched
    a_code_hold : assert (!($past(te_event) == 1'b0 && $past(in_error))
                          || (te_code == $past(te_code)));
  end

  // ---- cover witnesses (E9 no-deadlock: reach error, then reach idle) ----
  reg f_was_error = 1'b0;
  always_ff @(posedge clk) if (rst_n && in_error) f_was_error <= 1'b1;

  always_ff @(posedge clk) if (rst_n) begin
    c_in_error : cover (in_error);
    c_te0      : cover (in_error && (te_code == TE0_CODE));
    c_te1      : cover (in_error && (te_code == TE1_CODE));
    c_te2      : cover (in_error && (te_code == TE2_CODE));
    c_te3      : cover (in_error && (te_code == TE3_CODE));
    c_te4      : cover (in_error && (te_code == TE4_CODE));
    c_te5      : cover (in_error && (te_code == TE5_CODE));
    c_errrec   : cover (err_recoverable);
    c_recover  : cover (f_was_error && !in_error);             // idle reachable after error
  end

  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    c_hdr_rec  : cover (f_was_error && !in_error && $past(hdr_exit_detected) && $past(in_error));
    c_stop_rec : cover (f_was_error && !in_error && $past(stop_stb)          && $past(in_error));
    c_sr_rec   : cover (f_was_error && !in_error && $past(rstart_stb)        && $past(in_error)
                        && ($past(recov_class) == RC_DISCARD));
  end
`endif

endmodule
`endif
