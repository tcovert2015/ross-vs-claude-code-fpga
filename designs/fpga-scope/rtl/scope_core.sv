// scope_core — capture RAM controller: circular buffer + pre-trigger + window FSM.
//
// Architecture: docs/DESIGN.md (incl. the host-side reconstruction math). Interface
// contract: docs/INTERFACES.md. Shared defs: rtl/scope_pkg.sv. Golden reference:
// sim/model/scope_ref.py (capture_model / windows_model replay these exact semantics).
//
// Responsibilities:
//   * Store `sample_data` into a DEPTH x PROBE_W circular buffer (prim_ram_1r1w, "old data"
//     read-during-write policy per issue #3) on every `sample_valid` cycle while capturing.
//     THE WRITE PATH HAS NO READY/BACK-PRESSURE — the capture side never stalls on the
//     transport (tracker rule 1). The buffer read port is same-clock, for the drain.
//   * Capture FSM per window: IDLE -> FILLING (store the pretrig backlog) -> ARMED (write
//     pointer free-runs, circular in the window's slice) -> TRIGGERED (store the post
//     budget, the trigger sample counted as the first) -> DONE -> (windows remaining ?
//     auto re-arm into the next slice : park in DONE until arm/disarm).
//   * WINDOW SLICING (issue #7, v1 semantics — INTERFACES.md "Capture semantics"):
//     W_eff = 2^ceil(log2(WINDOWS)) (clamped so a slice holds >= 2 samples; scope_csr
//     rejects out-of-range WINDOWS with cfg_err). The buffer is divided into W_eff equal
//     slices of SLICE = DEPTH/W_eff samples; window w captures into slice w. Per-window
//     scaling: pretrig_eff = PRETRIG >> log2(W_eff) (proportional), post budget =
//     SLICE - pretrig_eff with the trigger sample as post sample #1.
//   * Latch `trig_index` (absolute buffer address of the trigger sample) and `ts_at_trig`
//     for the MOST RECENT window; per-window {wrapped, trig_index} goes into a sideband
//     metadata RAM read via win_rd_addr/win_rd_data (drained in the #8 header).
//   * `wrapped` = write offset passed the slice size once since this window (re)armed.
//     The host reconstructs time order from trig_index/wrapped/PRETRIG (DESIGN.md math).
//   * Free-running TS_W-bit timestamp `ts`, cleared only by rst (tracker rule 5).
//
// Policy decisions:
//   * The sample present on `sample_data` in the cycle `trig` is asserted (with
//     sample_valid) IS the trigger sample; it is always stored (formal (a)).
//   * Triggers are accepted only in ARMED (ignored in FILLING — the backlog does not exist
//     yet); force_trig pending in scope_csr rides through gaps.
//   * After the LAST window the FSM parks in DONE (readable status/buffer) until arm or
//     disarm — deviation from PLAN.md's auto-IDLE, recorded in DESIGN.md. disarm aborts
//     from any state; windows_done then shows how many windows completed.
//   * In DONE the write pointer does not advance (formal (b)).
//   * WINDOWS is latched at arm; scope_csr's cfg_err lockout keeps config stable while
//     running. The core self-clamps W_eff to DEPTH/2 slices, so even unvalidated `windows`
//     values cannot underflow the slice math (garbage-in, safe-out).
module scope_core #(
    parameter int unsigned PROBE_W    = 32,   // 1..512
    parameter int unsigned DEPTH_LOG2 = 8,    // 8..15
    parameter int unsigned TS_W       = 48
) (
    input  logic                  clk,
    input  logic                  rst,           // synchronous, active high

    // sample stream (from the trigger engine's aligned sample_o; never back-pressured)
    input  logic [PROBE_W-1:0]    sample_data,
    input  logic                  sample_valid,

    // trigger: 1-cycle pulse aligned to the trigger sample on sample_data
    input  logic                  trig,

    // control (from CSR; pulses for arm/disarm, levels for config)
    input  logic                  arm,
    input  logic                  disarm,
    input  logic [DEPTH_LOG2-1:0] pretrig,       // samples to keep before the trigger
    input  logic [7:0]            windows,       // captures per arm, 1..255 (csr-validated)

    // status
    output logic [2:0]            state,         // scope_pkg::scope_state_e encoding
    output logic                  triggered,     // most recent window
    output logic                  wrapped,       // most recent window
    output logic [7:0]            windows_done,
    output logic [DEPTH_LOG2-1:0] trig_index,    // most recent window, absolute address
    output logic                  armed,

    // buffer read port (drain path, same clock; 1-cycle latency)
    input  logic [DEPTH_LOG2-1:0] rd_addr,
    output logic [PROBE_W-1:0]    rd_data,

    // per-window metadata read port ({wrapped, trig_index}; 1-cycle latency; issue #8 drain)
    input  logic [7:0]            win_rd_addr,
    output logic [DEPTH_LOG2:0]   win_rd_data,

    // timestamps (probe domain)
    output logic [TS_W-1:0]       ts,            // free-running, cleared only by rst
    output logic [TS_W-1:0]       ts_at_trig     // ts of the most recent trigger sample
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned PR_W = DEPTH_LOG2 + 1;  // post-counter width (holds a full slice)

  // ceil(log2(max(w,1))) clamped so a slice keeps >= 2 samples (W_eff <= DEPTH/2)
  function automatic logic [3:0] weff_log2_of(input logic [7:0] w);
    weff_log2_of = 4'd0;
    for (int unsigned i = 0; i < 8; i++) begin
      if (32'(w) > (32'h1 << i)) weff_log2_of = 4'(i + 1);
    end
    if (weff_log2_of > 4'(DEPTH_LOG2 - 1)) weff_log2_of = 4'(DEPTH_LOG2 - 1);
  endfunction

  scope_pkg::scope_state_e st;
  logic [DEPTH_LOG2-1:0] offset;      // write offset within the current slice
  logic [DEPTH_LOG2-1:0] base;        // current slice base address (multiple of SLICE)
  logic [DEPTH_LOG2-1:0] slice_mask;  // SLICE-1, latched at arm
  logic [3:0]            weff_log2_q; // log2(W_eff), latched at arm
  logic [7:0]            win_idx;     // current window number
  logic [7:0]            windows_q;   // window target, latched at arm
  logic [DEPTH_LOG2-1:0] fill_cnt;    // samples stored in FILLING (this window)
  logic [PR_W-1:0]       post_remaining;

  wire [DEPTH_LOG2-1:0] wr_addr_w = base | offset;
  wire [DEPTH_LOG2-1:0] pretrig_eff = pretrig >> weff_log2_q;

  // Write path: no ready, no stall. Stores in FILLING/ARMED always, in TRIGGERED while the
  // post-trigger budget lasts, never in IDLE/DONE.
  wire capture_wr = sample_valid && (st == scope_pkg::SCOPE_ST_FILLING ||
                                     st == scope_pkg::SCOPE_ST_ARMED ||
                                     (st == scope_pkg::SCOPE_ST_TRIGGERED &&
                                      post_remaining != '0));
  wire trig_accept = trig && sample_valid && (st == scope_pkg::SCOPE_ST_ARMED);

  wire fill_wr = capture_wr && (st == scope_pkg::SCOPE_ST_FILLING);
  wire post_wr = capture_wr && (st == scope_pkg::SCOPE_ST_TRIGGERED);

  // Post-update counter values, used for prompt state transitions (exactly `pretrig_eff`
  // samples are stored in FILLING; DONE is entered the cycle after the last post sample).
  wire [DEPTH_LOG2:0] fill_next = {1'b0, fill_cnt} + {{DEPTH_LOG2{1'b0}}, fill_wr};
  wire [PR_W-1:0] post_next = post_remaining - PR_W'(post_wr);
  wire wrapped_next = wrapped || (capture_wr && offset == slice_mask);
  wire window_done_now = (st == scope_pkg::SCOPE_ST_TRIGGERED) && (post_next == '0);

  always_ff @(posedge clk) begin
    if (rst) begin
      st             <= scope_pkg::SCOPE_ST_IDLE;
      offset         <= '0;
      base           <= '0;
      slice_mask     <= '1;
      weff_log2_q    <= '0;
      win_idx        <= 8'h00;
      windows_q      <= 8'h01;
      fill_cnt       <= '0;
      post_remaining <= '0;
      triggered      <= 1'b0;
      wrapped        <= 1'b0;
      windows_done   <= 8'h00;
      trig_index     <= '0;
      ts             <= '0;
      ts_at_trig     <= '0;
    end else begin
      ts <= ts + 1'b1;

      if (capture_wr) begin
        offset  <= (offset + 1'b1) & slice_mask;
        wrapped <= wrapped_next;
      end
      if (fill_wr) fill_cnt <= fill_cnt + 1'b1;
      if (post_wr) post_remaining <= post_next;

      if (trig_accept) begin
        trig_index     <= wr_addr_w;  // the trigger sample is stored HERE this cycle
        ts_at_trig     <= ts;
        triggered      <= 1'b1;
        // trigger sample = post sample #1: remaining = SLICE - pretrig_eff - 1
        post_remaining <= {1'b0, slice_mask} - {1'b0, pretrig_eff};
      end

      if (disarm) begin
        st <= scope_pkg::SCOPE_ST_IDLE;
      end else begin
        unique case (st)
          scope_pkg::SCOPE_ST_IDLE: begin
            if (arm) begin
              st           <= scope_pkg::SCOPE_ST_FILLING;
              offset       <= '0;
              base         <= '0;
              win_idx      <= 8'h00;
              windows_q    <= windows;
              weff_log2_q  <= weff_log2_of(windows);
              slice_mask   <= DEPTH_LOG2'((DEPTH - 1) >> weff_log2_of(windows));
              fill_cnt     <= '0;
              triggered    <= 1'b0;
              wrapped      <= 1'b0;
              windows_done <= 8'h00;
            end
          end
          scope_pkg::SCOPE_ST_FILLING: begin
            if (fill_next >= {1'b0, pretrig_eff}) st <= scope_pkg::SCOPE_ST_ARMED;
          end
          scope_pkg::SCOPE_ST_ARMED: begin
            if (trig_accept) st <= scope_pkg::SCOPE_ST_TRIGGERED;
          end
          scope_pkg::SCOPE_ST_TRIGGERED: begin
            if (post_next == '0) begin
              st           <= scope_pkg::SCOPE_ST_DONE;
              windows_done <= windows_done + 8'h01;
            end
          end
          scope_pkg::SCOPE_ST_DONE: begin
            if (arm) begin  // fresh capture run
              st           <= scope_pkg::SCOPE_ST_FILLING;
              offset       <= '0;
              base         <= '0;
              win_idx      <= 8'h00;
              windows_q    <= windows;
              weff_log2_q  <= weff_log2_of(windows);
              slice_mask   <= DEPTH_LOG2'((DEPTH - 1) >> weff_log2_of(windows));
              fill_cnt     <= '0;
              triggered    <= 1'b0;
              wrapped      <= 1'b0;
              windows_done <= 8'h00;
            end else if (windows_done < windows_q) begin  // auto re-arm: next slice
              st        <= scope_pkg::SCOPE_ST_FILLING;
              offset    <= '0;
              base      <= base + DEPTH_LOG2'(slice_mask) + 1'b1;
              win_idx   <= win_idx + 8'h01;
              fill_cnt  <= '0;
              triggered <= 1'b0;
              wrapped   <= 1'b0;
            end
            // else: park in DONE; buffer and status stay readable until arm/disarm
          end
          default: st <= scope_pkg::SCOPE_ST_IDLE;  // unreachable encodings recover to IDLE
        endcase
      end
    end
  end

  assign state = st;  // enum's logic [2:0] base IS the STATUS.state encoding
  assign armed = (st == scope_pkg::SCOPE_ST_FILLING) || (st == scope_pkg::SCOPE_ST_ARMED);

  // Capture buffer: "old data" read-during-write (tracker rule 2).
  prim_ram_1r1w #(
      .WIDTH     (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_buf (
      .clk    (clk),
      .wr_en  (capture_wr),
      .wr_addr(wr_addr_w),
      .wr_data(sample_data),
      .rd_en  (1'b1),
      .rd_addr(rd_addr),
      .rd_data(rd_data)
  );

  // Per-window {wrapped, trig_index} sideband, written once at each window's completion
  // (wrapped_next folds in a same-cycle final-write wrap). Aborts (disarm) don't record.
  prim_ram_1r1w #(
      .WIDTH     (DEPTH_LOG2 + 1),
      .DEPTH_LOG2(8)
  ) u_win_meta (
      .clk    (clk),
      .wr_en  (window_done_now && !disarm),
      .wr_addr(win_idx),
      .wr_data({wrapped_next, trig_index}),
      .rd_en  (1'b1),
      .rd_addr(win_rd_addr),
      .rd_data(win_rd_data)
  );

`ifdef FORMAL
  // Formal properties (a) and (b) — issues #6/#7, run by formal/scope_core.sby.
  // Instantiated under `ifdef FORMAL (yosys in the CI baseline lacks bind) so synthesis
  // and Verilator never see the checker; properties live in formal/scope_core_fchk.sv.
  scope_core_fchk #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_fchk (
      .clk           (clk),
      .rst           (rst),
      .state         (state),
      .offset        (offset),
      .base          (base),
      .slice_mask    (slice_mask),
      .weff_log2_q   (weff_log2_q),
      .pretrig_eff   (pretrig_eff),
      .trig_index    (trig_index),
      .post_remaining(post_remaining),
      .capture_wr    (capture_wr),
      .trig_accept   (trig_accept),
      .sample_data   (sample_data),
      .arm           (arm)
  );
`endif

endmodule
