// tb_csr_if — CSR register matrix through the Avalon-MM and AXI4-Lite front-ends (issue #11).
//
// The native-bus matrix is proven in tb_csr. This TB re-runs one SHARED matrix body through
// scope_avalon and scope_axil (a `BUS`-parameterized leg + bus-abstract bwrite/bread tasks), so
// the thin adapters are proven to carry every register class, the CTRL strobes, the cfg_err
// lockout, and — the place thin adapters break — the BUF_DATA pop-on-read side effect.
//
// BUF_DATA check without a golden buffer: sample_data is a free-running 8-bit counter stored by
// a contiguous, every-cycle write pointer, so buffer[addr] is linear in addr; DEPTH pops must
// return v[i] == (v[0]+i) mod 256. A double-pop or missed pop breaks the run.
//
/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_csr_if_leg
  import scope_pkg::*;
#(
    parameter int unsigned BUS        = 1,     // 1 = Avalon-MM, 2 = AXI4-Lite
    parameter int unsigned PROBE_W    = 8,
    parameter int unsigned DEPTH_LOG2 = 8,
    parameter string       NAME       = "leg"
) (
    output bit done,
    output int unsigned errs
);
  localparam int unsigned NUM_CMP = 4, SEQ_STAGES = 4, TS_W = 48;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  // native CSR bus (adapter -> scope_csr)
  logic [7:0]  csr_addr;
  logic [31:0] csr_wdata;
  logic        csr_write, csr_read;
  logic [31:0] csr_rdata;

  // core wiring
  logic arm, disarm, force_trig;
  logic [DEPTH_LOG2-1:0] pretrig;
  logic [7:0] windows, windows_done;
  logic rle_enable;
  logic [2:0] state;
  logic triggered, wrapped, armed, cfg_err;
  logic [DEPTH_LOG2-1:0] trig_index;
  logic [TS_W-1:0] ts, ts_at_trig;
  logic [DEPTH_LOG2-1:0] buf_rd_addr;
  logic [PROBE_W-1:0] buf_rd_data;
  logic [7:0] win_rd_addr;
  logic [DEPTH_LOG2:0] win_rd_data;
  logic [NUM_CMP*PROBE_W-1:0] cmp_mask, cmp_value, cmp_edge_mask, cmp_edge_pol;
  logic [31:0] trig_combine;
  logic [SEQ_STAGES*32-1:0] seq_cnt;

  // sample stream: free-running counter, valid every cycle during capture
  logic [PROBE_W-1:0] sample_data = '0;
  logic sample_valid = 1'b0;
  always_ff @(posedge clk) if (sample_valid) sample_data <= sample_data + 1'b1;

  // ---- Avalon-MM front-end signals ----
  logic [7:0]  av_addr = '0;
  logic        av_read = 1'b0, av_write = 1'b0;
  logic [31:0] av_wdata = '0, av_rdata;
  logic        av_wait;

  // ---- AXI4-Lite front-end signals ----
  logic [9:0]  ax_awaddr = '0, ax_araddr = '0;
  logic        ax_awvalid = 1'b0, ax_wvalid = 1'b0, ax_bready = 1'b0;
  logic        ax_arvalid = 1'b0, ax_rready = 1'b0;
  logic [31:0] ax_wdata = '0, ax_rdata;
  logic        ax_awready, ax_wready, ax_bvalid, ax_arready, ax_rvalid;
  logic [1:0]  ax_bresp, ax_rresp;

  generate
    if (BUS == 1) begin : g_avalon
      scope_avalon u_if (
          .address(av_addr), .read(av_read), .readdata(av_rdata),
          .write(av_write), .writedata(av_wdata), .waitrequest(av_wait),
          .csr_addr(csr_addr), .csr_wdata(csr_wdata), .csr_write(csr_write),
          .csr_read(csr_read), .csr_rdata(csr_rdata));
      // AXI outputs unused in this leg — tie off (no UNDRIVEN)
      assign ax_awready = 1'b0; assign ax_wready = 1'b0; assign ax_bvalid = 1'b0;
      assign ax_arready = 1'b0; assign ax_rvalid = 1'b0;
      assign ax_bresp = 2'b0;  assign ax_rresp = 2'b0;  assign ax_rdata = 32'b0;
    end else begin : g_axil
      scope_axil u_if (
          .clk(clk), .rst(rst),
          .awaddr(ax_awaddr), .awvalid(ax_awvalid), .awready(ax_awready),
          .wdata(ax_wdata), .wstrb(4'hF), .wvalid(ax_wvalid), .wready(ax_wready),
          .bresp(ax_bresp), .bvalid(ax_bvalid), .bready(ax_bready),
          .araddr(ax_araddr), .arvalid(ax_arvalid), .arready(ax_arready),
          .rdata(ax_rdata), .rresp(ax_rresp), .rvalid(ax_rvalid), .rready(ax_rready),
          .csr_addr(csr_addr), .csr_wdata(csr_wdata), .csr_write(csr_write),
          .csr_read(csr_read), .csr_rdata(csr_rdata));
      // Avalon outputs unused in this leg — tie off (no UNDRIVEN)
      assign av_rdata = 32'b0; assign av_wait = 1'b0;
    end
  endgenerate

  scope_csr #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .NUM_CMP(NUM_CMP),
              .SEQ_STAGES(SEQ_STAGES), .RLE_EN(1'b0), .TS_W(TS_W)) u_csr (
      .clk(clk), .rst(rst),
      .csr_addr(csr_addr), .csr_wdata(csr_wdata), .csr_write(csr_write),
      .csr_read(csr_read), .csr_rdata(csr_rdata),
      .arm(arm), .disarm(disarm), .force_trig(force_trig), .pretrig(pretrig),
      .windows(windows), .rle_enable(rle_enable),
      /* verilator lint_off PINCONNECTEMPTY */
      .decim(), .qual_en(), .qual_sel(),        // SMPL_CTRL outputs (#17/#20) unused in this TB
      /* verilator lint_on PINCONNECTEMPTY */
      .state(state), .triggered(triggered),
      .wrapped(wrapped), .windows_done(windows_done), .trig_index(trig_index),
      .ts(ts), .ts_at_trig(ts_at_trig), .buf_rd_addr(buf_rd_addr), .buf_rd_data(buf_rd_data),
      .win_rd_addr(win_rd_addr), .win_rd_data(win_rd_data),
      .cmp_mask(cmp_mask), .cmp_value(cmp_value), .cmp_edge_mask(cmp_edge_mask),
      .cmp_edge_pol(cmp_edge_pol), .trig_combine(trig_combine), .seq_cnt(seq_cnt),
      .cfg_err(cfg_err));

  scope_core #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .TS_W(TS_W)) u_core (
      .clk(clk), .rst(rst), .sample_data(sample_data), .sample_valid(sample_valid),
      .trig(force_trig), .arm(arm), .disarm(disarm), .pretrig(pretrig), .windows(windows),
      .state(state), .triggered(triggered), .wrapped(wrapped), .windows_done(windows_done),
      .trig_index(trig_index), .armed(armed), .rd_addr(buf_rd_addr), .rd_data(buf_rd_data),
      .win_rd_addr(win_rd_addr), .win_rd_data(win_rd_data), .ts(ts), .ts_at_trig(ts_at_trig));

  // trigger config outputs are unused here (matrix only reads them back via CSR)
  // one bus is active per leg; sink the other bus's TB-driven / adapter signals so an unused
  // generate branch does not trip UNUSEDSIGNAL (both sets referenced ⇒ -Wall clean either way).
  wire _unused = &{1'b0, cmp_mask, cmp_value, cmp_edge_mask, cmp_edge_pol, trig_combine,
                   seq_cnt, armed, triggered, wrapped, trig_index, ts, ts_at_trig,
                   windows_done, rle_enable, disarm, arm,
                   av_addr, av_read, av_write, av_wdata, av_rdata, av_wait, cfg_err, rd,
                   ax_awaddr, ax_araddr, ax_awvalid, ax_wvalid, ax_bready, ax_arvalid,
                   ax_rready, ax_wdata, ax_rdata, ax_awready, ax_wready, ax_bvalid,
                   ax_arready, ax_rvalid, ax_bresp, ax_rresp};

  int unsigned errors = 0;
  task automatic fail(input string m);
    $display("TB_RESULT: FAIL"); $display("[%s] %s", NAME, m); errors++;
  endtask

  // ---- bus-abstract write/read (aw_first: 0 = W first, 1 = AW first, 2 = simultaneous) ----
  task automatic bwrite(input logic [7:0] word, input logic [31:0] d, input int aw_first = 2);
    if (BUS == 1) begin
      @(negedge clk); av_addr = word; av_wdata = d; av_write = 1'b1;
      @(posedge clk); #1 av_write = 1'b0;
    end else begin
      if (aw_first == 1) begin
        @(negedge clk); ax_awaddr = {word, 2'b00}; ax_awvalid = 1'b1;
        @(negedge clk); ax_wdata = d; ax_wvalid = 1'b1;
      end else if (aw_first == 0) begin
        @(negedge clk); ax_wdata = d; ax_wvalid = 1'b1;
        @(negedge clk); ax_awaddr = {word, 2'b00}; ax_awvalid = 1'b1;
      end else begin
        @(negedge clk); ax_awaddr = {word, 2'b00}; ax_awvalid = 1'b1; ax_wdata = d; ax_wvalid = 1'b1;
      end
      // wait for joint accept
      do @(posedge clk); while (!(ax_awready && ax_wready));
      #1 ax_awvalid = 1'b0; ax_wvalid = 1'b0;
      ax_bready = 1'b1;
      do @(posedge clk); while (!ax_bvalid);
      #1 ax_bready = 1'b0;
    end
  endtask

  task automatic bread(input logic [7:0] word, output logic [31:0] d);
    if (BUS == 1) begin
      // mirror the native csr_rd phase exactly (read spans one posedge, negedge..negedge) so the
      // registered-RAM BUF_DATA pre-fetch is valid — scope_avalon is a combinational rename.
      @(negedge clk); av_addr = word; av_read = 1'b1;
      #2 d = av_rdata;               // combinational readdata, settled, no edge crossed
      @(negedge clk); av_read = 1'b0;   // one native csr_read cycle -> one BUF_DATA pop
    end else begin
      @(negedge clk); ax_araddr = {word, 2'b00}; ax_arvalid = 1'b1;
      do @(posedge clk); while (!ax_arready);   // AR accepted -> one csr_read pulse
      #1 ax_arvalid = 1'b0; ax_rready = 1'b1;
      do @(posedge clk); while (!ax_rvalid);
      #1 d = ax_rdata; ax_rready = 1'b0;
    end
  endtask

  task automatic bexpect(input logic [7:0] word, input logic [31:0] want, input string what);
    logic [31:0] got; bread(word, got);
    if (got !== want) fail($sformatf("%s @%0d: got %h want %h", what, word, got, want));
  endtask

  logic [31:0] rd, id_val, hwcfg_val;
  task automatic run_matrix;
    // --- RO registers reject writes and read stable ---
    bread(8'(CSR_ID), id_val);
    if ((id_val & 32'hFFFF_F000) != SCOPE_ID_MAGIC) fail($sformatf("ID magic %h", id_val));
    bwrite(8'(CSR_ID), 32'hDEAD_BEEF); bexpect(8'(CSR_ID), id_val, "ID RO");
    bread(8'(CSR_HWCFG), hwcfg_val);
    bwrite(8'(CSR_HWCFG), 32'h0); bexpect(8'(CSR_HWCFG), hwcfg_val, "HWCFG RO");

    // --- R/W scalar registers walk ---
    bwrite(8'(CSR_PRETRIG), 32'h0000_002A); bexpect(8'(CSR_PRETRIG), 32'h2A, "PRETRIG");
    bwrite(8'(CSR_WINDOWS), 32'h0000_0003); bexpect(8'(CSR_WINDOWS), 32'h3, "WINDOWS");
    bwrite(8'(CSR_RLE_CTRL), 32'h1); bexpect(8'(CSR_RLE_CTRL), 32'h1, "RLE_CTRL RW bit0");
    bwrite(8'(CSR_RLE_CTRL), 32'h0); bexpect(8'(CSR_RLE_CTRL), 32'h0, "RLE_CTRL clear");
    bwrite(8'(CSR_TRIG_COMBINE), 32'hA5A5_1234); bexpect(8'(CSR_TRIG_COMBINE), 32'hA5A5_1234, "TRIG_COMBINE");
    for (int n = 0; n < 4; n++) begin
      bwrite(8'(CSR_SEQ_CNT_BASE + n), 32'h1000_0000 + n);
      bexpect(8'(CSR_SEQ_CNT_BASE + n), 32'h1000_0000 + n, $sformatf("SEQ_CNT%0d", n));
    end

    // --- comparator lane window (CMP_SEL selects k+field; lane 0 window) ---
    for (int k = 0; k < 4; k++) begin
      bwrite(8'(CSR_CMP_SEL), 32'(k));          // field 0 = MASK
      bwrite(8'(CSR_CMP_LANE_BASE), 32'hFF & (32'hC3 + k));
      bwrite(8'(CSR_CMP_SEL), 32'(k));
      bexpect(8'(CSR_CMP_LANE_BASE), 32'hFF & (32'hC3 + k), $sformatf("CMP%0d MASK lane0", k));
    end

    // --- AXI4-Lite AW/W arrival-order independence (BUS==2) + back-to-back reads ---
    if (BUS == 2) begin
      bwrite(8'(CSR_PRETRIG), 32'h11, 1);  // AW before W
      bexpect(8'(CSR_PRETRIG), 32'h11, "AXI AW-first");
      bwrite(8'(CSR_PRETRIG), 32'h22, 0);  // W before AW
      bexpect(8'(CSR_PRETRIG), 32'h22, "AXI W-first");
      bwrite(8'(CSR_PRETRIG), 32'h33, 2);  // simultaneous
      bexpect(8'(CSR_PRETRIG), 32'h33, "AXI simultaneous");
      bexpect(8'(CSR_PRETRIG), 32'h33, "AXI back-to-back read");
    end

    // --- CTRL strobes self-clear (read back 0) ---
    bwrite(8'(CSR_CTRL), 32'h1);               // arm strobe
    bexpect(8'(CSR_CTRL), 32'h0, "CTRL self-clear");
    bwrite(8'(CSR_CTRL), 32'h8);               // soft_rst -> back to IDLE, clears cfg_err
    repeat (3) @(posedge clk);

    // --- cfg_err lockout through the adapter ---
    bwrite(8'(CSR_PRETRIG), 32'h0);
    bwrite(8'(CSR_WINDOWS), 32'h1);
    bwrite(8'(CSR_CTRL), 32'h1);               // arm (state leaves IDLE)
    repeat (4) @(posedge clk);
    bwrite(8'(CSR_PRETRIG), 32'h55);           // config write while armed -> ignored + cfg_err
    bread(8'(CSR_STATUS), rd);
    if (!rd[5]) fail("cfg_err not set on armed config write");
    if (state == SCOPE_ST_IDLE) fail("core unexpectedly IDLE during lockout test");
    bwrite(8'(CSR_CTRL), 32'h8);               // soft_rst clears cfg_err + disarms
    repeat (3) @(posedge clk);
    bread(8'(CSR_STATUS), rd);
    if (rd[5]) fail("cfg_err not cleared by soft_rst");

    // --- BUF_DATA pop-on-read: capture the counter, drain DEPTH samples, expect linear seq ---
    sample_valid = 1'b1;
    bwrite(8'(CSR_PRETRIG), 32'h0);
    bwrite(8'(CSR_WINDOWS), 32'h1);
    bwrite(8'(CSR_CTRL), 32'h1);               // arm
    fork begin : wait_armed
      int g; g = 0;
      forever begin @(posedge clk); if (state == SCOPE_ST_ARMED) break; g++;
        if (g > 100) begin fail("never reached ARMED"); break; end end
    end join
    bwrite(8'(CSR_CTRL), 32'h4);               // force_trig
    begin : wait_done
      int g; g = 0;
      forever begin @(posedge clk); if (state == SCOPE_ST_DONE) break; g++;
        if (g > 4*DEPTH) begin fail("never reached DONE"); break; end end
    end
    bwrite(8'(CSR_BUF_CTRL), 32'h1);           // reset drain pointer
    begin : drain
      // PROBE_W=8 lane is zero-extended into csr_rdata; buffer[addr] is linear in addr, so
      // successive pops must be (v0+i) mod 256. A double-pop or missed pop breaks the run.
      logic [31:0] v0, vi, want;
      bread(8'(CSR_BUF_DATA), v0);
      for (int i = 1; i < DEPTH; i++) begin
        bread(8'(CSR_BUF_DATA), vi);
        want = (v0 + 32'(i)) & 32'hFF;
        if (vi !== want)
          fail($sformatf("BUF_DATA pop seq @%0d: got %h want %h (v0=%h)", i, vi, want, v0));
      end
    end
    sample_valid = 1'b0;
  endtask

  initial begin
    done = 1'b0; errs = 0;
    repeat (4) @(posedge clk); @(negedge clk); rst = 1'b0;
    run_matrix;
    errs = errors;
    if (errors == 0) $display("-- [%s] BUS=%0d matrix + BUF_DATA pop + cfg_err: PASS", NAME, BUS);
    done = 1'b1;
  end
endmodule
/* verilator lint_on DECLFILENAME */

module tb_csr_if;
  bit d_av, d_ax;
  int unsigned e_av, e_ax;
  tb_csr_if_leg #(.BUS(1), .NAME("avalon")) u_av (.done(d_av), .errs(e_av));
  tb_csr_if_leg #(.BUS(2), .NAME("axil"))   u_ax (.done(d_ax), .errs(e_ax));

  initial begin
    wait (d_av && d_ax);
    #20;
    if (e_av != 0 || e_ax != 0) begin
      $display("TB_RESULT: FAIL");
      $fatal(1, "tb_csr_if: avalon errs=%0d axil errs=%0d", e_av, e_ax);
    end
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("TB_RESULT: FAIL");
    $display("tb_csr_if: global timeout");
    $finish;
  end
endmodule
