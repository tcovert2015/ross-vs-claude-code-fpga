// ============================================================================
// i3c_hdr_exit_detector.sv  -  HDR Exit Pattern + Target Reset Pattern recognizer
//
// Architecture §1.5 / interfaces §2.4.  One SDA-transition counter, qualified by
// scl_sync==0 and reset whenever scl_sync==1 (the fully-synchronous equivalent of
// the async-reset reference in MIPI Listing 1; critique fix B-4, R-HDREXIT-08).
//
// Both recognizers derive from the SAME transition stream (B-4):
//   * HDR Exit Pattern : SDA starts High, SCL held Low, SDA falls (High->Low)
//                        exactly 4 times, then a STOP.  (R-HDREXIT-02)
//                        -> hdr_exit_detected pulses on the 4th fall (gated by exit_en).
//   * Target Reset Pat : 14 SDA transitions while SCL held Low, ending SDA-High,
//                        then a repeated-START (Sr) then a STOP.  (R-TRP-RECOG)
//                        -> trp_body_valid at count==14, trp_trigger on body->Sr->STOP.
//
// Because the transition stream strictly alternates from SDA-High, the 4th High->Low
// fall is the 7th transition (count 6 -> 7) and the 14-transition TRP body ends High
// (count 14, even).  An HDR Exit (4 falls = 7 transitions) is therefore strictly
// shorter than a TRP body (14) and never advances the TRP path (R-TRP-DISTINGUISH).
//
// Enable: exit_en = is_hdr || err_recoverable (HDR-EXIT-04).  Only the HDR-Exit
// *action* is gated by exit_en (HDR-EXIT-05 / S5); TRP recognition is always-on
// (RST-00, always-available domain).
// ============================================================================
`ifndef I3C_HDR_EXIT_DETECTOR_SV
`define I3C_HDR_EXIT_DETECTOR_SV
`include "i3c_pkg.sv"

module i3c_hdr_exit_detector (
  input  logic clk,
  input  logic rst_n,
  // synchronized bus levels (front-end)
  input  logic sda_sync,        // synced SDA level
  input  logic scl_sync,        // synced SCL level (count qualified by ==0; ==1 resets)
  // edge strobes (front-end, 1-cycle)
  input  logic sda_falling,     // SDA High->Low  (HDR-Exit counts 4 falls)
  input  logic sda_rising,      // SDA Low->High  (TRP counts 14 transitions total)
  // bus conditions (front-end, 1-cycle, asserted while SCL High)
  input  logic rstart_stb,      // repeated START (Sr) -- TRP order body->Sr->STOP
  input  logic stop_stb,        // STOP -- completes HDR-Exit / TRP
  // enable
  input  logic exit_en,         // is_hdr || err_recoverable
  // outputs
  output logic hdr_exit_detected, // 4 SDA falls w/ SCL Low (+exit_en) -> HDR Exit
  output logic trp_body_valid,    // 14-transition Target-Reset body recognized
  output logic trp_trigger        // body->Sr->STOP completed -> fire Target Reset
);

  // Recognition thresholds on the shared transition counter.
  localparam logic [3:0] HDR_FALL4_CNT = 4'd6;  // pre-count before the 7th xition(=4th fall)
  localparam logic [3:0] TRP_BODY_CNT  = 4'd14; // 14 transitions, ends SDA-High
  localparam logic [3:0] CNT_MAX       = 4'd15; // saturate (overshoot bucket)

  // --------------------------------------------------------------------------
  // ONE shared SDA-transition counter (B-4).  Counts every SDA edge while SCL is
  // Low; SCL High forces it back to 0 (HDR-EXIT-06 / R-HDREXIT-07).
  // --------------------------------------------------------------------------
  logic [3:0] xn_cnt;
  logic       xition;            // an SDA transition while SCL is Low
  assign xition = ~scl_sync & (sda_rising | sda_falling);

  always_ff @(posedge clk) begin
    if (!rst_n)            xn_cnt <= 4'd0;
    else if (scl_sync)     xn_cnt <= 4'd0;                 // SCL High resets the count
    else if (xition && (xn_cnt != CNT_MAX))
                           xn_cnt <= xn_cnt + 4'd1;
  end

  // --------------------------------------------------------------------------
  // HDR Exit: pulse on the 4th High->Low fall (the 7th transition: count 6 -> 7),
  // gated by exit_en (no spurious action otherwise, S5 / HDR-EXIT-05).
  // --------------------------------------------------------------------------
  assign hdr_exit_detected = exit_en & ~scl_sync & sda_falling & (xn_cnt == HDR_FALL4_CNT);

  // --------------------------------------------------------------------------
  // TRP body recognition + body->Sr->STOP trigger sequence.
  //   recog       : instantaneous 14-transition body (R1 LHS)
  //   trp_body_q  : sticky body flag (must survive the SCL-High Sr/STOP)
  //   got_sr_q    : sticky "Sr seen after body"
  // A STOP ends the sequence: it either triggers (if Sr already seen) or aborts.
  // --------------------------------------------------------------------------
  logic recog, trp_body_q, got_sr_q;
  assign recog          = ~scl_sync & (xn_cnt == TRP_BODY_CNT) & sda_sync; // SCL Low, ends High
  assign trp_body_valid = trp_body_q | recog;                              // R1: combinational
  assign trp_trigger    = got_sr_q & stop_stb;                             // STOP after Sr

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      trp_body_q <= 1'b0;
      got_sr_q   <= 1'b0;
    end else if (stop_stb) begin           // STOP: trigger (if got_sr) then clear
      trp_body_q <= 1'b0;
      got_sr_q   <= 1'b0;
    end else begin
      if (recog)                       trp_body_q <= 1'b1;
      if (rstart_stb && trp_body_valid) got_sr_q  <= 1'b1;
    end
  end

  // ==========================================================================
  // Formal properties (Slice 8: §4.I R1-R3, §4.A S5; critique B-4)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (front-end contract; assume<->assert ledger) --
  // A1: edge strobes are consistent with the synced level (the front-end derives
  //     sda_rising/sda_falling exactly this way).  Guarantees a strictly
  //     alternating transition stream.
  // A2: a plain SDA rise and fall cannot occur in the same cycle.
  // A3: Sr / STOP are bus conditions formed while SCL is High; they are mutually
  //     exclusive and coincide with the corresponding SDA edge.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    am_rise : assume (sda_rising  == ( sda_sync & ~$past(sda_sync)));
    am_fall : assume (sda_falling == (~sda_sync &  $past(sda_sync)));
  end
  always_ff @(posedge clk) if (rst_n) begin
    am_edge_excl : assume (!(sda_rising && sda_falling));
    am_sr_high   : assume (!rstart_stb || ( scl_sync && sda_falling));
    am_stop_high : assume (!stop_stb   || ( scl_sync && sda_rising));
    am_sr_stop   : assume (!(rstart_stb && stop_stb));
  end

  // ---- Helper invariant: Sr-seen implies the body was recognized -------------
  always_ff @(posedge clk) if (rst_n) begin
    f_inv_sr_body : assert (!got_sr_q || trp_body_q);
  end

  // ---- R1 : TRP recognize at count 14 (R-TRP-RECOG) --------------------------
  // (scl_low && sda_edge_cnt==14 && sda==1) -> trp_body_valid
  always_ff @(posedge clk) if (rst_n) begin
    a_R1_recog : assert (!(~scl_sync && (xn_cnt == TRP_BODY_CNT) && sda_sync)
                         || trp_body_valid);
  end

  // ---- R2 : distinguish Exit(4) from Reset(14) (R-TRP-DISTINGUISH, B-4) -------
  // An HDR Exit (4 falls) with no valid 14-transition body must NOT trigger reset.
  always_ff @(posedge clk) if (rst_n) begin
    a_R2_distinguish : assert (!(hdr_exit_detected && !trp_body_valid) || !trp_trigger);
    // strong form: any trigger implies the body was/ is recognized.
    a_R2_trig_body   : assert (!trp_trigger || trp_body_valid);
  end

  // ---- R3 : trigger order body -> Sr -> STOP (R-TRP-TRIGGER) ------------------
  // Safety direction: a trigger can only occur as STOP, with Sr already seen, with
  // the body already recognized (i.e. the ordering body->Sr->STOP held).
  always_ff @(posedge clk) if (rst_n) begin
    a_R3_needs_stop : assert (!trp_trigger || stop_stb);
    a_R3_needs_sr   : assert (!trp_trigger || got_sr_q);
    a_R3_needs_body : assert (!trp_trigger || trp_body_q);
  end

  // ---- S5 : no spurious HDR-Exit action when !exit_en (R-HDREXIT-06) ----------
  always_ff @(posedge clk) if (rst_n) begin
    a_S5_no_spurious : assert (exit_en || !hdr_exit_detected);
  end

  // ---- HDR-EXIT-06 : SCL High forces the counter to 0 ------------------------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    a_scl_resets_cnt : assert (!$past(scl_sync) || (xn_cnt == 4'd0));
  end

  // ---- Counter never exceeds its saturation value (state bound) ---------------
  always_ff @(posedge clk) if (rst_n) begin
    f_cnt_bound : assert (xn_cnt <= CNT_MAX);
  end

  // --------------------------------------------------------------------------
  // Reachability covers (non-vacuity + B-4 distinguish witness)
  // --------------------------------------------------------------------------
  reg seen_hdr = 1'b0;
  reg seen_body = 1'b0;
  always_ff @(posedge clk) if (rst_n) begin
    if (hdr_exit_detected) seen_hdr  <= 1'b1;
    if (trp_body_valid)    seen_body <= 1'b1;
  end

  always_ff @(posedge clk) if (rst_n) begin
    c_hdr_exit   : cover (hdr_exit_detected);                 // 4-fall HDR Exit fires
    c_body       : cover (trp_body_valid);                    // 14-transition body
    c_trigger    : cover (trp_trigger);                       // full body->Sr->STOP
    // B-4 distinguish witness: an HDR Exit (4 falls) occurs *and* the run still
    // reaches a real TRP trigger -> Exit did not block, and did not itself trigger.
    c_distinguish: cover (seen_hdr && trp_trigger);
    // HDR Exit with NO reset trigger (pure exit, count never reaches 14).
    c_exit_only  : cover (seen_hdr && !seen_body && stop_stb);
  end
`endif

endmodule
`endif
