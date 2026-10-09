// tb_trigger_seq — sequencer configurations end-to-end with scope_core (issue #6).
//
// Drives the scope_ref.py "seq" case suite (sim/run.sh gen_vectors): 1/2/3/4-stage
// sequences, occurrence counts {1,2,5,255}, AND and OR combines, disabled-stage skipping,
// and a never-fires case (impossible comparator). scope_trigger feeds a real scope_core
// (sample_data = sample_o, the LATENCY-delayed probe). Per firing case:
//   * `trig` must rise EXACTLY at stream cycle fire+LATENCY (LATENCY=2) — the measured
//     probe->trig latency assert — and be exactly 1 cycle wide; trig_ext_o pulses with it;
//   * per-cycle cmp_hit compared against the model (same rigor as tb_trigger_cmp);
//   * after the capture completes, buffer[trig_index] must equal stim[fire] — the
//     host-visible trigger sample IS the probe sample that satisfied the final stage
//     (the alignment acceptance gate).
// Never-fires case: N cycles with zero trigs, then force_trig overrides (trig immediate,
// capture completes to DONE), then a re-armed pass proves trig_ext_i fires the capture
// while trig_ext_o stays silent (no cross-instance loop path).
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps
module tb_trigger_seq
  import scope_pkg::*;
