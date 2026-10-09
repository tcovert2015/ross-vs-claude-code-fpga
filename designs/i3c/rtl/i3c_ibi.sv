// ============================================================================
// i3c_ibi.sv  -  IBI (In-Band Interrupt) request / arbitration / MDB + payload
//
// Architecture §1.9. Device-agnostic SDR+IBI Target IBI engine.
//
// Sequence (idealized-edge model, one *_stb pulse = one settled bus edge):
//   IDLE  : not active. An IBI request (ibi_request) is accepted only while
//           capable = bcr[1] && ibi_en && ibi_en_app && da_valid.  -> WAIT.
//   WAIT  : back-off / arming.  Begin arbitration ONLY on a plain START while a
//           Bus Available Condition holds and NOT after a Repeated START
//           (BUS-AVAIL-01 / IBI-INIT-01 / IBI-AVAIL-01).  -> ARB.
//   ARB   : drive the 8-bit header {dyn_addr[6:0],1'b1} (RnW=1) MSB-first,
//           OPEN-DRAIN with per-bit arbitration: drive Low for a 0 bit, release
//           for a 1 bit and monitor.  released-1 sampled-0 => lost (IBI-ARB-01):
//             * loss on an address bit (idx<7)  -> ibi_arb_lost, back off (WAIT)
//             * loss on the RnW bit  (idx==7)   -> a Private Write to us won;
//               ibi_deferred, controller wins (IBI-DEFER-01 outcome (a)).
//   ACK   : release SDA; sample the controller's ACK/NACK (9th bit).
//             * ACK (Low) + bcr[2] -> PRE then push-pull MDB (IBI-MDB-01).
//             * ACK (Low) + !bcr[2] -> frame ends (no payload, IBI-MDB-02).
//             * NACK (High) -> ibi_nacked, release, return IDLE (IBI-NACK-01).
//   PRE   : ACK->MDB hand-off window: drive SDA Low (never High) until the next
//           SCL falling, then begin push-pull (critique F-5 contention safety).
//   DATA  : push-pull byte (MDB first, then optional payload), MSB-first.
//   TBIT  : push-pull read End-of-Data T-bit (T=1 continue, T=0 last).  Total
//           payload bounded by Max IBI Payload Size (IBI-MDB-LIM-01 / I9).
//
// B-7 collision enumeration (the four addr/RnW outcomes):
//   1. loss at an address bit          -> arb-loss / re-arm   (ibi_arb_lost)
//   2. loss at RnW bit (Private Write) -> defer, controller wins (ibi_deferred)
//   3. win header, controller ACKs     -> IBI accepted        (ibi_acked -> MDB)
//   4. win header, controller NACKs    -> NACK / back off      (ibi_nacked)
//   The "Private-Read double-NACK" tie (both addr+RnW match) is indistinguishable
//   from a won header during the header itself; it is resolved at the 9th bit and
//   folds into outcome 4 (controller NACK -> defer/back off).  See open issues.
//
// SDA model (design_decisions §3): ibi_oe=1,ibi_o=0 => drive Low; ibi_oe=0 =>
// release (pull-up High); push-pull phases may drive 0 or 1.  Open-drain phases
// (ARB, ACK, PRE) only ever drive Low or release - never High.
// ============================================================================
`ifndef I3C_IBI_SV
`define I3C_IBI_SV
`include "i3c_pkg.sv"

module i3c_ibi (
  input  logic        clk,
  input  logic        rst_n,
  // bus edge strobes (front-end, idealized)
  input  logic        scl_rising,
  input  logic        scl_falling,
  input  logic        sda_sync,        // sampled resolved SDA (arbitration)
  input  logic        start_stb,       // plain START
  input  logic        rstart_stb,      // repeated START
  input  logic        stop_stb,        // STOP
  input  logic        bus_available,   // tAVAL elapsed (gate)
  input  logic        post_rstart,     // a Sr occurred this frame (no IBI after Sr)
  // dynamic address (from i3c_daa, read-only)
  input  logic [6:0]  dyn_addr,
  input  logic        da_valid,
  // identity / config
  input  logic [7:0]  bcr,             // [1] IBI-capable, [2] MDB present
  input  logic        ibi_en,          // bus event-enable (regfile)
  input  logic        ibi_en_app,      // CTRL[2] application gate
  // request + payload source
  input  logic        ibi_request,     // request an IBI (Avalon IBI_CTRL)
  input  logic [7:0]  mdb,             // Mandatory Data Byte
  input  logic        mdb_is_prn,      // MDB is a Pending-Read-Notification
  input  logic [7:0]  max_ibi_payload, // payload bound (0 = unlimited)
  input  logic [7:0]  pl_byte,         // IBI payload head byte (TX/IBI FIFO)
  input  logic        pl_valid,        // payload byte available
  input  logic        pl_last,         // last payload byte
  // SDA drive (-> i3c_sda_mux src[SDA_IBI])
  output logic        ibi_oe,
  output logic        ibi_o,
  // payload FIFO pop
  output logic        pl_pop,
  // status
  output logic        ibi_active,      // IBI sequence in progress
  output logic        ibi_busy,        // request accepted, not yet done (STATUS[11])
  output logic        ibi_acked,       // controller ACKed the IBI address
  output logic        ibi_nacked,      // controller NACKed the IBI
  output logic        ibi_arb_lost,    // lost IBI arbitration
  output logic        ibi_deferred,    // deferred on collision / back-off
  output logic        ibi_done,        // sequence complete (INT)
  output logic [6:0]  ibi_addr         // address driven in header (== dyn_addr)
);

  // ---- state encoding -------------------------------------------------------
  localparam logic [2:0]
    ST_IDLE = 3'd0,
    ST_WAIT = 3'd1,   // request accepted, awaiting a Bus-Available plain START
    ST_ARB  = 3'd2,   // open-drain header arbitration
    ST_ACK  = 3'd3,   // 9th bit: sample controller ACK/NACK
    ST_PRE  = 3'd4,   // ACK->MDB low-drive hand-off window (F-5)
    ST_DATA = 3'd5,   // push-pull byte (MDB or payload)
    ST_TBIT = 3'd6;   // push-pull End-of-Data T-bit

  logic [2:0] state;
  logic [3:0] bit_idx;      // bit index within a byte (0..7)
  logic [7:0] cur_byte;     // byte being shifted out (MDB or payload)
  logic       cur_last;     // current payload byte is the last (pl_last latch)
  logic       is_mdb;       // current byte is the MDB
  logic       mdb_en;       // bcr[2] latched at ACK (MDB will be sent)
  logic [8:0] pl_count;     // bytes emitted so far (MDB counts as 1)
  logic       busy;         // request accepted, not yet terminated
  logic       acked_q, nacked_q, arblost_q, deferred_q;

  // ---- combinational helpers ------------------------------------------------
  logic [2:0] bidx;
  assign bidx = bit_idx[2:0];

  logic [7:0] hdr_word;
  assign hdr_word = {dyn_addr, 1'b1};           // {addr[6:0], RnW=1}
  logic hdr_bit;
  assign hdr_bit = hdr_word[3'd7 - bidx];        // MSB-first
  logic data_bit;
  assign data_bit = cur_byte[3'd7 - bidx];       // MSB-first

  logic capable;
  assign capable = bcr[1] && ibi_en && ibi_en_app && da_valid;

  // another byte follows the current one (drives T=1) - bounded by Max IBI Payload
  logic more_data;
  assign more_data = pl_valid && !cur_last &&
                     (max_ibi_payload == 8'd0 || pl_count < {1'b0, max_ibi_payload});

  logic active_s;
  assign active_s = (state == ST_ARB) || (state == ST_ACK) || (state == ST_PRE) ||
                    (state == ST_DATA) || (state == ST_TBIT);

  // ---- SDA drive (purely combinational from state / bit index) --------------
  // OD phases (ARB/ACK/PRE) only drive Low or release.  PP phases drive 0 or 1.
  always_comb begin
    unique case (state)
      ST_ARB:  begin ibi_oe = ~hdr_bit;  ibi_o = 1'b0;     end // Low for 0, release for 1
      ST_ACK:  begin ibi_oe = 1'b0;      ibi_o = 1'b0;     end // release for ACK
      ST_PRE:  begin ibi_oe = 1'b1;      ibi_o = 1'b0;     end // ACK->MDB Low window
      ST_DATA: begin ibi_oe = 1'b1;      ibi_o = data_bit; end // push-pull data
      ST_TBIT: begin ibi_oe = 1'b1;      ibi_o = more_data;end // push-pull T-bit
      default: begin ibi_oe = 1'b0;      ibi_o = 1'b0;     end // IDLE/WAIT released
    endcase
  end

  // ---- status / output assigns ----------------------------------------------
  assign ibi_addr   = dyn_addr;          // I3: never a group address
  assign ibi_active = active_s;
  assign ibi_busy   = busy;
  assign ibi_acked  = acked_q;
  assign ibi_nacked = nacked_q;
  assign ibi_arb_lost = arblost_q;
  assign ibi_deferred = deferred_q;

  // ---- main FSM -------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      bit_idx   <= 4'd0;
      cur_byte  <= 8'd0;
      cur_last  <= 1'b0;
      is_mdb    <= 1'b0;
      mdb_en    <= 1'b0;
      pl_count  <= 9'd0;
      busy      <= 1'b0;
      acked_q   <= 1'b0;
      nacked_q  <= 1'b0;
      arblost_q <= 1'b0;
      deferred_q<= 1'b0;
      ibi_done  <= 1'b0;
      pl_pop    <= 1'b0;
    end else begin
      // 1-cycle pulses default low
      ibi_done <= 1'b0;
      pl_pop   <= 1'b0;

      unique case (state)
        // -------------------------------------------------------------------
        ST_IDLE: begin
          bit_idx  <= 4'd0;
          pl_count <= 9'd0;
          is_mdb   <= 1'b0;
          mdb_en   <= 1'b0;
          cur_last <= 1'b0;
          if (ibi_request && capable) begin
            busy      <= 1'b1;
            acked_q   <= 1'b0;
            nacked_q  <= 1'b0;
            arblost_q <= 1'b0;
            deferred_q<= 1'b0;
            state     <= ST_WAIT;
          end
        end
        // -------------------------------------------------------------------
        ST_WAIT: begin
          // Drop the attempt if the Target became IBI-incapable (e.g. DISEC).
          if (!capable) begin
            busy  <= 1'b0;
            state <= ST_IDLE;
          end else if (start_stb && !post_rstart && bus_available) begin
            // begin arbitration on a Bus-Available plain START
            state     <= ST_ARB;
            bit_idx   <= 4'd0;
            arblost_q <= 1'b0;   // clear stale status for the new attempt
            deferred_q<= 1'b0;
          end
          // rstart_stb / stop_stb: stay waiting (no IBI after Sr)
        end
        // -------------------------------------------------------------------
        ST_ARB: begin
          if (stop_stb || rstart_stb) begin
            state <= ST_WAIT;                 // controller aborted; back off
          end else if (scl_rising) begin
            if (hdr_bit && !sda_sync) begin
              // released a 1 but bus is Low -> lost arbitration
              if (bit_idx == 4'd7) deferred_q <= 1'b1;   // RnW bit: Private Write won
              else                 arblost_q  <= 1'b1;   // address bit: lower addr won
              state <= ST_WAIT;
            end else if (bit_idx == 4'd7) begin
              state   <= ST_ACK;              // won full header -> ACK slot
              bit_idx <= 4'd0;
            end else begin
              bit_idx <= bit_idx + 4'd1;
            end
          end
        end
        // -------------------------------------------------------------------
        ST_ACK: begin
          if (stop_stb || rstart_stb) begin
            busy  <= 1'b0;
            state <= ST_IDLE;
            pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
          end else if (scl_rising) begin
            if (!sda_sync) begin
              // controller ACKed (SDA Low)
              acked_q <= 1'b1;
              if (bcr[2]) begin
                // IBI-MDB-01: drive Low after the ACK rising, begin PP next falling
                cur_byte <= mdb;
                cur_last <= 1'b0;
                is_mdb   <= 1'b1;
                mdb_en   <= 1'b1;
                pl_count <= 9'd1;             // MDB counts as the first payload byte
                bit_idx  <= 4'd0;
                state    <= ST_PRE;
              end else begin
                // no MDB (BCR[2]=0): frame ends after ACK
                ibi_done <= 1'b1;
                busy     <= 1'b0;
                state    <= ST_IDLE;
                pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
              end
            end else begin
              // controller NACKed (SDA High) -> release, return idle
              nacked_q <= 1'b1;
              busy     <= 1'b0;
              state    <= ST_IDLE;
              pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
            end
          end
        end
        // -------------------------------------------------------------------
        ST_PRE: begin
          if (stop_stb || rstart_stb) begin
            busy  <= 1'b0;
            state <= ST_IDLE;
            pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
          end else if (scl_falling) begin
            state <= ST_DATA;                 // begin push-pull MDB
          end
        end
        // -------------------------------------------------------------------
        ST_DATA: begin
          if (stop_stb || rstart_stb) begin
            busy  <= 1'b0;
            state <= ST_IDLE;
            pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
          end else if (scl_rising) begin
            if (bit_idx == 4'd7) begin
              state   <= ST_TBIT;
              bit_idx <= 4'd0;
            end else begin
              bit_idx <= bit_idx + 4'd1;
            end
          end
        end
        // -------------------------------------------------------------------
        ST_TBIT: begin
          if (stop_stb || rstart_stb) begin
            busy  <= 1'b0;
            state <= ST_IDLE;
            pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
          end else if (scl_rising) begin
            if (more_data) begin
              // load next payload byte from the FIFO
              cur_byte <= pl_byte;
              cur_last <= pl_last;
              is_mdb   <= 1'b0;
              pl_pop   <= 1'b1;
              if (~&pl_count) pl_count <= pl_count + 9'd1;  // saturating
              bit_idx  <= 4'd0;
              state    <= ST_DATA;
            end else begin
              // last byte transmitted -> done
              ibi_done <= 1'b1;
              busy     <= 1'b0;
              state    <= ST_IDLE;
              pl_count <= 9'd0; is_mdb <= 1'b0; mdb_en <= 1'b0; cur_last <= 1'b0;
            end
          end
        end
        // -------------------------------------------------------------------
        default: state <= ST_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // Formal properties (Slice 6, architecture §4.G + critique B-7 / F-5)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- idealized SCL level tracker (drives edge-cadence assumes) -----------
  reg scl_lvl = 1'b1;   // synced SCL level: High at idle
  always_ff @(posedge clk) begin
    if (!rst_n)            scl_lvl <= 1'b1;
    else if (scl_rising)   scl_lvl <= 1'b1;
    else if (scl_falling)  scl_lvl <= 1'b0;
  end

  // ---- environment assumptions (assume-ledger) ------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    // A1: SCL edges never coincide and alternate (one settled edge per strobe).
    am_scl_excl : assume (!(scl_rising && scl_falling));
    am_scl_rise : assume (!scl_rising  || !scl_lvl);   // rising only from Low
    am_scl_fall : assume (!scl_falling ||  scl_lvl);   // falling only from High
    // A2: bus-condition strobes are mutually exclusive ...
    am_evt_excl : assume (!(start_stb && rstart_stb) && !(start_stb && stop_stb) &&
                          !(rstart_stb && stop_stb));
    // ... and never coincide with an SCL edge (idealized settled bus events).
    am_evt_noscl: assume (!((start_stb || rstart_stb || stop_stb) &&
                            (scl_rising || scl_falling)));
    // A3: a plain START clears post_rstart (protocol-FSM contract).
    am_start_post: assume (!start_stb || !post_rstart);
    // A4: wired-AND bus model: when the Target pulls SDA Low, the line reads Low.
    am_busmodel : assume (!(ibi_oe && !ibi_o) || !sda_sync);
  end
  // A5: the dynamic address is stable while an IBI request is in flight (owned
  //     by i3c_daa, which does not run a DAA round concurrently with an IBI).
  // A6: the Max IBI Payload bound is stable while an IBI is in flight (only
  //     changes via SETMRL, which cannot occur during an in-flight IBI).
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    am_da_stable : assume (!$past(busy) ||
                           (da_valid == $past(da_valid) && dyn_addr == $past(dyn_addr)));
    am_max_stable: assume (!$past(busy) || (max_ibi_payload == $past(max_ibi_payload)));
  end

  // ---- structural / single-step invariants ----------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    // I3: the IBI address is always the dynamic address, never a group address.
    p_i3        : assert (ibi_addr == dyn_addr);
    // I2: header value is {dyn_addr,1} with RnW=1, MSB-first open-drain.
    p_i2_rnw    : assert (hdr_word[0] == 1'b1);
    p_i2_addr   : assert (hdr_word[7:1] == dyn_addr);
    p_i2_od     : assert (!(state == ST_ARB &&  ibi_oe) || (ibi_o == 1'b0 && hdr_bit == 1'b0));
    p_i2_rel    : assert (!(state == ST_ARB && !ibi_oe) || (hdr_bit == 1'b1));
    // S2 / F-5: open-drain phases never actively drive High.
    p_s2_arb    : assert (!(state == ST_ARB) || !(ibi_oe && ibi_o));
    p_f5        : assert (!(state == ST_ACK || state == ST_PRE) || !(ibi_oe && ibi_o));
    // quiet when idle / waiting (never drive SDA outside an active sequence).
    p_idle_quiet: assert (!(state == ST_IDLE || state == ST_WAIT) || !ibi_oe);
    // active/busy bookkeeping.
    p_active    : assert (ibi_active == active_s);
    // any non-IDLE state implies an accepted (busy) request.
    p_busy_act  : assert (!(state != ST_IDLE) || busy);
    // I7: a NACK releases the bus and returns to idle.
    p_i7        : assert (!ibi_nacked || (!ibi_oe && state == ST_IDLE));
    // I6: payload states only reachable when MDB was enabled (bcr[2]).
    p_i6        : assert (!(state == ST_PRE || state == ST_DATA || state == ST_TBIT) || mdb_en);
    // ST_PRE always carries the MDB at bit 0 (k-induction helper for I5).
    p_pre_mdb   : assert (!(state == ST_PRE) || (is_mdb && mdb_en && bit_idx == 4'd0));
    // I9 helper invariants (make the bound inductive).
    p_cnt_quiet : assert (!(state == ST_IDLE || state == ST_WAIT ||
                            state == ST_ARB  || state == ST_ACK) || pl_count == 9'd0);
    p_cnt_act   : assert (!(state == ST_PRE || state == ST_DATA || state == ST_TBIT) ||
                          (pl_count >= 9'd1 &&
                           (max_ibi_payload == 8'd0 || pl_count <= {1'b0, max_ibi_payload})));
    // I9: payload bound.
    p_i9        : assert (!((state == ST_PRE || state == ST_DATA || state == ST_TBIT) &&
                            max_ibi_payload != 8'd0) ||
                          pl_count <= {1'b0, max_ibi_payload});
    // bit-index range (k-induction helper).
    p_bidx      : assert (bit_idx <= 4'd7);
  end

  // ---- one-step ($past) transition properties --------------------------------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // I1: IBI drive begins only under the full gating set.
    p_arb_from_wait : assert (!(state == ST_ARB && $past(state) != ST_ARB) ||
                              $past(state) == ST_WAIT);
    p_i1 : assert (!(state == ST_ARB && $past(state) != ST_ARB) ||
                   ($past(bcr[1]) && $past(ibi_en) && $past(ibi_en_app) &&
                    $past(da_valid) && $past(bus_available) &&
                    $past(start_stb) && !$past(post_rstart)));

    // I4: arbitration loss on an address bit -> release + ibi_arb_lost.
    p_i4 : assert (!($past(state == ST_ARB) && $past(bit_idx) < 4'd7 &&
                     $past(hdr_bit) && $past(scl_rising) && !$past(sda_sync)) ||
                   (ibi_arb_lost && !ibi_oe));

    // B-7 outcome (a): loss on the RnW bit (Private Write) -> defer + release.
    p_i8_defer : assert (!($past(state == ST_ARB) && $past(bit_idx) == 4'd7 &&
                           $past(scl_rising) && !$past(sda_sync)) ||
                         (ibi_deferred && !ibi_oe));

    // B-7 outcomes (3)/(4): won header then ACK/NACK at the 9th bit.
    p_ack  : assert (!($past(state == ST_ACK) && $past(scl_rising) && !$past(sda_sync)) ||
                     ibi_acked);
    p_nack : assert (!($past(state == ST_ACK) && $past(scl_rising) &&  $past(sda_sync)) ||
                     (ibi_nacked && !ibi_oe));

    // I5: after ACK with bcr[2], hand off to push-pull MDB whose first byte = MDB.
    p_i5_pre  : assert (!($past(state == ST_ACK) && $past(scl_rising) &&
                          !$past(sda_sync) && $past(bcr[2])) ||
                        (state == ST_PRE && is_mdb && cur_byte == $past(mdb)));
    p_i5_data : assert (!($past(state == ST_PRE) && $past(scl_falling)) ||
                        (state == ST_DATA && is_mdb));
    // structural: while sending the MDB the driven byte is the MDB.
    p_i5_byte : assert (!(state == ST_DATA && is_mdb) || mdb_en);

    // I6: ACK with !bcr[2] ends the frame (no MDB, released, idle).
    p_i6_nomdb : assert (!($past(state == ST_ACK) && $past(scl_rising) &&
                           !$past(sda_sync) && !$past(bcr[2])) ||
                         (state == ST_IDLE && !ibi_oe));
    // I6 gating: PRE only entered from an ACK with bcr[2].
    p_i6_gate  : assert (!(state == ST_PRE && $past(state) == ST_ACK) || $past(bcr[2]));

    // payload pop only when consuming an extra payload byte (T-bit -> next byte).
    p_pop_legal: assert (!pl_pop || ($past(state == ST_TBIT) && $past(more_data) &&
                                     $past(scl_rising)));
  end

  // ---- covers ----------------------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_arb       : cover (state == ST_ARB);
    c_acked     : cover (ibi_acked);
    c_mdb_drive : cover (state == ST_DATA && is_mdb);                 // driving MDB
    c_acked_mdb : cover (ibi_done && acked_q);                        // ACKed IBI w/ MDB done
    c_payload   : cover (state == ST_DATA && !is_mdb);               // extra payload byte
    c_tbit_cont : cover (state == ST_TBIT && more_data);            // T=1 continue
    c_tbit_last : cover (state == ST_TBIT && !more_data);           // T=0 last
    c_nacked    : cover (ibi_nacked);                                 // NACKed IBI
    c_arblost   : cover (ibi_arb_lost);                              // arbitration loss
    c_defer     : cover (ibi_deferred);                             // Private-Write defer
    c_prn       : cover (state == ST_DATA && is_mdb && mdb_is_prn);  // PRN MDB
  end
  // B-7 cover: a deferred / lost IBI re-attempts arbitration after Bus-Available.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    c_rearm : cover (state == ST_ARB && $past(state) == ST_WAIT &&
                     $past(arblost_q || deferred_q));
  end
`endif

endmodule
`endif
