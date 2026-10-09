// tb_axil_top — end-to-end check of fpga/xilinx/scope_axil_top.sv through its s_axi_* port.
//
// tb_csr_if proves the scope_axil adapter against scope_csr + scope_core. This TB proves the
// Vivado wrapper itself: the s_axi_* renaming, the aresetn -> rst conversion, the XPORT="CSR"
// hookup into the full scope_top (trigger + RLE stage + core + CSR), and parameter
// pass-through. Two legs: the as-built default (RLE_EN=1, 33-bit stored word, 2 drain lanes)
// and RLE_EN=0 (32-bit stored word, 1 lane) at a different depth. Per leg, all over AXI4-Lite:
//   * ID magic; HWCFG reports the wrapper's PROBE_W / DEPTH_LOG2 / RLE_EN (pass-through).
//   * status pins: `armed` rises on arm, `triggered` rises on force_trig, both match STATUS.
//   * capture a free-running probe counter, drain DEPTH words via BUF_CTRL/BUF_DATA:
//     consecutive samples must differ by exactly 1 (mod 2^32) except at the single circular
//     wrap point, where the step is -(DEPTH-1); RLE lane 1 (is_count) must read 0 in bypass.
//   * the comparator trigger path: re-arm with CMP0 = (probe == a future counter value) and
//     check the captured sample at TRIG_INDEX is exactly that value.
// Self-checking: "TB_RESULT: FAIL" + $fatal on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_axil_top_leg
  import scope_pkg::*;