;

  localparam int unsigned PROBE_W = 16;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned LATENCY = 2;  // documented scope_trigger latency (DESIGN.md)
  localparam int unsigned MAXC = 8;
  localparam int unsigned MAXS = 4096;
  localparam logic [63:0] NO_FIRE = 64'hFFFF_FFFF_FFFF_FFFF;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  // trigger engine
  logic [PROBE_W-1:0] probe = '0;
  logic run = 1'b0;
  logic force_trig_i = 1'b0, trig_ext_i = 1'b0;
  logic [4*PROBE_W-1:0] cmp_mask_i = '0, cmp_value_i = '0, cmp_edge_mask_i = '0,
                        cmp_edge_pol_i = '0;
  logic [31:0] trig_combine_i = '0;
  logic [4*32-1:0] seq_cnt_i = '0;
  logic trig, trig_ext_o;
  logic [PROBE_W-1:0] sample_o;
  logic [3:0] cmp_hit;

  scope_trigger #(
      .PROBE_W(PROBE_W)
  ) u_trig (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .run          (run),
      .force_trig   (force_trig_i),
      .trig_ext_i   (trig_ext_i),
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

  // capture core fed by the aligned sample path
  logic arm = 1'b0, disarm = 1'b0;
  logic [2:0] state;
  logic triggered, wrapped, armed;
  logic [7:0] windows_done;
  logic [DEPTH_LOG2-1:0] trig_index;
  logic [DEPTH_LOG2-1:0] rd_addr = '0;
  logic [PROBE_W-1:0] rd_data;
  logic [47:0] ts, ts_at_trig;

  scope_core #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_core (
      .clk         (clk),
      .rst         (rst),
      .sample_data (sample_o),
      .sample_valid(1'b1),
      .trig        (trig),
      .arm         (arm),
      .disarm      (disarm),
      .pretrig     ({DEPTH_LOG2{1'b0}}),
      .windows     (8'd1),
      .state       (state),
      .triggered   (triggered),
      .wrapped     (wrapped),
      .windows_done(windows_done),
      .trig_index  (trig_index),
      .armed       (armed),
      .rd_addr     (rd_addr),
      .rd_data     (rd_data),
      .win_rd_addr (8'h0),
      .win_rd_data (unused_win_meta),
      .ts          (ts),
      .ts_at_trig  (ts_at_trig)
  );

  logic [DEPTH_LOG2:0] unused_win_meta;

  logic [PROBE_W-1:0] stim[MAXC*MAXS];
  logic [3:0] hits[MAXC*MAXS];
  logic [63:0] cfg[MAXC*21];
  logic [63:0] meta[MAXC+2];
  initial begin
    $readmemh("sim/build/vectors/trig_seq_stim.mem", stim);
    $readmemh("sim/build/vectors/trig_seq_hits.mem", hits);
    $readmemh("sim/build/vectors/trig_seq_cfg.mem", cfg);
    $readmemh("sim/build/vectors/trig_seq_meta.mem", meta);
  end

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", msg);
  endtask

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

  // arm the core and wait until it is ARMED (pretrig=0: FILLING is one sample-free cycle)
  task automatic arm_core();
    @(negedge clk);
    arm = 1'b1;
    @(negedge clk);
    arm = 1'b0;
    while (state != 3'(SCOPE_ST_ARMED)) @(negedge clk);
  endtask

  task automatic wait_done_and_check(input logic [PROBE_W-1:0] want_sample,
                                     input bit check_content, input int unsigned c);
    int unsigned guard = 0;
    while (state != 3'(SCOPE_ST_DONE)) begin
      @(negedge clk);
      probe = PROBE_W'($urandom());  // keep the pipe moving with junk
      guard++;
      if (guard > 3 * (1 << DEPTH_LOG2) + 100) fail($sformatf("case %0d: no DONE", c));
    end
    if (triggered !== 1'b1) fail($sformatf("case %0d: triggered not set", c));
    if (armed !== 1'b0) fail($sformatf("case %0d: armed still set in DONE", c));
    if (wrapped !== 1'b1) fail($sformatf("case %0d: completed capture must set wrapped", c));
    if (windows_done !== 8'd1) fail($sformatf("case %0d: windows_done != 1", c));
    if (ts_at_trig > ts) fail($sformatf("case %0d: ts_at_trig ahead of ts", c));
    if (check_content) begin
      rd_addr = trig_index;
      @(negedge clk);
      @(negedge clk);
      if (rd_data !== want_sample)
        fail($sformatf("case %0d: buffer[trig_index]=%h != satisfying sample %h", c, rd_data,
                       want_sample));
    end
  endtask

  int unsigned ncases, spc;
  int fire_obs;

  initial begin
    repeat (5) @(negedge clk);
    rst = 1'b0;
    ncases = 32'(meta[0]);
    spc    = 32'(meta[1]);

    for (int unsigned c = 0; c < ncases; c++) begin
      automatic logic [63:0] fire_exp = meta[2+c];
      probe = '0;
      run   = 1'b0;
      load_cfg(c);
      repeat (3) @(negedge clk);
      arm_core();
      run = 1'b1;
      fire_obs = -1;

      for (int unsigned i = 0; i < spc; i++) begin
        @(negedge clk);
        // the cycle that just ended carried sample i-1
        if (i > 0 && cmp_hit !== hits[c*spc+i-1])
          fail($sformatf("case %0d sample %0d: cmp_hit %b != model %b", c, i - 1, cmp_hit,
                         hits[c*spc+i-1]));
        if (trig === 1'b1) begin
          if (fire_obs != -1) fail($sformatf("case %0d: trig wider than 1 cycle / refired", c));
          fire_obs = int'(i) - 1;
          if (trig_ext_o !== 1'b1) fail($sformatf("case %0d: trig_ext_o missing on fire", c));
        end else if (trig_ext_o !== 1'b0) begin
          fail($sformatf("case %0d: trig_ext_o without trig", c));
        end
        probe = stim[c*spc+i];
      end

      if (fire_exp == NO_FIRE) begin
        // never-fires: prove no deadlock, then force_trig override, then ext-trig path
        if (fire_obs != -1) fail($sformatf("case %0d: fired but model says never", c));
        force_trig_i = 1'b1;
        @(negedge clk);
        if (trig !== 1'b1) fail("force_trig did not fire trig");
        wait_done_and_check('0, 1'b0, c);
        force_trig_i = 1'b0;
        run = 1'b0;
        @(negedge clk);
        disarm = 1'b1;
        @(negedge clk);
        disarm = 1'b0;
        // ext-trig pass on the same never-fire config
        arm_core();
        run = 1'b1;
        trig_ext_i = 1'b1;
        @(negedge clk);
        if (trig !== 1'b1) fail("trig_ext_i did not fire trig");
        if (trig_ext_o !== 1'b0) fail("trig_ext_o echoed trig_ext_i (loop hazard)");
        trig_ext_i = 1'b0;
        wait_done_and_check('0, 1'b0, c);
      end else begin
        // Exact latency. Labeling: a signal registered at edge P_j carries label j (same
        // convention as the cmp_hit compare above). The satisfying sample's hit registers
        // at label fire; the fire pulse registers one edge later (label fire+1 = observed
        // here as fire_obs); the core CONSUMES trig at the next edge, P_{fire+LATENCY},
        // together with sample_o = stim[fire] — probe->trig-consumption latency = LATENCY.
        if (fire_obs == -1) fail($sformatf("case %0d: never fired, model says %0d", c, fire_exp));
        if (fire_obs != int'(fire_exp) + int'(LATENCY) - 1)
          fail($sformatf("case %0d: trig pulse at label %0d, want %0d+%0d-1", c, fire_obs,
                         fire_exp, LATENCY));
        // capture completes; the stored trigger sample is the satisfying sample
        wait_done_and_check(stim[c*spc+32'(fire_exp)], 1'b1, c);
      end

      run = 1'b0;
      @(negedge clk);
      disarm = 1'b1;
      @(negedge clk);
      disarm = 1'b0;
      repeat (3) @(negedge clk);
    end

    $display("-- %0d sequencer cases: latency=%0d asserted, trigger-sample alignment exact",
             ncases, LATENCY);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #50ms;
    fail("timeout");
  end

endmodule
