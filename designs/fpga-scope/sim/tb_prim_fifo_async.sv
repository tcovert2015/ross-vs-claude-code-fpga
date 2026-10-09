// tb_prim_fifo_async — CDC soak of prim_fifo_async at three clock ratios (issue #3).
//
// Three independent DUT instances (legs) run concurrently, each with its own clocks,
// scoreboard, and stimulus:
//   leg_3to1       wclk 4 ns,  rclk 12 ns    (write side 3x faster), DEPTH_LOG2=4
//   leg_1to3       wclk 12 ns, rclk 4 ns     (read side 3x faster),  DEPTH_LOG2=2
//   leg_1to1_drift wclk 10 ns, rclk 10.3 ns  (~1:1, unrelated drifting phase), DEPTH_LOG2=5
// Each leg:
//   * pops >= 110k scoreboarded transfers (spec: >= 100k per ratio) under rotating
//     push/pop probability regimes (including hard-full 95/5 and hard-empty 5/95 stretches);
//     any data mismatch, drop, duplicate, or reorder -> $fatal;
//   * directed fill-to-full with the read side frozen: asserts total accepted settles at
//     exactly capacity (2^DEPTH_LOG2 + 1: RAM + FWFT output stage) with wr_ready pinned low
//     (wr_ready deasserts exactly at full);
//   * directed drain-to-empty: asserts popped == pushed and rd_valid pinned low afterwards
//     (rd_valid deasserts exactly at empty);
//   * reset check: both resets asserted together at start; while in reset, wr_ready and
//     rd_valid must be low (nothing crosses during reset);
//   * FWFT stability: rd_data frozen while rd_valid && !rd_ready.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" when all
// three legs complete.
`timescale 1ns / 1ps

// ---------------------------------------------------------------------------------------
// One leg: clocks + DUT + driver + scoreboard + phase sequencer.
// ---------------------------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_fifo_async_leg #(
    parameter real         W_HALF     = 2.0,     // wclk half-period, ns
    parameter real         R_HALF     = 6.0,     // rclk half-period, ns
    parameter int unsigned DEPTH_LOG2 = 4,
    parameter int unsigned N_XFERS    = 110000,  // pops required in the soak phase
    parameter logic [7:0]  SEED       = 8'h01,
    parameter string       NAME       = "leg"
) (
    output bit done
);

  localparam int unsigned WIDTH = 16;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned CAP = DEPTH + 1;  // RAM + FWFT output stage

  logic wclk = 1'b0, rclk = 1'b0;
  always #(W_HALF) wclk <= ~wclk;
  always #(R_HALF) rclk <= ~rclk;

  logic wrst = 1'b1, rrst = 1'b1;

  logic [WIDTH-1:0] wr_data;
  logic             wr_valid = 1'b0;
  logic             wr_ready;
  logic [WIDTH-1:0] rd_data;
  logic             rd_valid;
  logic             rd_ready = 1'b0;

  prim_fifo_async #(
      .WIDTH     (WIDTH),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) dut (
      .wclk    (wclk),
      .wrst    (wrst),
      .wr_data (wr_data),
      .wr_valid(wr_valid),
      .wr_ready(wr_ready),
      .rclk    (rclk),
      .rrst    (rrst),
      .rd_data (rd_data),
      .rd_valid(rd_valid),
      .rd_ready(rd_ready)
  );

  // ---- scoreboard + counters (queue pushed in wclk domain, popped in rclk domain; the
  //      FIFO's >= 2-cycle crossing latency guarantees push-before-pop per item) ----------
  logic [WIDTH-1:0] sb[$];
  int unsigned pushed = 0, popped = 0;
  int unsigned push_pct = 0, pop_pct = 0;

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // counting + LFSR pattern: data = {lfsr8, count8}
  logic [7:0] lfsr, cnt8;
  function automatic logic [7:0] lfsr_step(input logic [7:0] v);
    return {v[6:0], v[7] ^ v[5] ^ v[4] ^ v[3]};  // x^8+x^6+x^5+x^4+1, maximal
  endfunction

  // write driver: present wr_valid probabilistically; hold the word until accepted.
  always @(posedge wclk) begin
    if (wrst) begin
      wr_valid <= 1'b0;
      lfsr     <= SEED | 8'h01;  // LFSR must be nonzero
      cnt8     <= 8'h00;
    end else begin
      if (wr_valid && wr_ready) begin
        sb.push_back(wr_data);
        pushed <= pushed + 1;
      end
      if (!wr_valid || wr_ready) begin
        if ($urandom_range(99) < push_pct) begin
          wr_valid <= 1'b1;
          wr_data  <= {lfsr, cnt8};
          lfsr     <= lfsr_step(lfsr);
          cnt8     <= cnt8 + 8'h01;
        end else begin
          wr_valid <= 1'b0;
        end
      end
    end
  end

  // read driver + scoreboard compare
  always @(posedge rclk) begin
    if (rrst) begin
      rd_ready <= 1'b0;
    end else begin
      if (rd_valid && rd_ready) begin
        if (sb.size() == 0) fail("pop with empty scoreboard (duplicate/phantom data)");
        else begin
          automatic logic [WIDTH-1:0] exp = sb.pop_front();
          if (rd_data !== exp)
            fail($sformatf("data mismatch: got %h want %h (pop #%0d)", rd_data, exp, popped));
          popped <= popped + 1;
        end
      end
      rd_ready <= ($urandom_range(99) < pop_pct);
    end
  end

  // FWFT stability under a stalled consumer
  logic [WIDTH-1:0] stall_data;
  logic             stall_armed = 1'b0;
  always @(posedge rclk) begin
    if (rrst) stall_armed <= 1'b0;
    else if (rd_valid && !rd_ready) begin
      if (stall_armed && rd_data !== stall_data)
        fail("rd_data changed while stalled (FWFT stability violated)");
      stall_data  <= rd_data;
      stall_armed <= 1'b1;
    end else begin
      stall_armed <= 1'b0;
    end
  end

  // ---- phase sequencer ------------------------------------------------------------------
  initial begin
    // reset both domains together (contract: overlapping assert, >= SYNC_STAGES+2 cycles each)
    push_pct = 0;
    pop_pct  = 0;
    repeat (8) @(posedge wclk);
    repeat (8) @(posedge rclk);
    // nothing crosses during reset: both sides inert
    @(negedge wclk);
    if (wr_ready !== 1'b0) fail("wr_ready high during reset");
    @(negedge rclk);
    if (rd_valid !== 1'b0) fail("rd_valid high during reset");
    @(negedge wclk) wrst = 1'b0;
    @(negedge rclk) rrst = 1'b0;
    repeat (4) @(posedge wclk);
    repeat (4) @(posedge rclk);

    // ---- directed: fill to full (read side frozen) ---------------------------------------
    push_pct = 100;
    pop_pct  = 0;
    while (pushed - popped != CAP) @(negedge wclk);
    // settle: pointer sync round-trip, then wr_ready must be pinned low at exactly CAP items
    repeat (20) @(negedge wclk);
    repeat (20) begin
      @(negedge wclk);
      if (wr_ready !== 1'b0) fail($sformatf("wr_ready high at full (occ=%0d)", pushed - popped));
      if (pushed - popped != CAP)
        fail($sformatf("occupancy %0d != capacity %0d at full", pushed - popped, CAP));
    end

    // ---- directed: drain to empty ----------------------------------------------------------
    push_pct = 0;
    pop_pct  = 100;
    while (popped != pushed) @(negedge rclk);
    repeat (20) @(negedge rclk);
    if (rd_valid !== 1'b0) fail("rd_valid high after drain-to-empty");
    if (sb.size() != 0) fail("scoreboard not empty after drain (dropped words)");

    // ---- randomized soak: rotate push/pop regimes until N_XFERS pops ----------------------
    begin
      // regimes include hard-full (95/5) and hard-empty (5/95) stretches
      automatic int unsigned regimes[8][2] = '{'{80, 80}, '{100, 25}, '{25, 100}, '{100, 100},
                                               '{50, 50}, '{95, 5}, '{5, 95}, '{60, 90}};
      automatic int unsigned start = popped;
      automatic int unsigned r = 0;
      while (popped - start < N_XFERS) begin
        automatic int unsigned block_start = popped;
        push_pct = regimes[r%8][0];
        pop_pct  = regimes[r%8][1];
        r++;
        while ((popped - block_start < 2000) && (popped - start < N_XFERS)) @(negedge rclk);
      end
    end

    // ---- final drain + totals --------------------------------------------------------------
    push_pct = 0;
    pop_pct  = 100;
    while (popped != pushed) @(negedge rclk);
    repeat (20) @(negedge rclk);
    if (rd_valid !== 1'b0) fail("rd_valid high after final drain");
    if (sb.size() != 0) fail("scoreboard not empty at end");
    $display("-- [%s] %0d transfers scoreboarded clean (capacity %0d)", NAME, popped, CAP);
    done = 1'b1;
  end

endmodule
/* verilator lint_on DECLFILENAME */

// ---------------------------------------------------------------------------------------
// Top: three legs at the specified clock ratios, plus a global watchdog.
// ---------------------------------------------------------------------------------------
module tb_prim_fifo_async;

  bit done_a, done_b, done_c;

  tb_fifo_async_leg #(
      .W_HALF(2.0),
      .R_HALF(6.0),
      .DEPTH_LOG2(4),
      .N_XFERS(110000),
      .SEED(8'h11),
      .NAME("3to1")
  ) leg_a (
      .done(done_a)
  );

  tb_fifo_async_leg #(
      .W_HALF(6.0),
      .R_HALF(2.0),
      .DEPTH_LOG2(2),
      .N_XFERS(110000),
      .SEED(8'h22),
      .NAME("1to3")
  ) leg_b (
      .done(done_b)
  );

  tb_fifo_async_leg #(
      .W_HALF(5.0),
      .R_HALF(5.15),
      .DEPTH_LOG2(5),
      .N_XFERS(110000),
      .SEED(8'h33),
      .NAME("1to1_drift")
  ) leg_c (
      .done(done_c)
  );

  initial begin
    wait (done_a && done_b && done_c);
    $display("TB_RESULT: PASS");
    $finish;
  end

  // watchdog — generous: worst-case regime rotation at the slow-read ratio
  initial begin
    #500ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout: done=%b%b%b", done_a, done_b, done_c);
  end

endmodule
