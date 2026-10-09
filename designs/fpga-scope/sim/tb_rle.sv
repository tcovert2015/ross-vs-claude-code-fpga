// tb_rle — scope_rle encoder word stream vs the scope_ref.py golden model (issue #9).
//
// For each stimulus class (compressible / near-worst-case / wide), drive the raw sample stream
// into scope_rle one sample per cycle (never back-pressured), collect the emitted words, flush
// at end-of-stream, and compare the collected word stream BYTE-for-BYTE against the model's
// `_words.mem` — proving the RTL encoder reproduces the canonical encoding. Also checks:
//   * expansion bound: word count <= sample count + 1 (formal (c) is the unbounded proof);
//   * bypass (enable=0): every sample -> {is_count=0, sample}, count == sample count;
// decode-identity is guaranteed by the model's own self-test (cmd_rle) so is not re-done here.
//
/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_rle_leg #(
    parameter int unsigned PROBE_W    = 8,
    parameter int unsigned CNT_W      = 8,
    parameter string       VEC_PREFIX = "",
    parameter string       NAME       = "leg"
) (
    output bit done,
    output int unsigned errs
);
  localparam int unsigned MAXN = 4096;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic               enable, in_valid, flush;
  logic [PROBE_W-1:0] in_data;
  logic [PROBE_W:0]   word;
  logic               word_valid;
  logic               unused_trig_out;

  // trig_in tied 0 here: this TB verifies the pure encoder word stream vs scope_ref; the
  // trigger-flush path is exercised end-to-end through scope_top by tb_cosim / host co-sim.
  scope_rle #(.PROBE_W(PROBE_W), .CNT_W(CNT_W)) dut (
      .clk(clk), .rst(rst), .enable(enable), .in_data(in_data),
      .in_valid(in_valid), .flush(flush), .trig_in(1'b0),
      .word(word), .word_valid(word_valid), .trig_out(unused_trig_out));

  // vectors
  logic [PROBE_W-1:0] samples [0:MAXN-1];
  logic [PROBE_W:0]   exp_words [0:MAXN-1];
  logic [63:0]        meta [0:1];
  int unsigned n_samples, n_words;

  // collection
  logic [PROBE_W:0] got [0:MAXN-1];
  int unsigned n_got;
  bit collecting = 1'b0;
  always_ff @(posedge clk) begin
    if (collecting && word_valid) begin
      if (n_got < MAXN) got[n_got] <= word;
      n_got <= n_got + 1;
    end
  end

  int unsigned errors = 0;
  task automatic fail(input string m);
    $display("TB_RESULT: FAIL"); $display("[%s] %s", NAME, m); errors++;
  endtask

  // drive the whole sample stream, flush, drain; leaves results in got[0..n_got-1]
  task automatic run_stream(input bit use_enable);
    rst = 1'b1; enable = use_enable; in_valid = 1'b0; flush = 1'b0; in_data = '0;
    n_got = 0; collecting = 1'b0;
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    collecting = 1'b1;
    for (int i = 0; i < int'(n_samples); i++) begin
      in_data = samples[i]; in_valid = 1'b1; @(negedge clk);
    end
    in_valid = 1'b0;
    @(negedge clk); flush = 1'b1; @(negedge clk); flush = 1'b0;  // end-of-run flush
    repeat (6) @(negedge clk);   // drain the 1-deep skid + flushed count
    collecting = 1'b0;
  endtask

  initial begin
    done = 1'b0; errs = 0;
    $readmemh({VEC_PREFIX, "_samples.mem"}, samples);
    $readmemh({VEC_PREFIX, "_words.mem"}, exp_words);
    $readmemh({VEC_PREFIX, "_meta.mem"}, meta);
    n_samples = meta[0][31:0];
    n_words   = meta[1][31:0];

    // --- encode: RTL word stream must equal the model word stream exactly ---
    run_stream(1'b1);
    if (n_got != n_words)
      fail($sformatf("word count: RTL %0d vs model %0d (samples=%0d)", n_got, n_words, n_samples));
    else begin
      for (int i = 0; i < int'(n_words); i++)
        if (got[i] !== exp_words[i])
          fail($sformatf("word %0d: RTL %h vs model %h", i, got[i], exp_words[i]));
    end
    if (n_got > n_samples + 1)
      fail($sformatf("expansion bound: %0d words > %0d samples + 1", n_got, n_samples));

    // --- bypass: enable=0 -> one {0,sample} word per sample ---
    run_stream(1'b0);
    if (n_got != n_samples)
      fail($sformatf("bypass count: %0d words vs %0d samples", n_got, n_samples));
    else
      for (int i = 0; i < int'(n_samples); i++)
        if (got[i] !== {1'b0, samples[i]})
          fail($sformatf("bypass word %0d: %h vs {0,%h}", i, got[i], samples[i]));

    if (errors == 0)
      $display("-- [%s] PROBE_W=%0d CNT_W=%0d: %0d samples -> %0d words, encode+bypass PASS",
               NAME, PROBE_W, CNT_W, n_samples, n_words);
    errs = errors;
    done = 1'b1;
  end
endmodule
/* verilator lint_on DECLFILENAME */

module tb_rle;
  bit d0, d1, d2;
  int unsigned e0, e1, e2;
  tb_rle_leg #(.PROBE_W(8),  .CNT_W(8),  .VEC_PREFIX("sim/build/vectors/rle_c8"),  .NAME("const8"))  u0 (.done(d0), .errs(e0));
  tb_rle_leg #(.PROBE_W(8),  .CNT_W(8),  .VEC_PREFIX("sim/build/vectors/rle_t8"),  .NAME("toggle8")) u1 (.done(d1), .errs(e1));
  tb_rle_leg #(.PROBE_W(32), .CNT_W(10), .VEC_PREFIX("sim/build/vectors/rle_w32"), .NAME("wide32"))  u2 (.done(d2), .errs(e2));

  initial begin
    wait (d0 && d1 && d2);
    #20;
    if (e0 != 0 || e1 != 0 || e2 != 0) begin
      $display("TB_RESULT: FAIL");
      $fatal(1, "tb_rle: errs const8=%0d toggle8=%0d wide32=%0d", e0, e1, e2);
    end
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #5_000_000; $display("TB_RESULT: FAIL"); $fatal(1, "tb_rle: global timeout");
  end
endmodule
