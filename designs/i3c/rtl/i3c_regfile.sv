// ============================================================================
// i3c_regfile.sv  -  Identity / characteristic / configuration register block
//
// Owns every Target-visible register that is NOT a live core status or a FIFO:
//   * Read-only identity straps  : BCR, DCR, 48-bit Provisioned ID (ID-*).
//   * Mutable config             : MWL/MRL (16-bit, MSB-first GET, range-checked
//                                  SET, out-of-range => leave unchanged, OQ-32),
//                                  Max IBI Payload (SETMRL 3rd byte, 0=unlimited).
//   * Event enable               : ibi_en (ENEC/DISEC EVT_ENINT; reset = 1, IBI-EN-02).
//   * GETSTATUS Format-1 assembler with sticky proto_err (set on a protocol-error
//                                  event, read-to-clear on GETSTATUS completion;
//                                  SET WINS over the read-clear, critique B-8).
//   * GETCAPS constant bytes     : {GETCAP4,GETCAP3,GETCAP2,GETCAP1}.
//   * RSTACT reset-action + escalation-arm in an always-on sub-domain: reset_action
//                                  and escalation_armed survive a peripheral reset;
//                                  whole reset clears config back to defaults.
//
// All ports follow docs/interfaces.md §2.3 verbatim. The five identity ports/params
// of the original Slice-0 block are retained, and their proofs (ID1-ID3) kept green.
//
//   PID layout (ID-PID-02): [47:33]=15-bit MIPI MfgID, [32]=type selector
//   (1=random,0=vendor-fixed), [31:0]=vendor-fixed value or random.
// ============================================================================
`ifndef I3C_REGFILE_SV
`define I3C_REGFILE_SV
`include "i3c_pkg.sv"

module i3c_regfile #(
  // ---- Identity straps (built; ID-BCR/DCR/PID) ----
  parameter logic [7:0]  BCR      = i3c_pkg::BCR_DEFAULT,
  parameter logic [7:0]  DCR      = i3c_pkg::DCR_DEFAULT,
  parameter logic [14:0] MFG_ID   = 15'h0000,        // PID[47:33] - product-specific
  parameter logic        PID_TYPE = 1'b0,            // PID[32] 0=vendor-fixed
  parameter logic [31:0] PID_VAL  = 32'h0000_0000,   // PID[31:0]
  // ---- Config defaults / maxima (OQ-32; numeric values are a product decision) ----
  parameter logic [15:0] MWL_DEFAULT    = 16'd64,
  parameter logic [15:0] MRL_DEFAULT    = 16'd64,
  parameter logic [7:0]  MAXIBI_DEFAULT = 8'd0,       // 0 = unlimited
  parameter logic [7:0]  GETCAP3        = i3c_pkg::GETCAP3_DEFAULT,
  // SET range bound: value > *_MAX is "out of range" => leave register unchanged.
  parameter logic [15:0] MWL_MAX        = 16'd256,
  parameter logic [15:0] MRL_MAX        = 16'd256
) (
  input  logic        clk,
  input  logic        rst_n,
  // ---- bus-side read ports (constants + config) ----
  output logic [7:0]  bcr,
  output logic [7:0]  dcr,
  output logic [47:0] pid,
  output logic [15:0] mwl,
  output logic [15:0] mrl,
  output logic [7:0]  max_ibi_payload,
  output logic        ibi_en,
  output logic [15:0] getstatus_word,
  output logic [31:0] getcaps,
  output logic [1:0]  reset_action,          // 0=none, 1=periph, 2=whole
  output logic        escalation_armed,
  output logic        last_reset_was_whole,
  output logic        proto_err_seen,
  // ---- CCC bus-side writes (from i3c_ccc) ----
  input  logic        ccc_set_mwl,
  input  logic [15:0] ccc_mwl_val,
  input  logic        ccc_set_mrl,
  input  logic [15:0] ccc_mrl_val,
  input  logic        ccc_set_maxibi,
  input  logic [7:0]  ccc_maxibi_val,
  input  logic        ccc_ibi_en_set,
  input  logic        ccc_ibi_en_clr,
  input  logic        ccc_set_rstact,
  input  logic [7:0]  ccc_rstact_val,
  input  logic        getstatus_rd,
  // ---- status / reset events ----
  input  logic        proto_err_set,
  input  logic [3:0]  pending_irq,
  input  logic [1:0]  activity_mode,
  input  logic        trp_trigger,
  input  logic        start_clr,
  input  logic        periph_reset,
  input  logic        whole_reset,
  // ---- app-side (from i3c_avalon_mm) ----
  input  logic        app_wr_en,
  input  logic [4:0]  app_wr_idx,
  input  logic [31:0] app_wr_data,
  input  logic [3:0]  app_wr_be,
  input  logic [4:0]  app_rd_idx,
  output logic [31:0] app_rd_data
);

  // ---- RF-owned Avalon word indices (docs/interfaces.md §3) -----------------
  // app_wr_idx/app_rd_idx are 4-bit; CAPS(16)/RESET_CFG(17) are read through the
  // dedicated getcaps/reset_action/escalation_armed/last_reset_was_whole outputs
  // (netlist §4), so the 4-bit window only needs to reach indices 5..9 and 15.
  localparam logic [4:0] IDX_PID_LOW  = 5'd5;
  localparam logic [4:0] IDX_PID_HIGH = 5'd6;
  localparam logic [4:0] IDX_IDENT    = 5'd7;
  localparam logic [4:0] IDX_MWL      = 5'd8;
  localparam logic [4:0] IDX_MRL      = 5'd9;
  localparam logic [4:0] IDX_GSCFG    = 5'd15;
  localparam logic [4:0] IDX_CAPS     = 5'd16;
  localparam logic [4:0] IDX_RESET    = 5'd17;

  // ==========================================================================
  // Read-only identity constants (built straps)
  // ==========================================================================
  assign bcr = BCR;
  assign dcr = DCR;
  assign pid = {MFG_ID, PID_TYPE, PID_VAL};   // [47:33][32][31:0]

  // GETCAPS constant bytes: {GETCAP4,GETCAP3,GETCAP2,GETCAP1} (§3 CAPS map).
  assign getcaps = {i3c_pkg::GETCAP4_CONST, GETCAP3,
                    i3c_pkg::GETCAP2_CONST, i3c_pkg::GETCAP1_CONST};

  // ==========================================================================
  // MWL / MRL / Max IBI Payload (range-checked SET; app direct write; whole-reset)
  //   Priority: rst_n > whole_reset > CCC SET > Avalon app write.
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n)            mwl <= MWL_DEFAULT;
    else if (whole_reset)  mwl <= MWL_DEFAULT;                 // RST-CFGLIST-01
    else if (ccc_set_mwl) begin
      if (ccc_mwl_val <= MWL_MAX) mwl <= ccc_mwl_val;          // in-range commit
      // else: out of range -> leave unchanged (OQ-32, R-MWL-3)
    end
    else if (app_wr_en && app_wr_idx == IDX_MWL) begin
      if (app_wr_be[0]) mwl[7:0]  <= app_wr_data[7:0];
      if (app_wr_be[1]) mwl[15:8] <= app_wr_data[15:8];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)            mrl <= MRL_DEFAULT;
    else if (whole_reset)  mrl <= MRL_DEFAULT;                 // RST-CFGLIST-01
    else if (ccc_set_mrl) begin
      if (ccc_mrl_val <= MRL_MAX) mrl <= ccc_mrl_val;          // in-range commit
      // else: out of range -> leave unchanged (OQ-32, R-MRL-3)
    end
    else if (app_wr_en && app_wr_idx == IDX_MRL) begin
      if (app_wr_be[0]) mrl[7:0]  <= app_wr_data[7:0];
      if (app_wr_be[1]) mrl[15:8] <= app_wr_data[15:8];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)              max_ibi_payload <= MAXIBI_DEFAULT;
    else if (whole_reset)    max_ibi_payload <= MAXIBI_DEFAULT;
    else if (ccc_set_maxibi) max_ibi_payload <= ccc_maxibi_val; // SETMRL 3rd byte
    else if (app_wr_en && app_wr_idx == IDX_MRL && app_wr_be[2])
      max_ibi_payload <= app_wr_data[23:16];
  end

  // ==========================================================================
  // Event enable ibi_en (ENEC/DISEC EVT_ENINT) - reset/whole-reset = 1 (IBI-EN-02)
  //   DISEC (clear) has priority over ENEC (set) if both pulse together.
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n)               ibi_en <= 1'b1;
    else if (whole_reset)     ibi_en <= 1'b1;                  // config -> default
    else if (ccc_ibi_en_clr)  ibi_en <= 1'b0;                 // DISEC EVT_ENINT
    else if (ccc_ibi_en_set)  ibi_en <= 1'b1;                 // ENEC  EVT_ENINT
  end

  // ==========================================================================
  // Sticky protocol-error (GETSTATUS[5]) - read-to-clear, SET WINS (critique B-8)
  //   System reset (rst_n) dominates; otherwise proto_err_set is the highest-
  //   priority writer so a protocol-error event always lands and WINS over a
  //   simultaneous read-to-clear (E10 set / set-wins hold for rst_n high).
  // ==========================================================================
  always_ff @(posedge clk) begin
    if      (!rst_n)        proto_err_seen <= 1'b0;            // system reset dominates
    else if (proto_err_set) proto_err_seen <= 1'b1;            // CCC-STAT-02 set (set-wins)
    else if (whole_reset)   proto_err_seen <= 1'b0;
    else if (getstatus_rd)  proto_err_seen <= 1'b0;            // read-to-clear
  end

  // ==========================================================================
  // GETSTATUS Format-1 assembler (CCC-STAT-01) - vendor MSB strapped via app port.
  // ==========================================================================
  logic [7:0] vendor_msb;
  always_ff @(posedge clk) begin
    if (!rst_n)           vendor_msb <= 8'h00;
    else if (whole_reset) vendor_msb <= 8'h00;
    else if (app_wr_en && app_wr_idx == IDX_GSCFG && app_wr_be[0])
      vendor_msb <= app_wr_data[7:0];
  end

  //  [15:8]=vendor MSB  [7:6]=activity mode  [5]=proto err  [4]=rsv0  [3:0]=pending irq
  assign getstatus_word = { vendor_msb,        // [15:8]
                            activity_mode,     // [7:6]  STAT_ACTMODE_LSB=6
                            proto_err_seen,    // [5]    STAT_PROTOERR=5
                            1'b0,              // [4]    reserved
                            pending_irq };     // [3:0]  STAT_PENDINT_LSB=0

  // ==========================================================================
  // RSTACT reset-action + escalation arming (always-on retention sub-domain).
  //   reset_action : cleared on a plain START (RST-CFG-02, NOT on Sr), loaded by a
  //                  supported RSTACT defining byte; survives a peripheral reset.
  //   escalation_armed : set when a peripheral reset fires (default escalation,
  //                  RST-ESC-02/03), disarmed by an intervening RSTACT or GETSTATUS
  //                  (RST-ESC-04); survives a peripheral reset; cleared on whole reset.
  //   last_reset_was_whole : status of the last reset action.
  //   Priority for reset_action: rst_n > whole_reset > start_clr > RSTACT decode.
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n)            reset_action <= 2'd0;
    else if (whole_reset)  reset_action <= 2'd0;
    else if (start_clr)    reset_action <= 2'd0;               // RST-CFG-02 plain START
    else if (ccc_set_rstact) begin
      case (ccc_rstact_val)
        i3c_pkg::RSTACT_NO_RESET   : reset_action <= 2'd0;     // 0x00 No Reset
        i3c_pkg::RSTACT_PERIPHERAL : reset_action <= 2'd1;     // 0x01 Peripheral
        8'h02                      : reset_action <= 2'd2;     // 0x02 Whole Target
        default                    : reset_action <= reset_action; // unsupported -> keep
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                              escalation_armed <= 1'b0;
    else if (whole_reset)                    escalation_armed <= 1'b0;
    else if (ccc_set_rstact || getstatus_rd) escalation_armed <= 1'b0; // RST-ESC-04 disarm
    else if (periph_reset)                   escalation_armed <= 1'b1; // RST-ESC-02/03 arm
  end

  always_ff @(posedge clk) begin
    if (!rst_n)            last_reset_was_whole <= 1'b0;
    else if (whole_reset)  last_reset_was_whole <= 1'b1;
    else if (periph_reset) last_reset_was_whole <= 1'b0;
  end

  // ==========================================================================
  // Avalon app read mux (RF-owned indices 5..9, 15). RO-mapped fields read 0.
  // ==========================================================================
  always_comb begin
    unique case (app_rd_idx)
      IDX_PID_LOW  : app_rd_data = pid[31:0];
      IDX_PID_HIGH : app_rd_data = {16'h0, pid[47:32]};
      IDX_IDENT    : app_rd_data = {8'h0, 8'h0, dcr, bcr};        // static_addr field = 0
      IDX_MWL      : app_rd_data = {16'h0, mwl};
      IDX_MRL      : app_rd_data = {8'h0, max_ibi_payload, mrl};
      IDX_GSCFG    : app_rd_data = {18'h0, pending_irq, activity_mode, vendor_msb};
      IDX_CAPS     : app_rd_data = getcaps;
      IDX_RESET    : app_rd_data = {28'h0, last_reset_was_whole, escalation_armed, reset_action};
      default      : app_rd_data = 32'h0;
    endcase
  end

`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Elaboration sanity: defaults must be in range so the reset value is legal.
  initial begin
    a_mwl_default_ok : assert (MWL_DEFAULT <= MWL_MAX);
    a_mrl_default_ok : assert (MRL_DEFAULT <= MRL_MAX);
  end

  // ==========================================================================
  // ID1/ID2/ID3 (KEEP) - identity field legality + read-only constants
  // ==========================================================================
  always_ff @(posedge clk) if (rst_n) begin
    id_bcr_const : assert (bcr == BCR);
    id_bcr_role  : assert (bcr[7:6] == 2'b00);                 // ID-BCR-03 I3C Target
    id_bcr_nores : assert (bcr[7:6] != 2'b10 && bcr[7:6] != 2'b11);
    id_bcr_adv   : assert (bcr[5] == 1'b0 && bcr[4] == 1'b0);  // ID-BCR-07 no adv/virtual
    id_bcr_off   : assert (bcr[3] == 1'b0);                    // ID-BCR-06 always responds
    id_dcr_const : assert (dcr == DCR);
    id_pid_mfg   : assert (pid[47:33] == MFG_ID);             // ID-PID-03 never randomized
    id_pid_type  : assert (pid[32] == PID_TYPE);
  end

  // ID1/ID2/ID3 stability: identity never changes after reset (read-only from bus).
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    id_bcr_stable : assert (bcr == $past(bcr));
    id_dcr_stable : assert (dcr == $past(dcr));
    id_pid_stable : assert (pid == $past(pid));
  end

  // ==========================================================================
  // V4 - read-only registers stable under ANY Avalon / CCC write.
  //   bcr/dcr/pid (covered above) + getcaps are pure strap constants; they must
  //   never move regardless of app_wr_* or ccc_* activity.
  // ==========================================================================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    v4_getcaps : assert (getcaps == $past(getcaps));
    v4_caps_const : assert (getcaps == {i3c_pkg::GETCAP4_CONST, GETCAP3,
                                        i3c_pkg::GETCAP2_CONST, i3c_pkg::GETCAP1_CONST});
  end
  // GETCAPS constant fields (C12 subset).
  always_ff @(posedge clk) if (rst_n) begin
    g_cap1_zero : assert (getcaps[7:0]   == 8'h00);            // R-GCAP1-HDR0
    g_cap2_ver  : assert (getcaps[11:8]  == 4'h2);             // R-GCAP2-VER (v1.2)
    g_cap2_hi   : assert (getcaps[15:12] == 4'h0);             // R-GCAP2-ZEROS
    g_cap4_zero : assert (getcaps[31:24] == 8'h00);            // R-GCAP4-HDR0
  end

  // ==========================================================================
  // C3 - SETMWL/SETMRL commit & out-of-range leave-unchanged (R-MWL/MRL-1/3).
  // ==========================================================================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    if ($past(ccc_set_mwl) && !$past(whole_reset)) begin
      if ($past(ccc_mwl_val) <= MWL_MAX)
        c3_mwl_commit : assert (mwl == $past(ccc_mwl_val));    // in-range commit
      else
        c3_mwl_keep   : assert (mwl == $past(mwl));            // out-of-range -> unchanged
    end
    if ($past(ccc_set_mrl) && !$past(whole_reset)) begin
      if ($past(ccc_mrl_val) <= MRL_MAX)
        c3_mrl_commit : assert (mrl == $past(ccc_mrl_val));
      else
        c3_mrl_keep   : assert (mrl == $past(mrl));
    end
    // Max IBI payload commit (SETMRL 3rd byte; no range bound, 0=unlimited).
    if ($past(ccc_set_maxibi) && !$past(whole_reset))
      c3_maxibi_commit : assert (max_ibi_payload == $past(ccc_maxibi_val));
  end

  // ==========================================================================
  // E10 - proto_err sticky set-wins + read-to-clear (R-STAT-02, critique B-8).
  // ==========================================================================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // protocol_error_event |=> proto_err  (highest priority -> always lands)
    e10_set     : assert (!$past(proto_err_set) || proto_err_seen);
    // getstatus_read_complete (and no concurrent set) |=> !proto_err (read-to-clear)
    e10_clear   : assert (!($past(getstatus_rd) && !$past(proto_err_set)) || !proto_err_seen);
    // both set & read in the same cycle -> SET WINS (stays set)
    e10_setwins : assert (!($past(proto_err_set) && $past(getstatus_rd)) || proto_err_seen);
    // sticky hold: set, no clear, no whole-reset -> remains set
    e10_hold    : assert (!($past(proto_err_seen) && !$past(getstatus_rd)
                            && !$past(whole_reset)) || proto_err_seen);
  end

  // ==========================================================================
  // C6 (bonus) - ENEC/DISEC event-enable; reset/whole-reset default = 1.
  // ==========================================================================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    c6_disec : assert (!($past(ccc_ibi_en_clr) && !$past(whole_reset)) || !ibi_en);
    c6_enec  : assert (!($past(ccc_ibi_en_set) && !$past(ccc_ibi_en_clr)) || ibi_en);
  end
  // reset default value (IBI-EN-02): one cycle out of reset, ibi_en==1.
  always_ff @(posedge clk) if (f_past_valid && !$past(rst_n)) begin
    rst_ibi_en  : assert (ibi_en == 1'b1);
    rst_proto   : assert (proto_err_seen == 1'b0);
    rst_raction : assert (reset_action == 2'd0);
    rst_armed   : assert (escalation_armed == 1'b0);
  end

  // ==========================================================================
  // R4/R5 (bonus) - RSTACT decode + START-clears-action; escalation arming.
  // ==========================================================================
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // R4: plain START clears the configured action (whole_reset also -> 0).
    r4_start_clr : assert (!$past(start_clr) || reset_action == 2'd0);
    // RSTACT defining-byte decode (when no higher-priority clear).
    if ($past(ccc_set_rstact) && !$past(whole_reset) && !$past(start_clr)) begin
      case ($past(ccc_rstact_val))
        i3c_pkg::RSTACT_NO_RESET   : r5_rstact_none  : assert (reset_action == 2'd0);
        i3c_pkg::RSTACT_PERIPHERAL : r5_rstact_per   : assert (reset_action == 2'd1);
        8'h02                      : r5_rstact_whole : assert (reset_action == 2'd2);
        default                    : r5_rstact_keep  : assert (reset_action == $past(reset_action));
      endcase
    end
    // Escalation arming (RST-ESC-02/03/04) - always-on retention.
    arm_disarm : assert (!($past(ccc_set_rstact) || $past(getstatus_rd)) || !escalation_armed);
    arm_whole  : assert (!$past(whole_reset) || !escalation_armed);
    arm_set    : assert (!($past(periph_reset) && !$past(whole_reset)
                           && !$past(ccc_set_rstact) && !$past(getstatus_rd)) || escalation_armed);
    // last_reset_was_whole follows the last reset event.
    lrw_whole  : assert (!$past(whole_reset)                       || last_reset_was_whole);
    lrw_periph : assert (!($past(periph_reset) && !$past(whole_reset)) || !last_reset_was_whole);
  end

  // ==========================================================================
  // GETSTATUS Format-1 field placement (CCC-STAT-01/02/03).
  // ==========================================================================
  always_ff @(posedge clk) if (rst_n) begin
    gs_pend  : assert (getstatus_word[3:0]  == pending_irq);
    gs_rsv   : assert (getstatus_word[4]    == 1'b0);
    gs_proto : assert (getstatus_word[5]    == proto_err_seen);
    gs_act   : assert (getstatus_word[7:6]  == activity_mode);
  end

  // ==========================================================================
  // Reachability covers.
  // ==========================================================================
  always_ff @(posedge clk) if (rst_n) begin
    c_mwl_commit  : cover (f_past_valid && $past(ccc_set_mwl) && ($past(ccc_mwl_val) <= MWL_MAX)
                           && (mwl == $past(ccc_mwl_val)));
    c_mwl_oor     : cover (f_past_valid && $past(ccc_set_mwl) && ($past(ccc_mwl_val) > MWL_MAX)
                           && (mwl == $past(mwl)));
    c_mrl_commit  : cover (f_past_valid && $past(ccc_set_mrl) && ($past(ccc_mrl_val) <= MRL_MAX));
    c_mrl_oor     : cover (f_past_valid && $past(ccc_set_mrl) && ($past(ccc_mrl_val) > MRL_MAX));
    c_maxibi      : cover (f_past_valid && $past(ccc_set_maxibi)
                           && (max_ibi_payload == $past(ccc_maxibi_val)));
    c_proto_set   : cover (proto_err_seen);
    c_proto_clr   : cover (f_past_valid && $past(proto_err_seen) && !proto_err_seen);
    c_proto_win   : cover (f_past_valid && $past(proto_err_set) && $past(getstatus_rd) && proto_err_seen);
    c_ibi_dis     : cover (!ibi_en);
    c_ibi_en      : cover (f_past_valid && $past(!ibi_en) && ibi_en);
    c_rstact_per  : cover (reset_action == 2'd1);
    c_rstact_whole: cover (reset_action == 2'd2);
    c_armed       : cover (escalation_armed);
    c_whole_last  : cover (last_reset_was_whole);
    c_trp         : cover (trp_trigger);
    c_app_mwl     : cover (f_past_valid && $past(app_wr_en) && ($past(app_wr_idx) == IDX_MWL));
  end
`endif

endmodule
`endif
