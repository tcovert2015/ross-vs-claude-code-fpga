// ============================================================================
// i3c_ccc.sv  -  CCC decode + handlers (architecture §1.8, Slice 5)
//
// Classifies Broadcast (code[7]=0) vs Direct (code[7]=1) Common Command Codes,
// maintains a supported-code + supported-defining-byte allow-list -> directed
// ACK/NACK (umbrella CCC-NACK-01), decodes the required v1 CCC set, tracks a
// sticky Defining Byte across the Direct segments of one CCC, and serializes
// GET* responses (FIFO-bypassed per B-1).
//
// Frame model (idealized-edge, architecture §2.4): the protocol FSM ACKs the
// 7E/W broadcast header; this block sees byte boundaries (byte_done) tagged by
// phase (PH_ADDR vs PH_DATA), the address matches (match_7e/match_da) and the
// captured byte (rx_byte). It runs its own small position tracker:
//   * a 7E header byte (seg_kind=HDR): first DATA byte = command code, second =
//     Defining Byte (DB-bearing codes) or broadcast operand/data;
//   * a Repeated-START then directed address (seg_kind=DIR): the directed write
//     operands / read response of the latched Direct CCC.
//
// Ports are EXACTLY per docs/interfaces.md §2.8.  Formal: docs/architecture.md
// §4.F C1/C6/C10/C12, §4.D K6/K7, critique B-2 (wildcard default case).
// ============================================================================
`ifndef I3C_CCC_SV
`define I3C_CCC_SV
`include "i3c_pkg.sv"
import i3c_pkg::*;

module i3c_ccc #(
  parameter logic STATIC_ADDR_EN = 1'b0     // SETDASA/SETAASA support (off in v1)
) (
  input  logic        clk,
  input  logic        rst_n,
  // bus conditions (1-cycle strobes, front-end)
  input  logic        start_stb,
  input  logic        rstart_stb,
  input  logic        stop_stb,
  // SCL edge strobes (unused in the idealized-edge decode; kept per contract)
  input  logic        scl_rising,
  input  logic        scl_falling,
  // byte stream (bit engine)
  input  logic [7:0]  rx_byte,
  input  logic        byte_done,
  input  logic [3:0]  bit_cnt,
  // framing
  input  logic [1:0]  phase,        // i3c_pkg::phase_e
  input  logic        ninth_slot,
  input  logic        ack_slot,
  // address match / frame class (protocol FSM)
  input  logic        match_7e,
  input  logic        match_da,
  input  logic        is_broadcast,
  input  logic        is_read,
  input  logic        da_valid,
  // identity / config (regfile) for GET*
  input  logic [7:0]  bcr,
  input  logic [7:0]  dcr,
  input  logic [47:0] pid,
  input  logic [15:0] mwl,
  input  logic [15:0] mrl,
  input  logic [7:0]  max_ibi_payload,
  input  logic [15:0] getstatus_word,
  input  logic [31:0] getcaps,
  // ---- outputs --------------------------------------------------------------
  output logic [7:0]  ccc_code,
  output logic        ccc_is_direct,
  output logic        ccc_supported,
  output logic        ccc_ack,
  output logic        ccc_getstatus_seg,
  output logic        ccc_resp_valid,
  output logic [7:0]  ccc_resp_byte,
  output logic        ccc_resp_last,
  output logic        enthdr_seen,
  output logic        entdaa_start,
  output logic        entdaa_active,
  output logic        rstdaa,
  output logic        setdasa_load,
  output logic        setaasa_load,
  output logic        setnewda_load,
  output logic [6:0]  load_addr,
  output logic        ccc_set_mwl,
  output logic [15:0] ccc_mwl_val,
  output logic        ccc_set_mrl,
  output logic [15:0] ccc_mrl_val,
  output logic        ccc_set_maxibi,
  output logic [7:0]  ccc_maxibi_val,
  output logic        ccc_ibi_en_set,
  output logic        ccc_ibi_en_clr,
  output logic        ccc_set_rstact,
  output logic [7:0]  ccc_rstact_val,
  output logic        getstatus_rd,
  output logic        ccc_code_parity_err,
  output logic        ccc_illegal_format,
  output logic        ccc_event
);

  // ---- segment-kind tracker (what the last address byte selected) -----------
  localparam logic [1:0] SK_NONE  = 2'd0;
  localparam logic [1:0] SK_HDR   = 2'd1;   // 7E header -> command code follows
  localparam logic [1:0] SK_DIR   = 2'd2;   // directed (DA-matched) segment
  localparam logic [1:0] SK_OTHER = 2'd3;   // some other address (not us / not 7E)

  // ---- frame state ----------------------------------------------------------
  logic [7:0] code_q;            logic code_valid;
  logic [7:0] def_byte_q;        logic def_byte_valid;
  logic       entdaa_active_q;
  logic [1:0] seg_kind;
  logic [2:0] dcnt;              // DATA-phase byte index since last address byte
  logic       in_read_seg;       // directed GET response segment active
  logic [2:0] resp_idx;          // response byte index
  logic [7:0] op0;               // captured operand byte 0 (SET* value MSB)

  // ---- byte-boundary classification ----------------------------------------
  wire addr_done = byte_done && (phase == PH_ADDR);
  wire data_done = byte_done && (phase == PH_DATA);
  wire hdr_open  = addr_done && match_7e;

  // Falling edge of a DATA-phase ninth slot = a GET RESPONSE byte's T-bit just ended.
  // This is the read-byte boundary where the FSM loads the next response byte
  // (FINDING-SIM-7). Gated to PH_DATA so the directed-address ACK's ninth slot (the
  // first-byte load point, S_ACK->S_READ) does NOT advance resp_idx / the look-ahead.
  logic ninth_data_q;
  always_ff @(posedge clk) ninth_data_q <= rst_n && ninth_slot && (phase == PH_DATA);
  wire  ninth_fell_c = ninth_data_q && !ninth_slot;

  // ---- code-class helpers ---------------------------------------------------
  function automatic logic is_db_code(input logic [7:0] c);
    // codes carrying a Defining Byte right after the command code
    is_db_code = (c==CCC_RSTACT_B) || (c==CCC_RSTACT_D) || (c==CCC_GETSTATUS_D) ||
                 (c==CCC_GETCAPS_D) || (c==CCC_GETMXDS_D);
  endfunction

  function automatic logic supported_direct(input logic [7:0] c,
                                            input logic       dbv,
                                            input logic [7:0] db);
    // Direct-CCC allow-list (everything else -> NACK : K6 / B-2 wildcard).
    case (c)
      CCC_ENEC_D, CCC_DISEC_D, CCC_SETNEWDA_D,
      CCC_SETMWL_D, CCC_SETMRL_D,
      CCC_GETMWL_D, CCC_GETMRL_D,
      CCC_GETPID_D, CCC_GETBCR_D, CCC_GETDCR_D: supported_direct = 1'b1;
      CCC_SETDASA_D:  supported_direct = STATIC_ADDR_EN;
      CCC_GETSTATUS_D:supported_direct = !dbv;                 // Format-1 only
      CCC_GETCAPS_D:  supported_direct = !dbv;                 // Format-1 only
      CCC_RSTACT_D:   supported_direct = dbv && ((db==RSTACT_NO_RESET) ||
                                                 (db==RSTACT_PERIPHERAL));
      default:        supported_direct = 1'b0;
    endcase
  endfunction

  wire code_has_db = is_db_code(code_q);
  wire is_get_code = (code_q==CCC_GETMWL_D) || (code_q==CCC_GETMRL_D) ||
                     (code_q==CCC_GETPID_D) || (code_q==CCC_GETBCR_D) ||
                     (code_q==CCC_GETDCR_D) || (code_q==CCC_GETSTATUS_D) ||
                     (code_q==CCC_GETCAPS_D) || (code_q==CCC_GETMXDS_D);
  wire is_setmwl   = (code_q==CCC_SETMWL_B) || (code_q==CCC_SETMWL_D);
  wire is_setmrl   = (code_q==CCC_SETMRL_B) || (code_q==CCC_SETMRL_D);

  // ---- capture events -------------------------------------------------------
  wire code_capture = data_done && (seg_kind==SK_HDR) && (dcnt==3'd0);
  wire db_capture   = data_done && (seg_kind==SK_HDR) && (dcnt==3'd1) && code_has_db;

  // value bytes: broadcast operands live in the 7E header after the code;
  // direct operands live in the directed (write) segment.
  wire val_hdr  = data_done && (seg_kind==SK_HDR) && !code_q[7] &&
                  (dcnt>=3'd1) && !code_has_db;
  wire val_dir  = data_done && (seg_kind==SK_DIR) &&  code_q[7] && !is_read;
  wire value_stb= val_hdr || val_dir;
  wire [2:0] vidx = code_q[7] ? dcnt : (dcnt - 3'd1);

  // ENEC/DISEC events byte (broadcast: header dcnt1; direct: seg dcnt0).
  wire ev_bcast  = data_done && (seg_kind==SK_HDR) && (dcnt==3'd1) &&
                   ((code_q==CCC_ENEC_B) || (code_q==CCC_DISEC_B));
  wire ev_direct = data_done && (seg_kind==SK_DIR) && (dcnt==3'd0) && !is_read &&
                   ((code_q==CCC_ENEC_D) || (code_q==CCC_DISEC_D));
  wire events_now= ev_bcast || ev_direct;
  wire is_enec   = (code_q==CCC_ENEC_B)  || (code_q==CCC_ENEC_D);
  wire is_disec  = (code_q==CCC_DISEC_B) || (code_q==CCC_DISEC_D);

  // ==========================================================================
  // Sequential frame tracker
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      code_q <= 8'h00; code_valid <= 1'b0;
      def_byte_q <= 8'h00; def_byte_valid <= 1'b0;
      entdaa_active_q <= 1'b0;
      seg_kind <= SK_NONE; dcnt <= 3'd0;
      in_read_seg <= 1'b0; resp_idx <= 3'd0; op0 <= 8'h00;
    end else if (start_stb || stop_stb) begin
      // clean frame boundary -> drop all per-frame state
      code_valid <= 1'b0; def_byte_valid <= 1'b0; entdaa_active_q <= 1'b0;
      seg_kind <= SK_NONE; dcnt <= 3'd0; in_read_seg <= 1'b0; resp_idx <= 3'd0;
    end else if (rstart_stb) begin
      // Sr: keep code / sticky DB / entdaa across segments (CCC-DEFB-STICKY-01)
      seg_kind <= SK_NONE; dcnt <= 3'd0; in_read_seg <= 1'b0;
    end else begin
      // resp_idx advances after each completed read byte (its T/ACK bit, ninth_fell),
      // so at the load point (ninth_fell) it still names the byte just sent and the
      // FSM/resp_sel look-ahead picks the NEXT byte (FINDING-SIM-7). Reset on a new
      // segment's address byte.
      if (addr_done)                          resp_idx <= 3'd0;
      else if (ninth_fell_c && in_read_seg &&
               (resp_idx != 3'd7))            resp_idx <= resp_idx + 3'd1;

      if (addr_done) begin
        dcnt <= 3'd0; in_read_seg <= 1'b0;
        if (match_7e) begin
          seg_kind <= SK_HDR; code_valid <= 1'b0; def_byte_valid <= 1'b0;
        end else if (match_da) begin
          seg_kind <= SK_DIR;
          if (code_valid && code_q[7] && is_get_code && is_read &&
              supported_direct(code_q, def_byte_valid, def_byte_q)) begin
            in_read_seg <= 1'b1;
          end
        end else begin
          seg_kind <= SK_OTHER;
        end
      end else if (data_done) begin
        dcnt <= (dcnt==3'd7) ? dcnt : (dcnt + 3'd1);
        if (code_capture) begin
          code_q <= rx_byte; code_valid <= 1'b1;
          if (rx_byte==CCC_ENTDAA_B) entdaa_active_q <= 1'b1;
        end
        if (db_capture) begin def_byte_q <= rx_byte; def_byte_valid <= 1'b1; end
        if (value_stb && (is_setmwl || is_setmrl) && (vidx==3'd0)) op0 <= rx_byte;
      end
    end
  end

  // ==========================================================================
  // Combinational outputs
  // ==========================================================================
  assign ccc_code      = code_q;
  assign ccc_is_direct = code_q[7];                              // C1
  assign entdaa_active = entdaa_active_q;

  assign ccc_supported = !code_valid ? 1'b1 :
                         (code_q[7] ? supported_direct(code_q, def_byte_valid, def_byte_q)
                                    : 1'b1);

  wire dir_ok = (is_read == is_get_code);
  assign ccc_ack = code_valid && code_q[7] && match_da && da_valid &&
                   ccc_supported && dir_ok;                      // K6 / K7 / B-2

  assign ccc_getstatus_seg = code_valid && code_q[7] && match_da && da_valid &&
                             !def_byte_valid &&
                             ((code_q==CCC_GETSTATUS_D) || (code_q==CCC_GETPID_D) ||
                              (code_q==CCC_GETBCR_D)   || (code_q==CCC_GETDCR_D) ||
                              (code_q==CCC_GETCAPS_D));

  assign ccc_illegal_format = code_valid && code_q[7] && match_da && da_valid &&
                              ccc_supported && !dir_ok;          // TE5 dir-mismatch
  assign ccc_code_parity_err = 1'b0;  // no T-bit/parity wired to CCC (see open issues)

  // ENEC/DISEC -> ibi_en strobes (C6)
  assign ccc_ibi_en_set = events_now && is_enec  && rx_byte[EVT_ENINT];
  assign ccc_ibi_en_clr = events_now && is_disec && rx_byte[EVT_ENINT];

  // SET MWL / MRL commits
  assign ccc_set_mwl    = value_stb && is_setmwl && (vidx==3'd1);
  assign ccc_mwl_val    = {op0, rx_byte};
  assign ccc_set_mrl    = value_stb && is_setmrl && (vidx==3'd1);
  assign ccc_mrl_val    = {op0, rx_byte};
  assign ccc_set_maxibi = value_stb && is_setmrl && (vidx==3'd2);
  assign ccc_maxibi_val = rx_byte;

  // SETNEWDA / SETDASA / SETAASA
  assign setnewda_load  = val_dir && (code_q==CCC_SETNEWDA_D) && (vidx==3'd0);
  assign setdasa_load   = val_dir && (code_q==CCC_SETDASA_D) && (vidx==3'd0) && STATIC_ADDR_EN;
  assign setaasa_load   = code_capture && (rx_byte==CCC_SETAASA_B) && STATIC_ADDR_EN;
  assign load_addr      = rx_byte[7:1];

  // RSTACT defining-byte commit (broadcast at DB; direct at directed address)
  assign ccc_set_rstact = (db_capture && (code_q==CCC_RSTACT_B) &&
                           ((rx_byte==RSTACT_NO_RESET) || (rx_byte==RSTACT_PERIPHERAL)))
                       || (addr_done && match_da && code_valid &&
                           (code_q==CCC_RSTACT_D) && ccc_supported);
  assign ccc_rstact_val = (code_q==CCC_RSTACT_B) ? rx_byte : def_byte_q;

  // DAA strobes
  assign rstdaa       = stop_stb && code_valid && (code_q==CCC_RSTDAA_B);
  assign entdaa_start = code_capture && (rx_byte==CCC_ENTDAA_B) && !da_valid;

  // HDR quiesce
  assign enthdr_seen  = code_valid && (code_q>=CCC_ENTHDR0_B) && (code_q<=CCC_ENTHDR7_B);

  // GETSTATUS read-to-clear
  assign getstatus_rd = in_read_seg && (code_q==CCC_GETSTATUS_D) && (stop_stb || rstart_stb);

  // INT event
  assign ccc_event = ccc_set_mwl || ccc_set_mrl || ccc_set_maxibi || ccc_set_rstact ||
                     ccc_ibi_en_set || ccc_ibi_en_clr ||
                     setnewda_load || setdasa_load || setaasa_load;

  // ---- GET* response serializer (FIFO-bypassed) -----------------------------
  // FINDING-SIM-7 fix: the FSM loads the NEXT response byte on byte_done, but resp_idx
  // (registered) only advances on the next cycle -- so a load at byte_done would sample
  // the stale (current) byte. Select the response byte with a 1-ahead index on the
  // load cycle (data_done while in a read segment) so the value being captured is the
  // next byte. Termination (ccc_resp_last) stays on resp_idx: it answers "is the byte
  // just finished the last one?".
  wire [2:0] resp_sel = (ninth_fell_c && in_read_seg && (resp_idx != 3'd7)) ?
                        (resp_idx + 3'd1) : resp_idx;
  assign ccc_resp_valid = in_read_seg;
  always_comb begin
    ccc_resp_byte = 8'h00;
    ccc_resp_last = 1'b0;
    case (code_q)
      CCC_GETPID_D: begin
        case (resp_sel)
          3'd0: ccc_resp_byte = pid[47:40];
          3'd1: ccc_resp_byte = pid[39:32];
          3'd2: ccc_resp_byte = pid[31:24];
          3'd3: ccc_resp_byte = pid[23:16];
          3'd4: ccc_resp_byte = pid[15:8];
          default: ccc_resp_byte = pid[7:0];
        endcase
        ccc_resp_last = (resp_idx >= 3'd5);
      end
      CCC_GETBCR_D: begin ccc_resp_byte = bcr; ccc_resp_last = 1'b1; end
      CCC_GETDCR_D: begin ccc_resp_byte = dcr; ccc_resp_last = 1'b1; end
      CCC_GETMWL_D: begin
        ccc_resp_byte = (resp_sel==3'd0) ? mwl[15:8] : mwl[7:0];
        ccc_resp_last = (resp_idx >= 3'd1);
      end
      CCC_GETMRL_D: begin
        case (resp_sel)
          3'd0:    ccc_resp_byte = mrl[15:8];
          3'd1:    ccc_resp_byte = mrl[7:0];
          default: ccc_resp_byte = max_ibi_payload;
        endcase
        ccc_resp_last = bcr[2] ? (resp_idx >= 3'd2) : (resp_idx >= 3'd1);
      end
      CCC_GETSTATUS_D: begin
        ccc_resp_byte = (resp_sel==3'd0) ? getstatus_word[15:8] : getstatus_word[7:0];
        ccc_resp_last = (resp_idx >= 3'd1);
      end
      CCC_GETCAPS_D: begin
        case (resp_sel)
          3'd0:    ccc_resp_byte = getcaps[7:0];     // GETCAP1
          3'd1:    ccc_resp_byte = getcaps[15:8];    // GETCAP2
          3'd2:    ccc_resp_byte = getcaps[23:16];   // GETCAP3
          default: ccc_resp_byte = getcaps[31:24];   // GETCAP4
        endcase
        ccc_resp_last = (resp_idx >= 3'd3);
      end
      default: begin ccc_resp_byte = 8'h00; ccc_resp_last = 1'b1; end
    endcase
  end

  // ==========================================================================
  // Formal properties (Slice 5: §4.F C1/C6/C10/C12, §4.D K6/K7, critique B-2)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- environment assumptions (assume-ledger; discharged at integration) ---
  always_ff @(posedge clk) begin
    // front-end: at most one bus condition per cycle (proven in i3c_bus_frontend)
    a_bus_onehot : assume ($onehot0({start_stb, rstart_stb, stop_stb}));
    // a byte boundary and a bus condition do not coincide (distinct events)
    a_no_byte_bus: assume (!(byte_done && (start_stb || rstart_stb || stop_stb)));
    // address matcher: 7E and DA are mutually exclusive; match_da => da_valid
    a_addr_excl  : assume (!(match_7e && match_da));
    a_da_def     : assume (!match_da || da_valid);
    // phase encoding is one of PH_IDLE/PH_ADDR/PH_DATA (no 2'd3)
    a_phase_enc  : assume (phase != 2'd3);
    // GETCAPS constant fields (regfile-owned constants, ledgered for C12)
    a_caps_b1    : assume (getcaps[7:0]   == GETCAP1_CONST);
    a_caps_b2    : assume (getcaps[15:8]  == GETCAP2_CONST);
    a_caps_b4    : assume (getcaps[31:24] == GETCAP4_CONST);
    a_caps_b3r   : assume (getcaps[23] == 1'b0 && getcaps[18:16] == 3'b000);
  end

  // ---- C1 : Broadcast/Direct classification by bit7 -------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c1_classify : assert (ccc_is_direct == ccc_code[7]);
  end

  // ---- strengthening invariants (reachable-state predicates for k-induction)-
  // Entering a 7E header (seg_kind=HDR, dcnt=0) always clears code_valid, so a
  // fresh command code is never captured on top of a still-valid latched code.
  always_ff @(posedge clk) if (rst_n) begin
    inv_hdr0 : assert (!(code_valid && (seg_kind==SK_HDR) && (dcnt==3'd0)));
  end

  // ---- K6 : known-unsupported Direct CCC at directed addr -> NACK ------------
  // ---- B-2 (direct half) : wildcard unknown Direct -> NACK -------------------
  always_ff @(posedge clk) if (rst_n) begin
    k6_unsup_nack : assert (!(code_valid && code_q[7] && match_da && da_valid &&
                              !ccc_supported) || !ccc_ack);
    // representative deprecated / out-of-scope Direct codes always NACK
    c2_oos_nack   : assert (!(code_valid && match_da && da_valid &&
                              ((code_q==CCC_RSTDAA_D)  || (code_q==CCC_GETACCCR_D) ||
                               (code_q==CCC_SETBRGTGT_D)|| (code_q==CCC_SETROUTE_D) ||
                               (code_q==CCC_GETMXDS_D) || (code_q==CCC_SETGRPA_D)  ||
                               (code_q==CCC_RSTGRPA_D) || (code_q==CCC_RESERVED_FF)))
                            || !ccc_ack);
    // ccc_ack only ever for a supported, correctly-directed Direct CCC at our DA
    k8_ack_sane   : assert (!ccc_ack || (code_q[7] && match_da && da_valid &&
                                         ccc_supported && dir_ok));
  end

  // ---- K7 : GETSTATUS (Format-1) is always answerable ------------------------
  always_ff @(posedge clk) if (rst_n) begin
    k7_getstatus : assert (!(code_valid && (code_q==CCC_GETSTATUS_D) && !def_byte_valid &&
                             match_da && da_valid && is_read)
                           || (ccc_ack && ccc_getstatus_seg));
  end

  // ---- C6 : ENEC/DISEC EVT_ENINT -> ibi_en strobes --------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c6_enec  : assert (!(events_now && is_enec  && rx_byte[EVT_ENINT]) ||
                       (ccc_ibi_en_set && !ccc_ibi_en_clr));
    c6_disec : assert (!(events_now && is_disec && rx_byte[EVT_ENINT]) ||
                       (ccc_ibi_en_clr && !ccc_ibi_en_set));
    c6_excl  : assert (!(ccc_ibi_en_set && ccc_ibi_en_clr));
    c6_only  : assert (!ccc_ibi_en_set || (events_now && is_enec  && rx_byte[EVT_ENINT]));
    c6_only2 : assert (!ccc_ibi_en_clr || (events_now && is_disec && rx_byte[EVT_ENINT]));
  end

  // ---- C10 : sticky Defining Byte (stable until a new Direct code) -----------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    c10_dbq_stable : assert ($past(db_capture) || (def_byte_q == $past(def_byte_q)));
    c10_dbv_stable : assert ($past(db_capture) || $past(hdr_open) ||
                             $past(start_stb)  || $past(stop_stb) ||
                             (def_byte_valid == $past(def_byte_valid)));
  end

  // ---- C12 : GETCAPS >=2 bytes + constant fields -----------------------------
  // Checked in the steady response cycle (not the 1-cycle load transition, where the
  // FINDING-SIM-7 look-ahead mux deliberately presents the NEXT byte for capture).
  always_ff @(posedge clk) if (rst_n) begin
    if (in_read_seg && (code_q==CCC_GETCAPS_D) && !ninth_fell_c) begin
      c12_len : assert ((resp_idx != 3'd0) || !ccc_resp_last);           // >=2 bytes
      c12_b1  : assert ((resp_idx != 3'd0) || (ccc_resp_byte == GETCAP1_CONST));
      c12_b2  : assert ((resp_idx != 3'd1) ||
                        (ccc_resp_byte[3:0]==4'b0010 && ccc_resp_byte[7:4]==4'h0));
      c12_b3  : assert ((resp_idx != 3'd2) ||
                        (ccc_resp_byte[7]==1'b0 && ccc_resp_byte[2:0]==3'b000));
      c12_b4  : assert ((resp_idx < 3'd3)  || (ccc_resp_byte == GETCAP4_CONST));
    end
  end

  // ---- B-2 (broadcast half) : unknown Broadcast -> consume, no effect --------
  wire bcast_known = (code_q==CCC_ENEC_B)   || (code_q==CCC_DISEC_B) ||
                     (code_q==CCC_SETMWL_B) || (code_q==CCC_SETMRL_B) ||
                     (code_q==CCC_RSTACT_B) || (code_q==CCC_RSTDAA_B) ||
                     (code_q==CCC_ENTDAA_B) || (code_q==CCC_SETAASA_B);
  always_ff @(posedge clk) if (rst_n) begin
    if (code_valid && !code_q[7] && !bcast_known) begin
      b2_no_commit : assert (!ccc_set_mwl && !ccc_set_mrl && !ccc_set_maxibi &&
                             !ccc_set_rstact && !ccc_ibi_en_set && !ccc_ibi_en_clr &&
                             !setnewda_load && !setdasa_load && !setaasa_load &&
                             !rstdaa && !entdaa_start);
      b2_no_err    : assert (!ccc_illegal_format && !ccc_code_parity_err);
      b2_no_ack    : assert (!ccc_ack);   // broadcast is never per-target NACK/ACK'd
    end
  end

  // ---- reachability covers --------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_code_cap   : cover (code_capture);
    c_ack        : cover (ccc_ack);
    c_getstat    : cover (ccc_getstatus_seg);
    c_caps_resp  : cover (in_read_seg && (code_q==CCC_GETCAPS_D) && (resp_idx==3'd1));
    c_pid_resp   : cover (in_read_seg && (code_q==CCC_GETPID_D)  && (resp_idx==3'd2));
    c_enec_set   : cover (ccc_ibi_en_set);
    c_disec_clr  : cover (ccc_ibi_en_clr);
    c_db_sticky  : cover (def_byte_valid && (seg_kind==SK_DIR));   // DB survived Sr+DA
    c_setmwl     : cover (ccc_set_mwl);
    c_setrstact  : cover (ccc_set_rstact);
    c_entdaa     : cover (entdaa_start);
    c_rstdaa     : cover (rstdaa);
    c_enthdr     : cover (enthdr_seen);
    c_unsup_nack : cover (code_valid && code_q[7] && match_da && da_valid && !ccc_supported);
  end
`endif

endmodule
`endif
