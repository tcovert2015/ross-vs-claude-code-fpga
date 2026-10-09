// tb_csr — scope_csr register-file matrix on the native CSR bus (issue #5).
//
// Two legs with different parameter sets (PROBE_W=32/DEPTH_LOG2=8/RLE_EN=0 and
// PROBE_W=512/DEPTH_LOG2=10/RLE_EN=1 — proves HWCFG is not hardcoded), each wiring
// scope_csr + scope_core together and driving the native bus directly (the #11 front-end
// adapters re-run this matrix). Per leg:
//   * ID magic/version and HWCFG field packing vs parameters; RO registers ignore writes;
//     CTRL reads as 0 (strobes self-clear).
//   * Full config walk: PRETRIG (incl. truncation to DEPTH_LOG2 bits), WINDOWS (incl. the
//     0 -> 1 clamp), RLE_CTRL, CMP_SEL + all 4 comparators x 4 fields x lanes via the lane
//     window (distinct pattern per lane; top-lane masking; unimplemented lanes read 0 and
//     drop writes), TRIG_COMBINE, SEQ_CNT0..3.
//   * TS_LO/TS_HI: 48-bit reads via the TS_LO-latched shadow, strictly increasing.
//   * cfg_err lockout: config writes while armed are ignored (read-back unchanged) and set
//     sticky STATUS.cfg_err; capture still completes; cfg_err clears only on soft_rst.
//   * force_trig via CTRL bit2, timed so the trigger sample is stimulus sample K =
//     DEPTH/2: capture drained via BUF_CTRL/BUF_DATA (lane-sequenced pops) and compared
//     word-for-word against the scope_ref.py golden .mem (same vectors as tb_capture_basic)
//     while poisoned samples keep streaming; TRIG_INDEX / TSTRIG_LO/HI / STATUS checked.
//   * soft_rst: cfg_err cleared, FSM back to IDLE, re-arm + disarm sanity.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_csr_leg
  import scope_pkg::*;
