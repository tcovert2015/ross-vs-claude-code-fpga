// ============================================================================
// i3c_framer.sv  -  9th-bit (T/ACK) framing, write parity, read T-bit (arch §1.4)
//
// Tracks the 8 data bits + the 9th "T/ACK" slot of every SDR byte and decides
// the 9th-bit role from the frame phase (architecture §1.4, R-FMT-02):
//   * phase == PH_ADDR -> 9th bit is an ACK/NACK slot (driven by i3c_protocol_fsm
//     on SDA_ACK; the framer only flags the slot, it never drives it).
//   * phase == PH_DATA -> 9th bit is a T-bit:
//       - Controller WRITE  : the controller drives an odd-parity T-bit; the
//         framer SAMPLES it and checks parity (expected_t = ~(^rx_byte)); a
//         mismatch raises parity_err (TE2 source). The Target never drives any
//         bit of a written word (WR-NODRIVE-01).
//       - Controller READ   : the Target drives the End-of-Data T-bit on SDA_TBIT
//         (push-pull): T=0 = last byte (drive Low on SCL fall, release on SCL
//         rise), T=1 = continue (drive High on SCL fall, release on SCL rise).
//         After a continue (T=1) the Controller may abort with a Repeated START
//         (Sr) -> read_abort, and the Target must not drive thereafter.
//
// Bit cadence is the idealized-edge model (architecture §2.4): scl_rising is the
// RX sample point, scl_falling the TX drive-update point, byte_done pulses at the
// 8th data-bit sample. The framer requires sda_bit (the bit_engine's sampled SDA)
// to be valid in the same cycle as scl_rising.
//
// SDA-drive contract (interfaces.md §0/§2.2): the framer owns ONLY the read T-bit
// driver pair tbit_oe/tbit_o -> i3c_sda_mux src[SDA_TBIT]. oe=1,o=0 -> drive Low;
// oe=1,o=1 -> drive High (push-pull, legal for the read T-bit); oe=0 -> release.
// ============================================================================
`ifndef I3C_FRAMER_SV
`define I3C_FRAMER_SV
`include "i3c_pkg.sv"

module i3c_framer (
  input  logic        clk,
  input  logic        rst_n,
  // phase / direction (from i3c_protocol_fsm)
  input  logic [1:0]  phase,            // i3c_pkg::phase_e (PH_IDLE/PH_ADDR/PH_DATA)
  input  logic        is_read,          // 1 = Controller reads from Target
  input  logic        more_read_data,   // Target has a further read byte (continue-T = 1)
  // byte / bit cadence (from i3c_bit_engine + front-end)
  input  logic [7:0]  rx_byte,          // assembled byte (write-parity source)
  input  logic        sda_bit,          // sampled SDA at scl_rising (controller's write T-bit)
  input  logic        byte_done,        // 8 data bits received -> enter 9th slot
  input  logic        scl_rising,        // RX sample strobe
  input  logic        scl_falling,       // TX drive-update strobe
  input  logic        rstart_stb,        // Repeated START (read-abort after continue-T)
  // slot flags
  output logic        ninth_slot,       // currently in the 9th (T/ACK) bit slot
  output logic        ack_slot,         // 9th slot is ACK/NACK (phase == PH_ADDR)
  output logic        tbit_slot,        // 9th slot is a T-bit  (phase == PH_DATA)
  // write parity
  output logic        parity_ok,        // write odd-parity matched
  output logic        parity_err,       // write parity mismatch (TE2 source)
  // read T-bit
  output logic        t_drive_val,      // read T-bit value (0 = last, 1 = continue)
  output logic        read_abort,       // Controller aborted read (Sr after continue-T)
  output logic        tbit_oe,          // -> src_oe[SDA_TBIT]
  output logic        tbit_o            // -> src_o[SDA_TBIT]
);

  // ---- phase decode ---------------------------------------------------------
  wire ph_addr = (phase == i3c_pkg::PH_ADDR);
  wire ph_data = (phase == i3c_pkg::PH_DATA);

  // ---- 9th-bit slot tracking -------------------------------------------------
  // byte_done pulses at the 8th-bit sample (a scl_rising); the slot then spans
  // until the NEXT scl_rising (the 9th-bit sample/release), or a frame boundary.
  logic ninth_q;
  always_ff @(posedge clk) begin
    if (!rst_n)                     ninth_q <= 1'b0;
    else if (byte_done)             ninth_q <= 1'b1;   // entering 9th slot (priority)
    else if (scl_rising && ninth_q) ninth_q <= 1'b0;   // 9th bit completes
    else if (rstart_stb)            ninth_q <= 1'b0;    // frame boundary
  end

  assign ninth_slot = ninth_q;
  assign ack_slot   = ninth_q && ph_addr;              // R-FMT-02
  assign tbit_slot  = ninth_q && ph_data;

  // ---- Write odd-parity check (controller-driven T-bit on a write data byte) -
  // Odd parity: total ones incl. T odd -> expected_t = ~(^Data[7:0]) (WR-PAR-01).
  wire       expected_t     = ~(^rx_byte);
  wire       wr_tbit_sample = ninth_q && ph_data && !is_read && scl_rising;
  assign parity_err = wr_tbit_sample && (sda_bit != expected_t);   // R-WR-02 / TE2
  assign parity_ok  = wr_tbit_sample && (sda_bit == expected_t);

  // ---- Read T-bit generation (target-driven End-of-Data bit, RD-TBIT-EOD-01) -
  wire rd_tbit_slot = ninth_q && ph_data && is_read;
  wire begin_drive  = scl_falling && rd_tbit_slot;     // start the drive on SCL fall

  // Hold the drive across the SCL-Low period; latch the value at the fall.
  logic drv_active, drv_val;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      drv_active <= 1'b0;
      drv_val    <= 1'b0;
    end else if (scl_rising || rstart_stb) begin
      drv_active <= 1'b0;                               // release on SCL rise / abort
    end else if (begin_drive) begin
      drv_active <= 1'b1;
      drv_val    <= more_read_data;
    end
  end

  // Value currently being driven: a fresh fall latches more_read_data, otherwise
  // the held value. Single source so tbit_o and t_drive_val never disagree.
  wire cur_val = begin_drive ? more_read_data : drv_val;
  assign t_drive_val = (begin_drive || drv_active) ? cur_val : more_read_data;
  // Drive on SCL fall, hold through SCL-Low, release on SCL rise (RD-RELEASE-01).
  assign tbit_oe = (begin_drive || drv_active) && !scl_rising && !rstart_stb;
  assign tbit_o  = cur_val;

  // ---- Read-abort: Repeated START after a continue (T=1) bit (RD-ABORT-01) ---
  logic after_continue;                                // a continue-T was just parked
  always_ff @(posedge clk) begin
    if (!rst_n)                                   after_continue <= 1'b0;
    else if (rstart_stb)                          after_continue <= 1'b0;   // resolved/abort
    else if (byte_done)                           after_continue <= 1'b0;   // controller continued
    else if (drv_active && drv_val && scl_rising) after_continue <= 1'b1;   // continue-T released
  end

  assign read_abort = after_continue && rstart_stb;

  // ==========================================================================
  // Formal properties (Slice 2 - §4.E T1-T5, §4.B F1)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (idealized-edge model, architecture §2.4) -----
  // Recorded for the integration assume-ledger.
  always_ff @(posedge clk) begin
    // SCL rising/falling edge strobes are mutually exclusive.
    am_edge_excl    : assume (!(scl_rising && scl_falling));
    // byte_done is produced by the bit engine at the 8th-bit sample (a scl_rising).
    am_bytedone_rise: assume (!byte_done || scl_rising);
    // A Repeated START is an SDA edge while SCL is stable-High: not coincident
    // with an SCL edge strobe.
    am_rstart_excl  : assume (!rstart_stb || (!scl_rising && !scl_falling));
  end

  // The protocol FSM holds phase / direction constant across one byte's 9th-bit
  // slot (they only change at byte / frame boundaries).
  always_ff @(posedge clk) if (f_past_valid) begin
    am_phase_stable : assume (!(ninth_q && $past(ninth_q)) || (phase   == $past(phase)));
    am_isread_stable: assume (!(ninth_q && $past(ninth_q)) || (is_read == $past(is_read)));
  end

  // ---- F1 : 9th-bit role decided by phase (R-FMT-02, CCC-NINTH-01) -----------
  always_ff @(posedge clk) if (rst_n) begin
    f1_ack_role  : assert (!ninth_q || (ack_slot  == ph_addr));
    f1_tbit_role : assert (!ninth_q || (tbit_slot == ph_data));
    f1_excl      : assert (!(ack_slot && tbit_slot));
    f1_ack_imp   : assert (!ack_slot  || ninth_q);
    f1_tbit_imp  : assert (!tbit_slot || ninth_q);
  end

  // ---- T1 : write parity check correctness (R-WR-02, R-TBIT-01) --------------
  always_ff @(posedge clk) if (rst_n) begin
    t1_par_err  : assert (!wr_tbit_sample || (parity_err == (sda_bit != expected_t)));
    t1_par_ok   : assert (!wr_tbit_sample || (parity_ok  == (sda_bit == expected_t)));
    t1_excl     : assert (!(parity_ok && parity_err));
    // Parity flags only ever fire in a controller-write T-bit sample (not in an
    // ACK slot, a read T-bit, or idle) -> never a false TE2.
    t1_ctx_err  : assert (!parity_err || (ninth_q && ph_data && !is_read && scl_rising));
    t1_ctx_ok   : assert (!parity_ok  || (ninth_q && ph_data && !is_read && scl_rising));
  end

  // ---- T2 / T3 : read T-bit drive values + release timing --------------------
  // Helper invariants (mutually inductive with the drive-discipline asserts).
  always_ff @(posedge clk) if (rst_n) begin
    h_drv_ninth : assert (!drv_active || ninth_q);
    h_drv_read  : assert (!drv_active || (is_read && ph_data));
  end
  always_ff @(posedge clk) if (rst_n) begin
    // T2 read END (T=0): drive Low on SCL fall.
    t2_drive    : assert (!(rd_tbit_slot && scl_falling && !more_read_data)
                          || (tbit_oe && !tbit_o));
    // T3 read CONTINUE (T=1): drive High on SCL fall.
    t3_drive    : assert (!(rd_tbit_slot && scl_falling &&  more_read_data)
                          || (tbit_oe &&  tbit_o));
    // Release on SCL rise (RD-RELEASE-01): the T-bit driver is never on at a
    // sample edge -> covers both T2/T3 "then High-Z on next SCL rising".
    t_release   : assert (!scl_rising || !tbit_oe);
    // Hold the drive through the SCL-Low period between fall and rise.
    t_hold      : assert (!(drv_active && !scl_rising && !rstart_stb) || tbit_oe);
    // Driven value matches the reported decision while driving.
    t_val_cons  : assert (!tbit_oe || (tbit_o == t_drive_val));
    // The framer drives ONLY the read T-bit (never an ACK slot, never a write):
    // supports S3/S6 and WR-NODRIVE-01 at integration.
    s_drive_rd  : assert (!tbit_oe || (is_read && ph_data && ninth_q));
  end

  // ---- T4 : read-abort detect (Sr after continue-T, RD-ABORT-01) -------------
  always_ff @(posedge clk) if (rst_n) begin
    t4_def      : assert (read_abort == (after_continue && rstart_stb));
    t4_nodrive  : assert (!read_abort || !tbit_oe);    // MUST NOT drive when aborting
  end

  // ---- T5 : DAA PAR helper (odd parity over DA[6:0], DAA-PAR-01) -------------
  // The frozen interface gives the framer no DAA-PAR port (i3c_daa owns par_err);
  // this proves the reusable odd-parity primitive the DAA layer relies on.
  wire [6:0] f_daa_da   = rx_byte[7:1];
  wire       f_daa_par  = rx_byte[0];
  wire       f_daa_pok  = (f_daa_par == ~(^f_daa_da));   // PAR valid?
  always_ff @(posedge clk) if (rst_n) begin
    // XOR formulation: valid PAR <=> whole {DA,PAR} byte has odd parity.
    t5_par_xor  : assert (f_daa_pok == (^rx_byte));
    // Independent arithmetic cross-check via a population count (odd # of ones).
    t5_par_cnt  : assert (f_daa_pok == (($countones(rx_byte) & 32'd1) == 32'd1));
  end

  // ---- Reachability covers ---------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_ninth     : cover (ninth_slot);
    c_ack       : cover (ack_slot);
    c_tbit      : cover (tbit_slot);
    c_par_ok    : cover (parity_ok);
    c_par_err   : cover (parity_err);
    c_read_end  : cover (rd_tbit_slot && tbit_oe && !tbit_o);   // T=0 drive
    c_read_cont : cover (rd_tbit_slot && tbit_oe &&  tbit_o);   // T=1 drive
    c_release   : cover (f_past_valid && $past(tbit_oe) && !tbit_oe && $past(scl_falling) == 1'b0);
    c_after_cont: cover (after_continue);
    c_read_abort: cover (read_abort);
  end
`endif

endmodule
`endif
