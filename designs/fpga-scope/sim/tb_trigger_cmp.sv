// tb_trigger_cmp — comparator truth-table sweep, all 4 units, cycle-exact (issue #6).
//
// Drives the scope_ref.py "cmp" case suite (sim/run.sh gen_vectors): 6 cases covering
// level-only hit/miss, edge-only rise/fall/wrong-direction, level+edge combined, multi-bit
// edge masks, all-zero mask (always-hit), alternating X-adjacent patterns, and biased-random
// configs. EVERY cycle's cmp_hit[3:0] is compared against the model's per-sample hits — not
// just the final trigger. All cases use TRIG_COMBINE=0 (no stage enabled), so `trig` must
// never fire from the comparator path (checked every cycle, run held high).
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps
module tb_trigger_cmp
  import scope_pkg::*;
;

  localparam int unsigned PROBE_W = 16;
  localparam int unsigned MAXC = 8;  // array headroom; real counts come from the meta file
  localparam int unsigned MAXS = 512;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic [PROBE_W-1:0] probe = '0;
  logic run = 1'b0;
  logic [4*PROBE_W-1:0] cmp_mask_i = '0, cmp_value_i = '0, cmp_edge_mask_i = '0,
                        cmp_edge_pol_i = '0;
  logic [31:0] trig_combine_i = '0;
  logic [4*32-1:0] seq_cnt_i = '0;
  logic trig, trig_ext_o;
  logic [PROBE_W-1:0] sample_o;
  logic [3:0] cmp_hit;

  scope_trigger #(
      .PROBE_W   (PROBE_W),
      .NUM_CMP   (4),
      .SEQ_STAGES(4)
  ) dut (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .run          (run),
      .force_trig   (1'b0),
      .trig_ext_i   (1'b0),
      .cmp_mask     (cmp_mask_i),
      .cmp_value    (cmp_value_i),
      .cmp_edge_mask(cmp_edge_mask_i),
      .cmp_edge_pol (cmp_edge_pol_i),
      .trig_combine (trig_combine_i),
      .seq_cnt      (seq_cnt_i),
      .trig         (trig),
      .trig_ext_o   (trig_ext_o),
      .sample_o     (sample_o),
      .cmp_hit      (cmp_hit)
  );

  logic [PROBE_W-1:0] stim[MAXC*MAXS];
  logic [3:0] hits[MAXC*MAXS];
  logic [63:0] cfg[MAXC*21];
  logic [63:0] meta[MAXC+2];
  initial begin
    $readmemh("sim/build/vectors/trig_cmp_stim.mem", stim);
    $readmemh("sim/build/vectors/trig_cmp_hits.mem", hits);
    $readmemh("sim/build/vectors/trig_cmp_cfg.mem", cfg);
    $readmemh("sim/build/vectors/trig_cmp_meta.mem", meta);
  end

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", msg);
  endtask

  // sample_o must be probe delayed by exactly LATENCY=2 cycles (the alignment path)
  logic [PROBE_W-1:0] probe_q1, probe_q2;
  always @(posedge clk) begin
    if (rst) begin
      probe_q1 <= '0;
      probe_q2 <= '0;
    end else begin
      probe_q1 <= probe;
      probe_q2 <= probe_q1;
      if (sample_o !== probe_q2) fail("sample_o != probe delayed by LATENCY");
    end
  end

  // NOTE: config vectors are assembled in full-width temporaries and assigned whole.
  // Workaround: Verilator 5.020 does not propagate procedural PART-SELECT writes to >64-bit signals
  // into downstream continuous assigns (verified with a minimal repro); full-width
  // assignments propagate correctly.
  task automatic load_cfg(input int unsigned c);
    logic [4*PROBE_W-1:0] tm, tv, tem, tep;
    logic [4*32-1:0] tsc;
    for (int unsigned k = 0; k < 4; k++) begin
      tm[k*PROBE_W+:PROBE_W]  = PROBE_W'(cfg[c*21+k*4+0]);
      tv[k*PROBE_W+:PROBE_W]  = PROBE_W'(cfg[c*21+k*4+1]);
      tem[k*PROBE_W+:PROBE_W] = PROBE_W'(cfg[c*21+k*4+2]);
      tep[k*PROBE_W+:PROBE_W] = PROBE_W'(cfg[c*21+k*4+3]);
    end
    for (int unsigned n = 0; n < 4; n++) tsc[n*32+:32] = cfg[c*21+17+n][31:0];
    cmp_mask_i      = tm;
    cmp_value_i     = tv;
    cmp_edge_mask_i = tem;
    cmp_edge_pol_i  = tep;
    seq_cnt_i       = tsc;
    trig_combine_i  = cfg[c*21+16][31:0];
  endtask

  int unsigned ncases, spc;

  initial begin
    repeat (5) @(negedge clk);
    rst = 1'b0;
    ncases = 32'(meta[0]);
    spc    = 32'(meta[1]);
    run    = 1'b1;  // sequencer live: proves combine=0 never fires even while running

    for (int unsigned c = 0; c < ncases; c++) begin
      probe = '0;
      load_cfg(c);
      repeat (3) @(negedge clk);  // model prev0=0: probe_d1 settled to 0 before sample 0

      for (int unsigned i = 0; i < spc; i++) begin
        @(negedge clk);
        // cmp_hit visible now belongs to sample i-1 (registered comparator outputs)
        if (i > 0 && cmp_hit !== hits[c*spc+i-1])
          fail($sformatf("case %0d sample %0d: cmp_hit %b != model %b", c, i - 1, cmp_hit,
                         hits[c*spc+i-1]));
        if (trig !== 1'b0) fail($sformatf("case %0d: trig fired with TRIG_COMBINE=0", c));
        if (trig_ext_o !== 1'b0) fail($sformatf("case %0d: trig_ext_o fired", c));
        probe = stim[c*spc+i];
      end
      @(negedge clk);
      if (cmp_hit !== hits[c*spc+spc-1])
        fail($sformatf("case %0d final sample: cmp_hit %b != model %b", c, cmp_hit,
                       hits[c*spc+spc-1]));
      probe = '0;
      repeat (3) @(negedge clk);
    end

    $display("-- %0d comparator cases x %0d samples, cycle-exact", ncases, spc);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #10ms;
    fail("timeout");
  end

endmodule
