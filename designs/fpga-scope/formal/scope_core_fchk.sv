// scope_core_fchk — formal properties (a) and (b) for scope_core (issues #6/#7).
//
// Instantiated INSIDE scope_core under `ifdef FORMAL (see the end of rtl/scope_core.sv), so
// synthesis and Verilator never see it and the checker gets direct port access to the
// internals it observes. Driven by formal/scope_core.sby (SymbiYosys, smtbmc/z3): BMC +
// full k-induction at a reduced parameterization (PROBE_W=4, DEPTH_LOG2=3 — the FSM /
// pointer / slice logic is parametric; the small depth makes full-capture, wrap, and
// multi-window scenarios reachable within BMC depth). All scope_core inputs (arm/disarm/
// trig/sample_*/pretrig/windows) are left free.
//
// (a) The capture FSM never loses the trigger sample: at trigger acceptance the sample is
//     being written at the address latched into trig_index, and that slice offset is never
//     rewritten while the same window is in flight (TRIGGERED). In DONE property (b) shows
//     no writes at all, and once the FSM re-arms the window is over (later windows write
//     other slices; a fresh arm legitimately reuses the buffer). Together with
//     prim_ram_1r1w correctness this implies buffer[trig_index] == probe_at_trigger — the
//     1-sample-shadow reduction (no RAM mirroring). Inductivity comes from the slice-
//     relative pointer-distance invariants below.
// (b) The write pointer never advances in DONE (nor IDLE): asserted on the write-enable —
//     the only pointer-increment path — plus offset/base stability while DONE persists.
module scope_core_fchk #(
    parameter int unsigned PROBE_W    = 4,
    parameter int unsigned DEPTH_LOG2 = 3
) (
    input logic                  clk,
    input logic                  rst,
    input logic [2:0]            state,
    input logic [DEPTH_LOG2-1:0] offset,
    input logic [DEPTH_LOG2-1:0] base,
    input logic [DEPTH_LOG2-1:0] slice_mask,
    input logic [3:0]            weff_log2_q,
    input logic [DEPTH_LOG2-1:0] pretrig_eff,
    input logic [DEPTH_LOG2-1:0] trig_index,
    input logic [DEPTH_LOG2:0]   post_remaining,
    input logic                  capture_wr,
    input logic                  trig_accept,
    input logic [PROBE_W-1:0]    sample_data,
    input logic                  arm
);

  localparam logic [2:0] ST_IDLE = 3'd0, ST_FILLING = 3'd1, ST_ARMED = 3'd2,
                         ST_TRIGGERED = 3'd3, ST_DONE = 3'd4;

  // reset assumption: design starts in reset
  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (rst);

  // ---------------- (a) one-sample shadow of the trigger slot ----------------
  logic                  f_shadow_valid;
  logic [DEPTH_LOG2-1:0] f_shadow_off;   // slice-relative offset of the trigger sample
  logic [PROBE_W-1:0]    f_shadow_data;
  logic [DEPTH_LOG2:0]   f_target;       // post budget after the trigger sample

  always @(posedge clk) begin
    if (rst) begin
      f_shadow_valid <= 1'b0;
    end else begin
      if (trig_accept) begin
        f_shadow_valid <= 1'b1;
        f_shadow_off   <= offset;
        f_shadow_data  <= sample_data;
        f_target       <= {1'b0, slice_mask} - {1'b0, pretrig_eff};  // mirrors the RTL latch
      end else if (state == ST_IDLE || state == ST_FILLING || state == ST_ARMED) begin
        // window over (re-arm / disarm / next window): the old slot is fair game again
        f_shadow_valid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && f_past_valid) begin
      // the trigger sample is stored in the acceptance cycle, at trig_index's address
      if (trig_accept) assert (capture_wr);
      if ($past(trig_accept) && !$past(rst)) begin
        assert (trig_index == ($past(base) | f_shadow_off));
        assert (state == ST_TRIGGERED || state == ST_IDLE);  // disarm may abort
      end
      // (a) core: the shadowed slice offset is never rewritten while the window is in
      // flight (TRIGGERED is the only state writing between acceptance and DONE)
      if (f_shadow_valid && capture_wr && state == ST_TRIGGERED)
        assert (offset != f_shadow_off);
      // slice base cannot drift inside a window
      if (state == ST_TRIGGERED && $past(state) == ST_TRIGGERED && !$past(rst))
        assert (base == $past(base));
    end
  end

  // helper invariants (make (a) inductive): while TRIGGERED with a live shadow, the write
  // offset is exactly (completed post-writes) ahead of the trigger slot within the slice,
  // and post_remaining bounds what remains — the offset can never come back around.
  always @(*) begin
    if (!rst && f_shadow_valid && state == ST_TRIGGERED) begin
      assert (post_remaining <= f_target);
      assert (((offset - f_shadow_off) & slice_mask) ==
              (DEPTH_LOG2'(f_target - post_remaining + 1'b1) & slice_mask));
      assert (f_target <= {1'b0, slice_mask});
      assert ((f_shadow_off & ~slice_mask) == '0);
    end
    if (!rst && state == ST_TRIGGERED) assert (f_shadow_valid);
    if (!rst && f_shadow_valid && state == ST_DONE) assert (post_remaining == '0);
    // structural shape invariants (make the slice ring arithmetic sound in induction):
    // offset confined to the slice, base slice-aligned, mask contiguous-low-bits, and
    // slice_mask consistent with the latched W_eff (weff_log2_q and slice_mask are
    // latched together at arm from the same clamped function — an induction start state
    // must not decouple them, or pretrig_eff could exceed slice_mask and underflow the
    // post-budget arithmetic).
    if (!rst) begin
      assert ((offset & ~slice_mask) == '0);
      assert ((base & slice_mask) == '0);
      assert ((slice_mask & (slice_mask + 1'b1)) == '0);
      assert (weff_log2_q <= 4'(DEPTH_LOG2 - 1));
      assert (slice_mask == DEPTH_LOG2'(((1 << DEPTH_LOG2) - 1) >> weff_log2_q));
      assert (pretrig_eff <= slice_mask);
    end
  end

  // ---------------- (b) write pointer frozen in DONE (and IDLE) ----------------
  always @(*) begin
    if (!rst && (state == ST_DONE || state == ST_IDLE)) assert (!capture_wr);
  end
  always @(posedge clk) begin
    if (f_past_valid && !$past(rst) && $past(state) == ST_DONE && state == ST_DONE) begin
      assert (offset == $past(offset));
      assert (base == $past(base));
    end
  end

  // sanity: state encoding stays legal; reachability covers
  always @(*) if (!rst) assert (state <= ST_DONE);
  always @(posedge clk) begin
    if (!rst) begin
      cover (state == ST_DONE && f_shadow_valid);  // a full window completes
      cover (state == ST_TRIGGERED && base != '0);  // a non-first window is active
    end
  end

endmodule
