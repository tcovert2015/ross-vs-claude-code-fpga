// tb_pretrig — pre-trigger depth sweep + host-math reconstruction (issue #7).
//
// Two legs (DEPTH_LOG2 = 8 and 10), each sweeping PRETRIG in {0, 1, 25%, 50%, DEPTH-1}
// against scope_ref.py golden vectors (run.sh gen_vectors; the pretrig/trig-sample table
// there must match the localparams below). Trigger cycles cover both "before the buffer
// first wraps" (incl. K == PRETRIG, the first ARMED sample, adjacent to the
// FILLING->ARMED boundary) and "long after wrap". Where PRETRIG >= 1 an extra trig pulse
// is driven at sample PRETRIG-1 — the exact FILLING->ARMED transition-decision cycle — and
// must be IGNORED (trig_index proves the accepted trigger was the one at K).
// After each capture:
//   * full buffer + trig_index + wrapped compared against the model;
//   * the buffer is reordered in the TB using the DOCUMENTED host math (DESIGN.md
//     "Host-side reconstruction"):
//       post   = DEPTH - PRETRIG
//       oldest = wrapped ? (trig_index + post) mod DEPTH : 0
//       ordered[i] = buffer[(oldest + i) mod DEPTH]
//     and the reconstructed sequence must equal stim[K-PRETRIG .. K+post-1], with the
//     trigger sample at ordered[PRETRIG]. That check is the point of the milestone.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_pretrig_leg
  import scope_pkg::*;
#(
    parameter int unsigned DEPTH_LOG2 = 8,
    parameter string       NAME       = "leg"
) (
    output bit done
);

  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned MAXS = 4 * DEPTH + 512;
  // pretrig / trigger-sample table — MUST match gen_vectors in sim/run.sh
  localparam int unsigned PT[5] = '{0, 1, DEPTH / 4, DEPTH / 2, DEPTH - 1};
  localparam int unsigned KS[5] = '{3, 2 * DEPTH + 341, DEPTH / 4, 2 * DEPTH + 123,
                                    2 * DEPTH + 55};

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic [PROBE_W-1:0] sample_data = '0;
  logic sample_valid = 1'b0;
  logic trig = 1'b0, arm = 1'b0, disarm = 1'b0;
  logic [DEPTH_LOG2-1:0] pretrig = '0;
  logic [2:0] state;
  logic triggered, wrapped, armed;
  logic [7:0] windows_done;
  logic [DEPTH_LOG2-1:0] trig_index;
  logic [DEPTH_LOG2-1:0] rd_addr = '0;
  logic [PROBE_W-1:0] rd_data;
  logic [7:0] win_rd_addr = '0;
  logic [DEPTH_LOG2:0] win_rd_data;
  logic [47:0] ts, ts_at_trig;

  scope_core #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) dut (
      .clk         (clk),
      .rst         (rst),
      .sample_data (sample_data),
      .sample_valid(sample_valid),
      .trig        (trig),
      .arm         (arm),
      .disarm      (disarm),
      .pretrig     (pretrig),
      .windows     (8'd1),
      .state       (state),
      .triggered   (triggered),
      .wrapped     (wrapped),
      .windows_done(windows_done),
      .trig_index  (trig_index),
      .armed       (armed),
      .rd_addr     (rd_addr),
      .rd_data     (rd_data),
      .win_rd_addr (win_rd_addr),
      .win_rd_data (win_rd_data),
      .ts          (ts),
      .ts_at_trig  (ts_at_trig)
  );

  logic [PROBE_W-1:0] stim[MAXS];
  logic [PROBE_W-1:0] exp_buf[DEPTH];
  logic [63:0] exp_meta[3];
  logic [PROBE_W-1:0] got_buf[DEPTH];

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // consume the always-unused outputs so -Wall stays clean without waivers
  wire unused_outputs = &{1'b0, armed, windows_done, ts, ts_at_trig, win_rd_data};

  initial begin
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    for (int unsigned r = 0; r < 5; r++) begin
      automatic int unsigned P = PT[r];
      automatic int unsigned K = KS[r];
      automatic int unsigned post = DEPTH - P;
      automatic int unsigned oldest;
      automatic string pfx = $sformatf("sim/build/vectors/pt_d%0d_p%0d", DEPTH_LOG2, P);
      $readmemh({pfx, "_stim.mem"}, stim);
      $readmemh({pfx, "_buf.mem"}, exp_buf);
      $readmemh({pfx, "_meta.mem"}, exp_meta);

      pretrig = DEPTH_LOG2'(P);
      @(negedge clk);
      arm = 1'b1;
      @(negedge clk);
      arm = 1'b0;
      // stream sample k on cycle k (cycle 0 = first FILLING cycle); the accepted trigger
      // rides sample K; an extra pulse at P-1 (the FILLING->ARMED decision cycle) must be
      // ignored
      begin
        automatic int unsigned k = 0;
        sample_valid = 1'b1;
        while (state != 3'(SCOPE_ST_DONE)) begin
          sample_data = stim[k];
          trig = (k == K) || (P >= 1 && k == P - 1);
          @(negedge clk);
          k++;
          if (k > 4 * DEPTH + 600) fail($sformatf("run %0d: no DONE", r));
        end
        sample_valid = 1'b0;
        trig = 1'b0;
      end

      // metadata vs model
      if (trig_index !== DEPTH_LOG2'(exp_meta[0]))
        fail($sformatf("run %0d: trig_index %0d != model %0d", r, trig_index, exp_meta[0]));
      if (wrapped !== exp_meta[1][0]) fail($sformatf("run %0d: wrapped vs model", r));
      if (triggered !== 1'b1) fail($sformatf("run %0d: triggered not set", r));

      // full buffer vs model
      for (int unsigned a = 0; a < DEPTH; a++) begin
        rd_addr = DEPTH_LOG2'(a);
        @(negedge clk);
        @(negedge clk);
        got_buf[a] = rd_data;
        if (rd_data !== exp_buf[a])
          fail($sformatf("run %0d: buffer[%0d]=%h != model %h", r, a, rd_data, exp_buf[a]));
      end

      // host-math reconstruction (DESIGN.md "Host-side reconstruction")
      oldest = wrapped ? (32'(trig_index) + post) % DEPTH : 0;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        automatic logic [PROBE_W-1:0] ordered_i = got_buf[(oldest+i)%DEPTH];
        if (ordered_i !== stim[K-P+i])
          fail($sformatf("run %0d: ordered[%0d]=%h != stim[%0d]=%h", r, i, ordered_i, K - P + i,
                         stim[K-P+i]));
      end
      if (got_buf[(oldest+P)%DEPTH] !== stim[K])
        fail($sformatf("run %0d: trigger sample not at ordered[PRETRIG]", r));

      // next run
      @(negedge clk);
      disarm = 1'b1;
      @(negedge clk);
      disarm = 1'b0;
      repeat (3) @(negedge clk);
      $display("-- [%s] PRETRIG=%0d K=%0d: buffer, metadata, and host reconstruction exact",
               NAME, P, K);
    end

    done = 1'b1;
  end

endmodule
/* verilator lint_on DECLFILENAME */

module tb_pretrig;

  bit done_a, done_b;

  tb_pretrig_leg #(
      .DEPTH_LOG2(8),
      .NAME      ("d8")
  ) leg_a (
      .done(done_a)
  );

  tb_pretrig_leg #(
      .DEPTH_LOG2(10),
      .NAME      ("d10")
  ) leg_b (
      .done(done_b)
  );

  initial begin
    wait (done_a && done_b);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #20ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout: done=%b%b", done_a, done_b);
  end

endmodule
