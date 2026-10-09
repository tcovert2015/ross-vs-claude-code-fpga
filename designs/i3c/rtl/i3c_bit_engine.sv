// ============================================================================
// i3c_bit_engine.sv  -  Bit-level shift / deserialize + read-data serialize
//
// Architecture §1.3, interface contract docs/interfaces.md §2.1 (FROZEN ports).
//
// RX (deserialize): sample sda_sync on every scl_rising strobe and shift the bit
//   MSb-first into an 8-bit register (R-FMT-05). bit_cnt indexes the bit position
//   inside a 9-bit frame slot (0..7 = the eight data bits, 8 = the 9th T/ACK
//   slot). byte_done pulses one cycle after the 8th data bit is sampled, at which
//   point rx_byte holds the freshly assembled byte. start_stb / rstart_stb clear
//   the counter and shift register so a (repeated) START re-aligns the framer.
//
// TX (serialize read data): on tx_load the read-data byte (tx_byte) is latched
//   and presented MSb-first. The SDA_RDATA drive is PUSH-PULL only: rdata_oe
//   follows tx_drive_en and the engine may drive both 0 and 1 (R-RD-01/02).
//   The next bit is shifted out on scl_falling (the TX drive-update point).
//
// Drive discipline (docs/design_decisions §3, critique F-1/F-2): the engine owns
//   exactly the SDA_RDATA mux source. It NEVER drives open-drain and NEVER drives
//   while the Controller is writing (tx_drive_en==0). rdata_oe == tx_drive_en, so
//   "drive only when permitted" is structural (S2/S6).
//
// Arbitration (N-1): read data is push-pull and never arbitrated, so the bit
//   engine has NO arb_lost port. ENTDAA / IBI arbitration-loss (S8, R-ARB-02)
//   is computed in i3c_daa / i3c_ibi from sda_sync vs the driven bit. See the
//   property table for the deferral record.
//
// Reqs: R-FMT-05 (MSb-first), R-WR-01 (no drive during Controller write),
//       R-RD-01/02 (read-data push-pull), R-ACK-05/R-DAA-07 (no OD high, via N/A).
// ============================================================================
`ifndef I3C_BIT_ENGINE_SV
`define I3C_BIT_ENGINE_SV
`include "i3c_pkg.sv"

module i3c_bit_engine (
  input  logic       clk,
  input  logic       rst_n,
  // ---- bus inputs (front-end) --------------------------------------------
  input  logic       sda_sync,     // synchronized SDA level
  input  logic       scl_rising,   // SCL^ strobe - RX sample point
  input  logic       scl_falling,  // SCL_ strobe - TX drive-update point
  input  logic       start_stb,    // plain START   - clears bit counter / RX shift
  input  logic       rstart_stb,   // repeated START- clears bit counter / RX shift
  input  logic       bit_resync,   // re-align byte framing mid-frame (DAA payload->addr, FINDING-SIM-3)
  // ---- read-data serialize control (protocol FSM) ------------------------
  input  logic       tx_load,      // latch tx_byte to begin a read-data byte
  input  logic [7:0] tx_byte,      // read-data byte to send, MSb first
  input  logic       tx_drive_en,  // hold SDA_RDATA driven while sending (push-pull)
  // ---- outputs -----------------------------------------------------------
  output logic [7:0] rx_byte,      // last fully-received 8-bit byte, MSb first
  output logic [3:0] bit_cnt,      // current bit index 0..8 within the frame
  output logic       byte_done,    // pulses when the 8th data bit has been sampled
  output logic       sda_bit,      // value sampled at the most recent scl_rising
  output logic       rdata_oe,     // -> src_oe[SDA_RDATA]
  output logic       rdata_o       // -> src_o[SDA_RDATA]
);

  // -------------------------------------------------------------------------
  // RX deserialize: MSb-first shift register + bit/byte framing
  // -------------------------------------------------------------------------
  logic [7:0] shift_reg;   // newest bit in LSB; earliest bit migrates to MSb

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      shift_reg <= 8'h00;
      bit_cnt   <= 4'd0;
      rx_byte   <= 8'h00;
      sda_bit   <= 1'b0;
      byte_done <= 1'b0;
    end else begin
      byte_done <= 1'b0;                              // default: 1-cycle pulse
      if (start_stb || rstart_stb || bit_resync) begin
        // (Repeated) START or an explicit DAA resync re-aligns the frame.
        bit_cnt   <= 4'd0;
        shift_reg <= 8'h00;
      end else if (scl_rising) begin
        sda_bit   <= sda_sync;                        // capture sampled level
        shift_reg <= {shift_reg[6:0], sda_sync};      // MSb-first shift-in
        if (bit_cnt == 4'd8) begin
          // 9th (T/ACK) bit just sampled -> begin next byte.
          bit_cnt <= 4'd0;
        end else begin
          bit_cnt <= bit_cnt + 4'd1;
          if (bit_cnt == 4'd7) begin
            // 8th data bit just sampled -> latch assembled byte, raise byte_done.
            rx_byte   <= {shift_reg[6:0], sda_sync};
            byte_done <= 1'b1;
          end
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // TX serialize: read-data byte, MSb-first, push-pull.
  // tx_load has priority; otherwise advance one bit per scl_falling while driving.
  // -------------------------------------------------------------------------
  logic [7:0] tx_shift;
  logic       tx_first;   // loaded MSb still owes its first full bit period (FINDING-SIM-4)

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_shift <= 8'hFF;                              // idle = released-High value
      tx_first <= 1'b0;
    end else if (tx_load) begin
      tx_shift <= tx_byte;                            // present MSb (tx_byte[7]) first
      tx_first <= 1'b1;                               // hold it across its first scl_falling
    end else if (scl_falling && tx_drive_en) begin
      // The first falling after a load only completes the MSb's bit period (the
      // Controller samples it on the NEXT rising); shift on subsequent fallings.
      if (tx_first) tx_first <= 1'b0;
      else          tx_shift <= {tx_shift[6:0], 1'b1}; // shift to next bit, fill High
    end
  end

  // Push-pull SDA_RDATA request. Drive ONLY when the protocol FSM enables it
  // (tx_drive_en): never open-drain, never during a Controller write (S2/S6).
  assign rdata_oe = tx_drive_en & rst_n;
  assign rdata_o  = tx_shift[7];

  // ==========================================================================
  // Formal properties (Slice 2 - bit engine)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (idealized-edge model, recorded in ledger) ---
  // SCL rising/falling are distinct edges; a (repeated) START is an SDA edge
  // while SCL is held High, so it never coincides with an SCL edge; START and
  // repeated-START are mutually exclusive (front-end F-3 / N-2 semantics).
  always_ff @(posedge clk) if (rst_n) begin
    am_scl_excl   : assume (!(scl_rising && scl_falling));
    am_start_excl : assume (!(start_stb && rstart_stb));
    am_start_noscl: assume (!((start_stb || rstart_stb) && (scl_rising || scl_falling)));
  end

  // ---- Helper: ghost first-bit of the current byte (for MSb-ordering proof) --
  logic       first_bit;          // bit sampled when bit_cnt==0
  always_ff @(posedge clk) begin
    if (!rst_n)                          first_bit <= 1'b0;
    else if (!(start_stb || rstart_stb || bit_resync) && scl_rising && (bit_cnt == 4'd0))
                                         first_bit <= sda_sync;
  end
  // Position of first_bit inside shift_reg when 1<=bit_cnt<=8 is (bit_cnt-1).
  // 3-bit arithmetic keeps the index in range for all bit_cnt (vacuous outside).
  wire [2:0] fb_idx = bit_cnt[2:0] - 3'd1;

  // ---- Ghost: count completed bytes (cover witness for multi-byte framing) ---
  logic [3:0] f_done_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n)         f_done_cnt <= 4'd0;
    else if (byte_done) f_done_cnt <= f_done_cnt + 4'd1;
  end

  always_ff @(posedge clk) if (rst_n) begin
    // ----- S2 / S6 : drive only when permitted (push-pull read enabled) ------
    // The engine never drives open-drain and never drives during a Controller
    // write; the only legal drive is push-pull read data (tx_drive_en).
    a_s6_drive_perm : assert (!rdata_oe || tx_drive_en);
    // Push-pull driven value equals the current MSb-first read-data bit.
    a_pp_value      : assert (rdata_o == tx_shift[7]);

    // ----- F1 (bit role) : byte/bit framing -----------------------------------
    a_cnt_range     : assert (bit_cnt <= 4'd8);                  // 0..8 only
    a_bd_cnt8       : assert (!byte_done || (bit_cnt == 4'd8));  // 9th slot on done
    // rx_byte holds exactly the shift register's assembled value at byte_done.
    a_rx_eq_shift   : assert (!byte_done || (rx_byte == shift_reg));

    // ----- MSb ordering (RX) --------------------------------------------------
    // Inductive invariant: the first bit of the byte sits at shift_reg[bit_cnt-1].
    a_first_pos     : assert (!(bit_cnt >= 4'd1 && bit_cnt <= 4'd8) ||
                              (shift_reg[fb_idx] == first_bit));
    // End-to-end: the first sampled bit lands in the MSb of the assembled byte.
    a_msb_rx        : assert (!byte_done || (rx_byte[7] == first_bit));
  end

  // Sequential ($past) properties.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // ----- RX sample capture --------------------------------------------------
    // sda_bit reflects the value sampled at the most recent scl_rising and is
    // stable between samples.
    a_sda_capture : assert (!($past(scl_rising) && !$past(bit_resync)) || (sda_bit == $past(sda_sync)));
    a_sda_hold    : assert ( $past(scl_rising) || (sda_bit == $past(sda_bit)));

    // ----- MSb ordering (RX): one-step shift relation -------------------------
    a_rx_shift : assert (!($past(scl_rising) &&
                           !($past(start_stb) || $past(rstart_stb) || $past(bit_resync)))
                         || (shift_reg == {$past(shift_reg[6:0]), $past(sda_sync)}));

    // ----- byte_done is a clean one-cycle pulse caused by the 8th-bit sample ---
    a_bd_cause : assert (!byte_done ||
                         ($past(scl_rising) && ($past(bit_cnt) == 4'd7) &&
                          !($past(start_stb) || $past(rstart_stb))));

    // ----- MSb ordering (TX) : load + shift -----------------------------------
    a_tx_load  : assert (!$past(tx_load) || (tx_shift == $past(tx_byte)));
    a_tx_shift : assert (!($past(scl_falling) && $past(tx_drive_en) &&
                           !$past(tx_load) && !$past(tx_first))
                         || (tx_shift == {$past(tx_shift[6:0]), 1'b1}));
    // FINDING-SIM-4: the first falling after a load HOLDS the MSb (no shift), so the
    // Controller reads tx_byte[7] on the following rising.
    a_tx_first : assert (!($past(scl_falling) && $past(tx_drive_en) && $past(tx_first) &&
                           !$past(tx_load))
                         || (tx_shift == $past(tx_shift)));
    a_tx_hold  : assert ( ($past(tx_load) ||
                           ($past(scl_falling) && $past(tx_drive_en)))
                         || (tx_shift == $past(tx_shift)));

    // ----- Framing reset on (repeated) START ----------------------------------
    a_start_clr: assert (!($past(start_stb) || $past(rstart_stb)) ||
                         ((bit_cnt == 4'd0) && (shift_reg == 8'h00)));
  end

  // ---- Reachability covers --------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_byte_done : cover (byte_done);
    c_byte_a5   : cover (byte_done && (rx_byte == 8'hA5));   // MSb-first assembly
    c_slot9     : cover (bit_cnt == 4'd8);
    c_two_bytes : cover (byte_done && (f_done_cnt == 4'd1)); // 2nd byte completes
    c_drive_lo  : cover (rdata_oe && (rdata_o == 1'b0));     // push-pull drive 0
    c_drive_hi  : cover (rdata_oe && (rdata_o == 1'b1));     // push-pull drive 1
    c_tx_walk   : cover (rdata_oe && $past(rdata_oe) && (rdata_o != $past(rdata_o)));
  end
`endif

endmodule
`endif
