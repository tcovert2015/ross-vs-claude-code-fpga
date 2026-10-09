// tb_windows — multi-window capture: slicing, metadata, disarm, cfg_err bound (issue #7).
//
// WINDOWS in {1, 2, 3, 5, 8} at DEPTH_LOG2=8, PRETRIG=64, against scope_ref.py's
// windows_model vectors (run.sh gen_vectors): distinct per-window trigger events at the
// model-chosen absolute cycles (incl. rel=0 = trigger on a window's first ARMED sample),
// with the natural re-arm gaps (FILLING refill) between windows. Verified per sub-run:
//   * final state parks in DONE with windows_done == WINDOWS; triggered/wrapped/trig_index
//     reflect the last window;
//   * the used buffer region [0, WINDOWS*SLICE) is bit-exact vs the model (each window
//     confined to its slice);
//   * the per-window {wrapped, trig_index} sideband table matches the model, window by
//     window, via the win_rd_addr/win_rd_data port.
// Then: disarm mid-sequence (after 2 of 5 windows) returns to IDLE with windows_done==2;
// and a scope_csr instance proves WINDOWS > DEPTH/2 is rejected with cfg_err while an
// in-range value is accepted.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps
module tb_windows
  import scope_pkg::*;
;

  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned PRETRIG = 64;
  localparam int unsigned MAXS = 4096;
  localparam int unsigned NRUNS = 5;
  localparam int unsigned WLIST[NRUNS] = '{1, 2, 3, 5, 8};

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic [PROBE_W-1:0] sample_data = '0;
  logic sample_valid = 1'b0;
  logic trig = 1'b0, arm = 1'b0, disarm = 1'b0;
  logic [7:0] windows = 8'd1;
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
      .pretrig     (DEPTH_LOG2'(PRETRIG)),
      .windows     (windows),
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

  wire unused_outputs = &{1'b0, armed, ts, ts_at_trig};

  logic [PROBE_W-1:0] stim[MAXS];
  logic [PROBE_W-1:0] exp_buf[DEPTH];
  logic [63:0] exp_meta[2+3*8];

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", msg);
  endtask

  function automatic int unsigned weff_log2_of(input int unsigned w);
    weff_log2_of = 0;
    while ((1 << weff_log2_of) < w) weff_log2_of++;
    if (weff_log2_of > DEPTH_LOG2 - 1) weff_log2_of = DEPTH_LOG2 - 1;
  endfunction

  // run one armed multi-window capture, driving trig at the model-chosen absolute cycles;
  // stop_after_windows < W aborts with disarm once windows_done reaches it (else runs out)
  task automatic run_windows(input int unsigned W, input int unsigned stop_after);
    automatic int unsigned cycles = 32'(exp_meta[1]);
    automatic int unsigned nexttrig = 0;
    @(negedge clk);
    arm = 1'b1;
    @(negedge clk);
    arm = 1'b0;
    sample_valid = 1'b1;
    for (int unsigned k = 0; k < cycles; k++) begin
      if (stop_after < W && windows_done == 8'(stop_after)) break;
      sample_data = stim[k];
      trig = (nexttrig < W) && (k == 32'(exp_meta[2+3*nexttrig]));
      if (trig) nexttrig++;
      @(negedge clk);
    end
    sample_valid = 1'b0;
    trig = 1'b0;
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    for (int unsigned r = 0; r < NRUNS; r++) begin
      automatic int unsigned W = WLIST[r];
      automatic int unsigned slice = DEPTH >> weff_log2_of(W);
      automatic string pfx = $sformatf("sim/build/vectors/win_w%0d", W);
      $readmemh({pfx, "_stim.mem"}, stim);
      $readmemh({pfx, "_buf.mem"}, exp_buf);
      $readmemh({pfx, "_meta.mem"}, exp_meta);
      windows = 8'(W);

      run_windows(W, W + 1);
      @(negedge clk);

      // final status: parked in DONE, all windows counted, last window's metadata live
      if (state !== 3'(SCOPE_ST_DONE)) fail($sformatf("W=%0d: not parked in DONE", W));
      if (windows_done !== 8'(W)) fail($sformatf("W=%0d: windows_done=%0d", W, windows_done));
      if (triggered !== 1'b1) fail($sformatf("W=%0d: triggered not set", W));
      if (trig_index !== DEPTH_LOG2'(exp_meta[2+3*(W-1)+1]))
        fail($sformatf("W=%0d: live trig_index vs model", W));
      if (wrapped !== exp_meta[2+3*(W-1)+2][0])
        fail($sformatf("W=%0d: live wrapped vs model", W));

      // used buffer region bit-exact vs model
      for (int unsigned a = 0; a < W * slice; a++) begin
        rd_addr = DEPTH_LOG2'(a);
        @(negedge clk);
        @(negedge clk);
        if (rd_data !== exp_buf[a])
          fail($sformatf("W=%0d: buffer[%0d]=%h != model %h", W, a, rd_data, exp_buf[a]));
      end

      // per-window sideband metadata table
      for (int unsigned w = 0; w < W; w++) begin
        win_rd_addr = 8'(w);
        @(negedge clk);
        @(negedge clk);
        if (win_rd_data !== {exp_meta[2+3*w+2][0], DEPTH_LOG2'(exp_meta[2+3*w+1])})
          fail($sformatf("W=%0d window %0d: meta table {wrapped,trig_index} mismatch", W, w));
      end

      @(negedge clk);
      disarm = 1'b1;
      @(negedge clk);
      disarm = 1'b0;
      repeat (3) @(negedge clk);
      $display("-- W=%0d (slice=%0d): buffer + per-window metadata exact", W, slice);
    end

    // ---- disarm mid-sequence: stop after 2 of 5 windows ---------------------------------
    begin
      $readmemh("sim/build/vectors/win_w5_stim.mem", stim);
      $readmemh("sim/build/vectors/win_w5_meta.mem", exp_meta);
      windows = 8'd5;
      run_windows(5, 2);
      @(negedge clk);
      disarm = 1'b1;
      @(negedge clk);
      disarm = 1'b0;
      @(negedge clk);
      if (state !== 3'(SCOPE_ST_IDLE)) fail("mid-sequence disarm did not return to IDLE");
      if (windows_done !== 8'd2) fail($sformatf("windows_done=%0d after 2-window abort",
                                                windows_done));
      $display("-- mid-sequence disarm: IDLE with windows_done=2");
    end

    $display("TB_RESULT: PASS");
    $finish;
  end

  // ---- cfg_err bound: WINDOWS > DEPTH/2 rejected (scope_csr owns the validation) --------
  logic [7:0] csr_addr = '0;
  logic [31:0] csr_wdata = '0;
  logic csr_write = 1'b0, csr_read = 1'b0;
  logic [31:0] csr_rdata;
  logic csr_cfg_err;
  logic [7:0] csr_windows;
  logic unused_csr_arm, unused_csr_disarm, unused_csr_force, unused_csr_rle;
  logic [DEPTH_LOG2-1:0] unused_csr_pretrig;
  logic [DEPTH_LOG2-1:0] unused_csr_buf_addr;
  logic [7:0] unused_csr_win_addr;
  logic [4*PROBE_W-1:0] unused_csr_m, unused_csr_v, unused_csr_em, unused_csr_ep;
  logic [31:0] unused_csr_comb;
  logic [4*32-1:0] unused_csr_seq;

  scope_csr #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_csr (
      .clk          (clk),
      .rst          (rst),
      .csr_addr     (csr_addr),
      .csr_wdata    (csr_wdata),
      .csr_write    (csr_write),
      .csr_read     (csr_read),
      .csr_rdata    (csr_rdata),
      .arm          (unused_csr_arm),
      .disarm       (unused_csr_disarm),
      .force_trig   (unused_csr_force),
      .pretrig      (unused_csr_pretrig),
      .windows      (csr_windows),
      .rle_enable   (unused_csr_rle),
      /* verilator lint_off PINCONNECTEMPTY */  // SMPL_CTRL outputs (#17/#20) unused in this TB
      .decim        (),
      .qual_en      (),
      .qual_sel     (),
      /* verilator lint_on PINCONNECTEMPTY */
      .state        (3'(SCOPE_ST_IDLE)),
      .triggered    (1'b0),
      .wrapped      (1'b0),
      .windows_done (8'h0),
      .trig_index   ({DEPTH_LOG2{1'b0}}),
      .ts           (48'h0),
      .ts_at_trig   (48'h0),
      .buf_rd_addr  (unused_csr_buf_addr),
      .buf_rd_data  ({PROBE_W{1'b0}}),
      .win_rd_addr  (unused_csr_win_addr),
      .win_rd_data  ({(DEPTH_LOG2+1){1'b0}}),
      .cmp_mask     (unused_csr_m),
      .cmp_value    (unused_csr_v),
      .cmp_edge_mask(unused_csr_em),
      .cmp_edge_pol (unused_csr_ep),
      .trig_combine (unused_csr_comb),
      .seq_cnt      (unused_csr_seq),
      .cfg_err      (csr_cfg_err)
  );

  initial begin
    @(negedge rst);
    repeat (3) @(negedge clk);
    // in-range accepted, no cfg_err
    csr_addr  = 8'(CSR_WINDOWS);
    csr_wdata = 32'd100;
    csr_write = 1'b1;
    @(negedge clk);
    csr_write = 1'b0;
    @(negedge clk);
    if (csr_windows !== 8'd100) fail("csr: in-range WINDOWS write not accepted");
    if (csr_cfg_err !== 1'b0) fail("csr: cfg_err set by in-range WINDOWS");
    // out of range (DEPTH/2 = 128): rejected + cfg_err
    csr_wdata = 32'd200;
    csr_write = 1'b1;
    @(negedge clk);
    csr_write = 1'b0;
    @(negedge clk);
    if (csr_windows !== 8'd100) fail("csr: out-of-range WINDOWS write not rejected");
    if (csr_cfg_err !== 1'b1) fail("csr: cfg_err not set by WINDOWS > DEPTH/2");
    csr_read = 1'b1;
    csr_addr = 8'(CSR_WINDOWS);
    #2;
    if (csr_rdata !== 32'd100) fail("csr: WINDOWS readback changed by rejected write");
    @(negedge clk);
    csr_read = 1'b0;
    $display("-- cfg_err bound: WINDOWS>DEPTH/2 rejected, in-range accepted");
  end

  initial begin
    #50ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout");
  end

endmodule
