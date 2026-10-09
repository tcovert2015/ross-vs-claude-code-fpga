// ============================================================================
// i3c_fifo.sv  -  Generic single-clock RX/TX FIFO (architecture §1.13)
//
// Parameterized synchronous (single-clock) FIFO used for both RX (bus->app) and
// TX (app->bus) paths. Standard full/empty/level accounting:
//   * push (wr_en) is IGNORED when full, but raises a sticky `overflow` flag so
//     there is NO SILENT LOSS (critique V5 / R-MWL-04).
//   * pop (rd_en) is IGNORED when empty (no underflow).
//   * first-word-fall-through: `rd_data` always presents the head word.
//
// SCOPE (design_decisions D-4 / architecture §2.1): only the single-clock variant
// (ASYNC=0) is implemented; `i3c_target_top` ties avl_clk = sys_clk by default, so
// rd_clk/rd_rst_n MUST be tied to wr_clk/wr_rst_n. The async dual-clock Gray-pointer
// variant (ASYNC=1) is intentionally OUT OF SCOPE for this module/proof and would
// be a separate implementation. The ASYNC parameter is retained only to keep the
// frozen port/param contract (docs/interfaces.md §2.5) intact.
//
// Formal: proves V5 level-accounting / no-silent-overrun / no-underflow as
// k-induction-friendly immediate assertions (yosys open-source subset).
// ============================================================================
`ifndef I3C_FIFO_SV
`define I3C_FIFO_SV
`include "i3c_pkg.sv"

module i3c_fifo #(
  parameter int unsigned DW    = i3c_pkg::RX_FIFO_W,   // word width (RX_FIFO_W / TX_FIFO_W)
  parameter int unsigned DEPTH = 8,                    // number of entries (>=2)
  parameter int unsigned AW    = (DEPTH <= 2) ? 1 : $clog2(DEPTH),
  parameter bit          ASYNC = 1'b0                  // 0 = single-clock (only mode implemented)
) (
  // ---- write side (bus domain for RX, app/avl domain for TX) ----------------
  input  logic            wr_clk,
  input  logic            wr_rst_n,
  input  logic            wr_en,      // push request
  input  logic [DW-1:0]   wr_data,    // word in
  input  logic            clear,      // synchronous flush: drop all entries (FINDING-SIM-2)
  output logic            full,       // level == DEPTH
  output logic [AW:0]     wr_level,   // write-side occupancy (0..DEPTH)
  output logic            overflow,   // sticky: a push was attempted while full (V5)
  // ---- read side (= write side when ASYNC=0; rd_clk/rd_rst_n tied to wr_*) ---
  input  logic            rd_clk,     // unused when ASYNC=0 (tie = wr_clk)
  input  logic            rd_rst_n,   // unused when ASYNC=0 (tie = wr_rst_n)
  input  logic            rd_en,      // pop request
  output logic [DW-1:0]   rd_data,    // head word (first-word-fall-through)
  output logic            empty,      // level == 0
  output logic [AW:0]     rd_level    // read-side occupancy (0..DEPTH)
);

  // Storage + pointers + a single occupancy counter (single-clock domain).
  // Small FIFO: map to fast MLAB/distributed memory, not a big M20K block, so the
  // FWFT read (mem[rptr] -> rd_data) is fast. (Quartus synthesis attribute; ignored
  // by yosys/iverilog, so no formal/sim impact.)
  (* ramstyle = "MLAB, no_rw_check" *)
  logic [DW-1:0] mem [0:DEPTH-1];
  logic [AW-1:0] wptr, rptr;
  logic [AW:0]   level;

  // Effective push/pop: push masked by full (no overrun), pop masked by empty.
  wire do_push = wr_en && !full;
  wire do_pop  = rd_en && !empty;

  // Status (combinational off the single occupancy counter).
  assign full     = (level == DEPTH);
  assign empty    = (level == 0);
  assign wr_level = level;
  assign rd_level = level;          // single clock: read/write occupancy identical
  assign rd_data  = mem[rptr];      // FWFT: head word always presented

  always_ff @(posedge wr_clk) begin
    if (!wr_rst_n) begin
      wptr     <= '0;
      rptr     <= '0;
      level    <= '0;
      overflow <= 1'b0;
    end else if (clear) begin
      wptr     <= '0;
      rptr     <= '0;
      level    <= '0;
      overflow <= 1'b0;
    end else begin
      // write (only when not full)
      if (do_push) begin
        mem[wptr] <= wr_data;
        wptr      <= (wptr == AW'(DEPTH-1)) ? '0 : wptr + 1'b1;
      end
      // read (only when not empty)
      if (do_pop) begin
        rptr <= (rptr == AW'(DEPTH-1)) ? '0 : rptr + 1'b1;
      end
      // occupancy: +1 push-only, -1 pop-only, unchanged otherwise
      unique case ({do_push, do_pop})
        2'b10:   level <= level + 1'b1;
        2'b01:   level <= level - 1'b1;
        default: level <= level;
      endcase
      // sticky overflow: a push was attempted while full (no silent loss, V5)
      if (wr_en && full) overflow <= 1'b1;
    end
  end

`ifdef FORMAL
  // Single-clock proof: all logic runs on wr_clk; rd_clk/rd_rst_n are tied equal
  // at integration (ASYNC=0) and are not modelled here.
  reg f_past_valid = 1'b0;
  always_ff @(posedge wr_clk) f_past_valid <= 1'b1;

  initial assume (!wr_rst_n);

  // ---- combinational / state invariants (k-induction d1) --------------------
  always_ff @(posedge wr_clk) if (wr_rst_n) begin
    // V5: occupancy bounded — no silent overrun (level never exceeds DEPTH)
    a_level_bound  : assert (level <= DEPTH);
    // full <=> level==DEPTH ; empty <=> level==0
    a_full_iff     : assert (full  == (level == DEPTH));
    a_empty_iff    : assert (empty == (level == 0));
    // full and empty are mutually exclusive (DEPTH>=1)
    a_not_both     : assert (!(full && empty));
    // pointers stay in range (helper invariant, inductive)
    a_wptr_bound   : assert (wptr < DEPTH);
    a_rptr_bound   : assert (rptr < DEPTH);
    // a push is structurally suppressed when full; a pop when empty
    a_push_gated   : assert (!(full)  || !do_push);
    a_pop_gated    : assert (!(empty) || !do_pop);
  end

  // ---- transition invariants (k-induction, use $past) -----------------------
  always_ff @(posedge wr_clk) if (f_past_valid && wr_rst_n && $past(wr_rst_n)) begin
    // clear flushes the FIFO: level and overflow go to 0.
    a_clear        : assert (!$past(clear) || ((level == 0) && (overflow == 1'b0)));

    // V5 level accounting: change is exactly +1 / -1 / 0 per masked push/pop
    // (a synchronous clear overrides all of these; exempt it).
    a_acc_push     : assert (!( $past(do_push) && !$past(do_pop) && !$past(clear)) || (level == $past(level) + 1));
    a_acc_pop      : assert (!(!$past(do_push) &&  $past(do_pop) && !$past(clear)) || (level == $past(level) - 1));
    a_acc_same     : assert (!(($past(do_push) ==  $past(do_pop)) && !$past(clear)) || (level == $past(level)));

    // no underflow: a pop only ever happened from a non-empty FIFO
    a_no_underflow : assert (!$past(do_pop) || ($past(level) > 0));

    // push-while-full => overflow flag set AND no write committed (wptr unmoved)
    a_overflow_set : assert (!($past(wr_en) && $past(full) && !$past(clear)) || overflow);
    a_no_write_full: assert (!($past(wr_en) && $past(full) && !$past(clear)) || (wptr == $past(wptr)));
    // and occupancy is unchanged by a blocked push (unless a concurrent pop)
    a_full_nochange: assert (!($past(wr_en) && $past(full) && !$past(do_pop) && !$past(clear)) || (level == $past(level)));

    // no pop when empty => read pointer does not advance
    a_no_pop_empty : assert (!($past(rd_en) && $past(empty) && !$past(clear)) || (rptr == $past(rptr)));

    // overflow is sticky and only ever raised by a push-while-full
    a_ovf_sticky   : assert (!$past(overflow) || overflow || $past(clear));
    a_ovf_cause    : assert (!(overflow && !$past(overflow)) || ($past(wr_en) && $past(full)));
  end

  // ---- reachability witnesses ----------------------------------------------
  always_ff @(posedge wr_clk) if (wr_rst_n) begin
    c_reach_full : cover (full);
    c_reach_mid  : cover (level == (DEPTH/2) && !full && !empty);
    c_overflow   : cover (overflow);
    c_pushpop    : cover (do_push && do_pop);
    c_drain      : cover (f_past_valid && !$past(empty) && empty);   // returned to empty
    c_wrap_wptr  : cover (f_past_valid && $past(do_push) && $past(wptr) == AW'(DEPTH-1) && wptr == 0);
    c_wrap_rptr  : cover (f_past_valid && $past(do_pop)  && $past(rptr) == AW'(DEPTH-1) && rptr == 0);
  end
`endif

endmodule
`endif