#(
    parameter int unsigned PROBE_W     = 32,
    parameter int unsigned DEPTH_LOG2  = 8,
    parameter bit          RLE_EN      = 1'b0,
    parameter int unsigned TRIG_SAMPLE = 128,
    parameter int unsigned N_STIM      = 640,
    parameter string       VEC_PREFIX  = "",
    parameter string       NAME        = "leg"
) (
    output bit done
);

  localparam int unsigned NUM_CMP = 4;
  localparam int unsigned SEQ_STAGES = 4;
  localparam int unsigned TS_W = 48;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned LANES = (PROBE_W + 31) / 32;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  // ---- DUTs: scope_csr + scope_core wired together --------------------------------------
  logic [7:0] csr_addr = '0;
  logic [31:0] csr_wdata = '0;
  logic csr_write = 1'b0, csr_read = 1'b0;
  logic [31:0] csr_rdata;

  logic arm, disarm, force_trig;
  logic [DEPTH_LOG2-1:0] pretrig;
  logic [7:0] windows;
  logic rle_enable;
  logic [2:0] state;
  logic triggered, wrapped, armed, cfg_err;
  logic [7:0] windows_done;
  logic [DEPTH_LOG2-1:0] trig_index;
  logic [TS_W-1:0] ts, ts_at_trig;
  logic [DEPTH_LOG2-1:0] buf_rd_addr;
  logic [PROBE_W-1:0] buf_rd_data;
  logic [NUM_CMP*PROBE_W-1:0] cmp_mask, cmp_value, cmp_edge_mask, cmp_edge_pol;
  logic [31:0] trig_combine;
  logic [SEQ_STAGES*32-1:0] seq_cnt;

  logic [PROBE_W-1:0] sample_data = '0;
  logic sample_valid = 1'b0;

  // force-write injection mux (stream-aligned CTRL.force_trig, see stream block)
  logic force_wr = 1'b0;
  wire [7:0] dut_addr = force_wr ? 8'(CSR_CTRL) : csr_addr;
  wire [31:0] dut_wdata = force_wr ? 32'h4 : csr_wdata;
  wire dut_write = force_wr | csr_write;

  scope_csr #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .NUM_CMP   (NUM_CMP),
      .SEQ_STAGES(SEQ_STAGES),
      .RLE_EN    (RLE_EN),
      .TS_W      (TS_W)
  ) u_csr (
      .clk          (clk),
      .rst          (rst),
      .csr_addr     (dut_addr),
      .csr_wdata    (dut_wdata),
      .csr_write    (dut_write),
      .csr_read     (csr_read),
      .csr_rdata    (csr_rdata),
      .arm          (arm),
      .disarm       (disarm),
      .force_trig   (force_trig),
      .pretrig      (pretrig),
      .windows      (windows),
      .rle_enable   (rle_enable),
      /* verilator lint_off PINCONNECTEMPTY */  // SMPL_CTRL outputs (#17/#20) unused in this TB
      .decim        (),
      .qual_en      (),
      .qual_sel     (),
      /* verilator lint_on PINCONNECTEMPTY */
      .state        (state),
      .triggered    (triggered),
      .wrapped      (wrapped),
      .windows_done (windows_done),
      .trig_index   (trig_index),
      .ts           (ts),
      .ts_at_trig   (ts_at_trig),
      .buf_rd_addr  (buf_rd_addr),
      .buf_rd_data  (buf_rd_data),
      .win_rd_addr  (win_rd_addr),
      .win_rd_data  (win_rd_data),
      .cmp_mask     (cmp_mask),
      .cmp_value    (cmp_value),
      .cmp_edge_mask(cmp_edge_mask),
      .cmp_edge_pol (cmp_edge_pol),
      .trig_combine (trig_combine),
      .seq_cnt      (seq_cnt),
      .cfg_err      (cfg_err)
  );

  scope_core #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .TS_W      (TS_W)
  ) u_core (
      .clk         (clk),
      .rst         (rst),
      .sample_data (sample_data),
      .sample_valid(sample_valid),
      .trig        (force_trig),
      .arm         (arm),
      .disarm      (disarm),
      .pretrig     (pretrig),
      .windows     (windows),
      .state       (state),
      .triggered   (triggered),
      .wrapped     (wrapped),
      .windows_done(windows_done),
      .trig_index  (trig_index),
      .armed       (armed),
      .rd_addr     (buf_rd_addr),
      .rd_data     (buf_rd_data),
      .win_rd_addr (win_rd_addr),
      .win_rd_data (win_rd_data),
      .ts          (ts),
      .ts_at_trig  (ts_at_trig)
  );

  logic [7:0] win_rd_addr;
  logic [DEPTH_LOG2:0] win_rd_data;

  // ---- golden vectors ----------------------------------------------------------------------
  logic [PROBE_W-1:0] stim[N_STIM];
  logic [PROBE_W-1:0] exp_buf[DEPTH];
  logic [63:0] exp_meta[3];
  initial begin
    $readmemh({VEC_PREFIX, "_stim.mem"}, stim);
    $readmemh({VEC_PREFIX, "_buf.mem"}, exp_buf);
    $readmemh({VEC_PREFIX, "_meta.mem"}, exp_meta);
  end

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // ---- CSR bus tasks (drive at negedge; sample combinational rdata mid-cycle, i.e. the
  //      value a synchronous master captures at the consuming posedge) ----------------------
  task automatic csr_wr(input logic [7:0] a, input logic [31:0] d);
    @(negedge clk);
    csr_addr  = a;
    csr_wdata = d;
    csr_write = 1'b1;
    @(negedge clk);
    csr_write = 1'b0;
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk);
    csr_addr = a;
    csr_read = 1'b1;
    #2;  // combinational rdata settled; no clock edge crossed since the negedge
    d = csr_rdata;
    @(negedge clk);
    csr_read = 1'b0;
  endtask

  task automatic csr_expect(input logic [7:0] a, input logic [31:0] want, input string what);
    logic [31:0] got;
    csr_rd(a, got);
    if (got !== want) fail($sformatf("%s: addr %0d read %h want %h", what, a, got, want));
  endtask

  // ---- sample stream + aligned force write ---------------------------------------------------
  // stim[idx] assigned at a negedge is consumed at the following posedge. force_wr raised in
  // the same negedge slot as stim[K-1] => CTRL.force write commits at stim[K-1]'s posedge =>
  // force_trig (registered pending) is high in stim[K]'s cycle => the trigger sample is
  // stim[K], matching scope_ref.py --trig-sample K.
  logic stream_en = 1'b0;
  int unsigned idx = 0;
  always @(negedge clk) begin
    if (stream_en) begin
      sample_data  <= (idx < N_STIM) ? stim[idx] : ~stim[idx%N_STIM];
      sample_valid <= 1'b1;
      force_wr     <= (idx == TRIG_SAMPLE - 1);
      idx          <= idx + 1;
    end else begin
      sample_valid <= 1'b0;
      force_wr     <= 1'b0;
    end
  end

  // ts at the accepted force-trigger cycle (for the TSTRIG readback check)
  logic [TS_W-1:0] ts_seen = '0;
  always @(posedge clk) begin
    if (force_trig && sample_valid && state == 3'(SCOPE_ST_ARMED)) ts_seen <= ts;
  end

  // distinct per-(field,cmp,lane) config pattern
  function automatic logic [31:0] cfg_pat(input int unsigned f, input int unsigned k,
                                          input int unsigned j);
    return 32'h5EED_0000 ^ (32'(f) << 24) ^ (32'(k) << 16) ^ (32'(j) << 8) ^ 32'(f * 7 + k * 3 + j);
  endfunction

  function automatic logic [31:0] lane_mask32(input int unsigned j);
    if (PROBE_W >= 32 * (j + 1)) return 32'hFFFF_FFFF;
    else if (PROBE_W <= 32 * j) return 32'h0;
    else return (32'h1 << (PROBE_W - 32 * j)) - 32'h1;
  endfunction

  // expected PROBE_W-wide field value assembled from the per-lane write patterns
  function automatic logic [PROBE_W-1:0] cfg_field_exp(input int unsigned f, input int unsigned k);
    logic [PROBE_W-1:0] r;
    logic [31:0] lane;
    r = '0;
    for (int unsigned j = 0; j < LANES; j++) begin
      lane = cfg_pat(f, k, j) & lane_mask32(j);
      r |= PROBE_W'(lane) << (32 * j);
    end
    return r;
  endfunction

  logic [31:0] v, v2;
  logic [63:0] ts_a, ts_b;

  initial begin
    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // ---- identity / RO behavior ---------------------------------------------------------
    csr_expect(8'(CSR_ID), SCOPE_ID_REG, "ID");
    csr_wr(8'(CSR_ID), 32'hDEAD_BEEF);
    csr_expect(8'(CSR_ID), SCOPE_ID_REG, "ID after write (RO)");
    csr_expect(8'(CSR_HWCFG), {13'h0, RLE_EN, 4'(NUM_CMP), 4'(DEPTH_LOG2), 10'(PROBE_W)},
               "HWCFG");
    csr_wr(8'(CSR_HWCFG), 32'hFFFF_FFFF);
    csr_expect(8'(CSR_HWCFG), {13'h0, RLE_EN, 4'(NUM_CMP), 4'(DEPTH_LOG2), 10'(PROBE_W)},
               "HWCFG after write (RO)");
    csr_expect(8'(CSR_CTRL), 32'h0, "CTRL reads 0");
    csr_expect(8'(CSR_STATUS), 32'h0, "STATUS idle/clean");

    // ---- config walk (IDLE) ---------------------------------------------------------------
    csr_wr(8'(CSR_PRETRIG), 32'hFFFF_FFFF);
    csr_expect(8'(CSR_PRETRIG), 32'(DEPTH - 1), "PRETRIG truncates to DEPTH_LOG2 bits");
    csr_wr(8'(CSR_PRETRIG), 32'd17);
    csr_expect(8'(CSR_PRETRIG), 32'd17, "PRETRIG");
    csr_wr(8'(CSR_WINDOWS), 32'h0);
    csr_expect(8'(CSR_WINDOWS), 32'd1, "WINDOWS 0 clamps to 1");
    csr_wr(8'(CSR_WINDOWS), 32'h7B);  // 123 <= DEPTH/2 for both legs (#7 range check)
    csr_expect(8'(CSR_WINDOWS), 32'h7B, "WINDOWS");
    csr_wr(8'(CSR_RLE_CTRL), 32'h3);
    csr_expect(8'(CSR_RLE_CTRL), 32'h1, "RLE_CTRL bit0 only");
    if (rle_enable !== 1'b1) fail("rle_enable output");

    // comparator matrix: all fields x comparators x window lanes
    for (int unsigned f = 0; f < 4; f++) begin
      for (int unsigned k = 0; k < NUM_CMP; k++) begin
        csr_wr(8'(CSR_CMP_SEL), 32'((f << 2) | k));
        csr_expect(8'(CSR_CMP_SEL), 32'((f << 2) | k), "CMP_SEL");
        for (int unsigned j = 0; j < CSR_CMP_LANE_WORDS; j++) begin
          csr_wr(8'(CSR_CMP_LANE_BASE + j), cfg_pat(f, k, j));
        end
      end
    end
    for (int unsigned f = 0; f < 4; f++) begin
      for (int unsigned k = 0; k < NUM_CMP; k++) begin
        csr_wr(8'(CSR_CMP_SEL), 32'((f << 2) | k));
        for (int unsigned j = 0; j < CSR_CMP_LANE_WORDS; j++) begin
          csr_expect(8'(CSR_CMP_LANE_BASE + j), cfg_pat(f, k, j) & lane_mask32(j),
                     $sformatf("CMP lane f=%0d k=%0d j=%0d", f, k, j));
        end
      end
    end
    // flat config outputs (the #6 trigger-engine surface) must mirror the map exactly
    for (int unsigned k = 0; k < NUM_CMP; k++) begin
      if (cmp_mask[k*PROBE_W+:PROBE_W] !== cfg_field_exp(0, k)) fail("cmp_mask flat output");
      if (cmp_value[k*PROBE_W+:PROBE_W] !== cfg_field_exp(1, k)) fail("cmp_value flat output");
      if (cmp_edge_mask[k*PROBE_W+:PROBE_W] !== cfg_field_exp(2, k))
        fail("cmp_edge_mask flat output");
      if (cmp_edge_pol[k*PROBE_W+:PROBE_W] !== cfg_field_exp(3, k))
        fail("cmp_edge_pol flat output");
    end

    csr_wr(8'(CSR_TRIG_COMBINE), 32'hCAFE_F00D);
    csr_expect(8'(CSR_TRIG_COMBINE), 32'hCAFE_F00D, "TRIG_COMBINE");
    if (trig_combine !== 32'hCAFE_F00D) fail("trig_combine flat output");
    for (int unsigned n = 0; n < SEQ_STAGES; n++) begin
      csr_wr(8'(CSR_SEQ_CNT_BASE + n), 32'h1000_0000 + 32'(n));
      csr_expect(8'(CSR_SEQ_CNT_BASE + n), 32'h1000_0000 + 32'(n), "SEQ_CNT");
      if (seq_cnt[n*32+:32] !== 32'h1000_0000 + 32'(n)) fail("seq_cnt flat output");
    end

    // reserved address: reads 0, write ignored, no cfg_err
    csr_wr(8'd40, 32'h1234_5678);
    csr_expect(8'd40, 32'h0, "reserved reads 0");
    csr_rd(8'(CSR_STATUS), v);
    if (v[5] !== 1'b0) fail("cfg_err set by reserved write");

    // ---- TS coherent reads, strictly increasing ------------------------------------------
    csr_rd(8'(CSR_TS_LO), v);
    csr_rd(8'(CSR_TS_HI), v2);
    ts_a = {v2, v};
    repeat (3) @(negedge clk);
    csr_rd(8'(CSR_TS_LO), v);
    csr_rd(8'(CSR_TS_HI), v2);
    ts_b = {v2, v};
    if (!(ts_b > ts_a)) fail($sformatf("TS not increasing: %0d then %0d", ts_a, ts_b));
    if (ts_b - ts_a > 64'd100) fail("TS delta implausible");

    // ---- capture: arm, cfg_err lockout, aligned force_trig, drain ------------------------
    csr_wr(8'(CSR_PRETRIG), 32'd0);
    csr_wr(8'(CSR_WINDOWS), 32'd1);
    csr_wr(8'(CSR_CMP_SEL), 32'h0);  // point the lane window at MASK/comparator 0 (in IDLE)
    csr_wr(8'(CSR_CTRL), 32'h1);  // arm
    do csr_rd(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_ARMED));

    // locked config writes: ignored + sticky cfg_err
    csr_wr(8'(CSR_PRETRIG), 32'd99);
    csr_expect(8'(CSR_PRETRIG), 32'd0, "PRETRIG write locked while armed");
    csr_rd(8'(CSR_STATUS), v);
    if (v[5] !== 1'b1) fail("cfg_err not set by locked PRETRIG write");
    if (cfg_err !== 1'b1) fail("cfg_err output wire vs STATUS bit");
    csr_wr(8'(CSR_CMP_SEL), 32'h5);  // locked: selector must not move
    csr_expect(8'(CSR_CMP_SEL), 32'h0, "CMP_SEL write locked while armed");
    csr_wr(8'(CSR_CMP_LANE_BASE), 32'hFFFF_FFFF);
    csr_expect(8'(CSR_CMP_LANE_BASE), cfg_pat(0, 0, 0) & lane_mask32(0),
               "CMP lane write locked while armed");
    csr_wr(8'(CSR_SEQ_CNT_BASE), 32'd0);
    csr_expect(8'(CSR_SEQ_CNT_BASE), 32'h1000_0000, "SEQ_CNT write locked while armed");

    // stream samples; the stream block injects the CTRL.force_trig write at K-1
    stream_en = 1'b1;
    do csr_rd(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_DONE));

    // status + trigger metadata
    csr_rd(8'(CSR_STATUS), v);
    if (v[3] !== 1'b1) fail("STATUS.triggered");
    if (v[4] !== exp_meta[1][0]) fail("STATUS.wrapped vs model");
    if (v[5] !== 1'b1) fail("cfg_err lost during capture (must be sticky)");
    if (v[15:8] !== 8'd1) fail("STATUS.windows_done");
    csr_expect(8'(CSR_TRIG_INDEX), 32'(exp_meta[0]), "TRIG_INDEX vs model");
    csr_rd(8'(CSR_TSTRIG_LO), v);
    csr_rd(8'(CSR_TSTRIG_HI), v2);
    if ({v2[15:0], v} !== 48'(ts_seen)) fail("TSTRIG_LO/HI vs observed trigger cycle ts");

    // drain while poison keeps streaming (write pointer must be frozen in DONE)
    csr_wr(8'(CSR_BUF_CTRL), 32'h1);
    @(negedge clk);
    for (int unsigned a = 0; a < DEPTH; a++) begin
      for (int unsigned j = 0; j < LANES; j++) begin
        csr_rd(8'(CSR_BUF_DATA), v);
        if (v !== (32'(exp_buf[a] >> (32 * j)) & lane_mask32(j)))
          fail($sformatf("BUF_DATA sample %0d lane %0d: got %h want %h", a, j, v,
                         32'(exp_buf[a] >> (32 * j)) & lane_mask32(j)));
      end
    end
    stream_en = 1'b0;

    // ---- soft_rst: clears cfg_err, back to IDLE; re-arm sanity ---------------------------
    csr_wr(8'(CSR_CTRL), 32'h8);  // soft_rst
    csr_rd(8'(CSR_STATUS), v);
    if (v[2:0] !== 3'(SCOPE_ST_IDLE)) fail("soft_rst did not return to IDLE");
    if (v[5] !== 1'b0) fail("soft_rst did not clear cfg_err");
    csr_wr(8'(CSR_PRETRIG), 32'd3);  // accepted again in IDLE, no cfg_err
    csr_expect(8'(CSR_PRETRIG), 32'd3, "PRETRIG writable after soft_rst");
    csr_rd(8'(CSR_STATUS), v);
    if (v[5] !== 1'b0) fail("cfg_err set by legal IDLE write");
    csr_wr(8'(CSR_CTRL), 32'h1);  // arm
    csr_rd(8'(CSR_STATUS), v);
    if (v[2:0] == 3'(SCOPE_ST_IDLE)) fail("arm after soft_rst did not start");
    if (armed !== 1'b1) fail("armed status output not set while FILLING/ARMED");
    csr_wr(8'(CSR_CTRL), 32'h2);  // disarm
    csr_rd(8'(CSR_STATUS), v);
    if (v[2:0] !== 3'(SCOPE_ST_IDLE)) fail("disarm did not return to IDLE");

    $display("-- [%s] CSR matrix + lockout + %0d-word lane-sequenced drain clean", NAME,
             DEPTH * LANES);
    done = 1'b1;
  end

endmodule
/* verilator lint_on DECLFILENAME */

module tb_csr;

  bit done_a, done_b;

  tb_csr_leg #(
      .PROBE_W    (32),
      .DEPTH_LOG2 (8),
      .RLE_EN     (1'b0),
      .TRIG_SAMPLE(128),
      .N_STIM     (640),
      .VEC_PREFIX ("sim/build/vectors/cap_w32_d8"),
      .NAME       ("w32_d8")
  ) leg_a (
      .done(done_a)
  );

  tb_csr_leg #(
      .PROBE_W    (512),
      .DEPTH_LOG2 (10),
      .RLE_EN     (1'b1),
      .TRIG_SAMPLE(512),
      .N_STIM     (2560),
      .VEC_PREFIX ("sim/build/vectors/cap_w512_d10"),
      .NAME       ("w512_d10")
  ) leg_b (
      .done(done_b)
  );

  initial begin
    wait (done_a && done_b);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #50ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout: done=%b%b", done_a, done_b);
  end

endmodule