#(
    parameter int unsigned PROBE_W    = 32,
    parameter int unsigned DEPTH_LOG2 = 8,
    parameter bit          RLE_EN     = 1'b1,
    parameter string       NAME       = "leg"
) (
    output bit done
);
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned BUF_LANES = RLE_EN ? 2 : 1;   // PROBE_W=32: 33-bit word -> 2 lanes

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic aresetn = 1'b0;

  logic [PROBE_W-1:0] probe = '0;
  always_ff @(posedge clk) probe <= probe + 1'b1;

  logic        trig_ext_o, armed, triggered;
  logic [9:0]  awaddr = '0, araddr = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;

  scope_axil_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .RLE_EN    (RLE_EN)
  ) dut (
      .clk          (clk),
      .aresetn      (aresetn),
      .probe        (probe),
      .trig_ext_i   (1'b0),
      .trig_ext_o   (trig_ext_o),
      .armed        (armed),
      .triggered    (triggered),
      .s_axi_awaddr (awaddr),
      .s_axi_awprot (3'b000),
      .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_wdata  (wdata),
      .s_axi_wstrb  (4'hF),
      .s_axi_wvalid (wvalid),
      .s_axi_wready (wready),
      .s_axi_bresp  (bresp),
      .s_axi_bvalid (bvalid),
      .s_axi_bready (bready),
      .s_axi_araddr (araddr),
      .s_axi_arprot (3'b000),
      .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_rdata  (rdata),
      .s_axi_rresp  (rresp),
      .s_axi_rvalid (rvalid),
      .s_axi_rready (rready)
  );

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // AXI4-Lite master (same handshake discipline as tb_csr_if; `word` is the CSR word index)
  task automatic axi_wr(input logic [7:0] word, input logic [31:0] d);
    @(negedge clk);
    awaddr = {word, 2'b00}; awvalid = 1'b1; wdata = d; wvalid = 1'b1;
    do begin @(posedge clk); end while (!(awready && wready));
    #1 awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
    do begin @(posedge clk); end while (!bvalid);
    if (bresp !== 2'b00) fail("BRESP not OKAY");
    #1 bready = 1'b0;
  endtask

  task automatic axi_rd(input logic [7:0] word, output logic [31:0] d);
    @(negedge clk);
    araddr = {word, 2'b00}; arvalid = 1'b1;
    do begin @(posedge clk); end while (!arready);
    #1 arvalid = 1'b0; rready = 1'b1;
    do begin @(posedge clk); end while (!rvalid);
    if (rresp !== 2'b00) fail("RRESP not OKAY");
    #1 d = rdata; rready = 1'b0;
  endtask

  logic [31:0] v, prev, cur, tidx, cmpv;
  int unsigned wraps;

  // poll STATUS (into v) until the core reaches `want` (bounded)
  task automatic wait_state(input logic [2:0] want, input string what);
    int unsigned guard;
    guard = 0;
    v = '1;
    while (v[2:0] != want) begin
      axi_rd(8'(CSR_STATUS), v);
      guard++;
      if (guard > 4 * DEPTH + 2048) fail({"timeout waiting for ", what});
    end
  endtask

  // drain one stored word: lane 0 = sample value; RLE lane 1 = is_count (0 in bypass)
  task automatic pop_word(output logic [31:0] val);
    logic [31:0] hi;
    axi_rd(8'(CSR_BUF_DATA), val);
    if (BUF_LANES == 2) begin
      axi_rd(8'(CSR_BUF_DATA), hi);
      if (hi !== 32'h0) fail($sformatf("RLE bypass word has is_count/pad bits set: %h", hi));
    end
  endtask

  initial begin
    done = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk) aresetn = 1'b1;
    repeat (3) @(posedge clk);

    // ---- identity + parameter pass-through ------------------------------------------------
    axi_rd(8'(CSR_ID), v);
    if (v !== SCOPE_ID_REG) fail($sformatf("ID %h", v));
    axi_rd(8'(CSR_HWCFG), v);
    if (v !== {13'h0, RLE_EN, 4'd4, 4'(DEPTH_LOG2), 10'(PROBE_W)})
      fail($sformatf("HWCFG %h does not match wrapper parameters", v));
    if (armed !== 1'b0 || triggered !== 1'b0) fail("status pins not idle after reset");

    // ---- capture 1: force_trig, RLE bypass, pretrig = DEPTH/4 ------------------------------
    axi_wr(8'(CSR_RLE_CTRL), 32'h0);
    axi_wr(8'(CSR_PRETRIG), 32'(DEPTH / 4));
    axi_wr(8'(CSR_WINDOWS), 32'h1);
    axi_wr(8'(CSR_CTRL), 32'h1);  // arm
    wait_state(3'(SCOPE_ST_ARMED), "ARMED");
    if (armed !== 1'b1) fail("armed pin low while ARMED");
    if (triggered !== 1'b0) fail("triggered pin high before trigger");
    axi_wr(8'(CSR_CTRL), 32'h4);  // force_trig
    wait_state(3'(SCOPE_ST_DONE), "DONE");
    if (armed !== 1'b0) fail("armed pin high in DONE");
    if (triggered !== 1'b1) fail("triggered pin low after force_trig");
    axi_rd(8'(CSR_STATUS), v);
    if (v[3] !== 1'b1) fail("STATUS.triggered");
    if (v[5] !== 1'b0) fail("unexpected cfg_err");

    axi_wr(8'(CSR_BUF_CTRL), 32'h1);  // reset the drain pointer
    wraps = 0;
    pop_word(prev);
    for (int unsigned i = 1; i < DEPTH; i++) begin
      pop_word(cur);
      if (cur == prev + 32'd1) begin
        // contiguous
      end else if (cur == prev - 32'(DEPTH - 1)) begin
        wraps++;  // the circular buffer's oldest/newest seam
      end else begin
        fail($sformatf("drain word %0d: got %h after %h", i, cur, prev));
      end
      prev = cur;
    end
    if (wraps > 1) fail($sformatf("%0d wrap seams in one capture", wraps));

    // ---- capture 2: comparator trigger (probe == cmpv) through the real trigger engine ---------
    axi_wr(8'(CSR_CTRL), 32'h8);  // soft_rst -> IDLE
    wait_state(3'(SCOPE_ST_IDLE), "IDLE after soft_rst");
    axi_wr(8'(CSR_PRETRIG), 32'h0);
    axi_wr(8'(CSR_CMP_SEL), 32'({2'(CMP_FIELD_MASK), 2'd0}));
    axi_wr(8'(CSR_CMP_LANE_BASE), 32'hFFFF_FFFF);
    axi_wr(8'(CSR_CMP_SEL), 32'({2'(CMP_FIELD_VALUE), 2'd0}));
    cmpv = probe + 32'd2000;  // a counter value the probe reaches ~2000 cycles from now
    axi_wr(8'(CSR_CMP_LANE_BASE), cmpv);
    axi_wr(8'(CSR_TRIG_COMBINE), 32'h0000_0001);  // OR-combine, comparator 0 enabled
    axi_wr(8'(CSR_CTRL), 32'h1);  // arm
    wait_state(3'(SCOPE_ST_DONE), "DONE (comparator trigger)");
    axi_rd(8'(CSR_TRIG_INDEX), tidx);
    axi_wr(8'(CSR_BUF_CTRL), 32'h1);
    for (int unsigned i = 0; i <= tidx; i++) pop_word(cur);
    if (cur !== cmpv)
      fail($sformatf("trigger sample @%0d = %h, want comparator value %h", tidx, cur, cmpv));

    $display("-- [%s] PROBE_W=%0d DEPTH_LOG2=%0d RLE_EN=%0d: ID/HWCFG, status pins, %0d-word drain, cmp trigger clean",
             NAME, PROBE_W, DEPTH_LOG2, RLE_EN, DEPTH);
    done = 1'b1;
  end

  wire unused = &{1'b0, trig_ext_o};

endmodule
/* verilator lint_on DECLFILENAME */

module tb_axil_top;

  bit done_a, done_b;

  tb_axil_top_leg #(.PROBE_W(32), .DEPTH_LOG2(8),  .RLE_EN(1'b1), .NAME("rle1_d8"))  leg_a (.done(done_a));
  tb_axil_top_leg #(.PROBE_W(32), .DEPTH_LOG2(10), .RLE_EN(1'b0), .NAME("rle0_d10")) leg_b (.done(done_b));

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
