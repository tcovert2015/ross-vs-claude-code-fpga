// tb_ext_trig — cross-instance triggering + dual-instantiation proof (issue #13, §7).
//
// Two scope_top instances (distinct ID_VALUE, XPORT="CSR") in one design:
//   * A triggers on a COMPARATOR (its counter probe reaching TARGET_A).
//   * A's trig_ext_o is wired to B's trig_ext_i; B has NO comparator trigger — it fires only
//     from the cross-instance signal.
//   * Each captures its OWN counter probe (B's offset by OFFSET), proving no singleton state:
//     two fully-independent instances, and B's trigger is contemporaneous with A's (both store
//     the probe value present LATENCY cycles before A's sequencer fired).
// trig_ext_o excludes trig_ext_i (scope_trigger), so the A->B wire cannot form a comb loop.
// Self-checking: $fatal (prints TB_RESULT: FAIL) on mismatch; TB_RESULT: PASS on success.
`timescale 1ns / 1ps

module tb_ext_trig
  import scope_pkg::*;
;

  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam logic [31:0] IDV_A = 32'hA11CE000;
  localparam logic [31:0] IDV_B = 32'hB0B00000;
  localparam logic [31:0] TARGET_A = 32'h0000_0400;   // A fires when its counter hits this
  localparam logic [31:0] OFFSET   = 32'h0001_0000;   // B's counter = A's + OFFSET (distinct)

  logic clk = 1'b0;  always #5 clk <= ~clk;
  logic rst = 1'b1;

  // two free-running counter probes (lockstep; B offset so its samples are unmistakably B's)
  logic [31:0] cntA = 32'd0;
  always_ff @(posedge clk) cntA <= rst ? 32'd0 : cntA + 1'b1;
  wire [31:0] cntB = cntA + OFFSET;

  // one CSR driver, muxed to instance A (sel=0) or B (sel=1) — flat signals (no array ports)
  logic       sel;
  logic [7:0]  csr_addr;
  logic [31:0] csr_wdata;
  logic        csr_write, csr_read;
  logic [31:0] a_rdata, b_rdata;
  wire  [31:0] csr_rdata = sel ? b_rdata : a_rdata;
  logic        armedA, armedB, trigdA, trigdB;
  wire         a_trig_ext_o;

  // the STREAM/UART outputs are unused in CSR mode (this TB drives ext_csr_* only)
  /* verilator lint_off PINCONNECTEMPTY */
  scope_top #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .RLE_EN(1'b0),
              .XPORT("CSR"), .ID_VALUE(IDV_A)) uA (
      .clk(clk), .rst(rst), .probe(cntA),
      .trig_ext_i(1'b0),          .trig_ext_o(a_trig_ext_o),
      .xclk(clk), .xrst(rst),
      .rx_data(8'h0), .rx_valid(1'b0), .rx_ready(), .tx_data(), .tx_valid(), .tx_ready(1'b0),
      .uart_rx(1'b1), .uart_tx(), .armed(armedA), .triggered(trigdA),
      .ext_csr_addr(csr_addr), .ext_csr_wdata(csr_wdata), .ext_csr_write(csr_write & ~sel),
      .ext_csr_read(csr_read & ~sel), .ext_csr_rdata(a_rdata));

  scope_top #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .RLE_EN(1'b0),
              .XPORT("CSR"), .ID_VALUE(IDV_B)) uB (
      .clk(clk), .rst(rst), .probe(cntB),
      .trig_ext_i(a_trig_ext_o),  .trig_ext_o(),        // A drives B's external trigger
      .xclk(clk), .xrst(rst),
      .rx_data(8'h0), .rx_valid(1'b0), .rx_ready(), .tx_data(), .tx_valid(), .tx_ready(1'b0),
      .uart_rx(1'b1), .uart_tx(), .armed(armedB), .triggered(trigdB),
      .ext_csr_addr(csr_addr), .ext_csr_wdata(csr_wdata), .ext_csr_write(csr_write & sel),
      .ext_csr_read(csr_read & sel), .ext_csr_rdata(b_rdata));
  /* verilator lint_on PINCONNECTEMPTY */

  logic [31:0] v, tiA, tiB;
  wire unused = &{1'b0, armedA, armedB, trigdA, trigdB, tiA[31:DEPTH_LOG2], tiB[31:DEPTH_LOG2]};

  initial begin sel = 1'b0; csr_addr = 8'h0; csr_wdata = 32'h0; csr_write = 1'b0; csr_read = 1'b0; end

  task automatic fail(input string m); $display("TB_RESULT: FAIL"); $fatal(1, "%s", m); endtask

  task automatic csr_wr(input bit i, input logic [7:0] a, input logic [31:0] d);
    @(negedge clk); sel = i; csr_addr = a; csr_wdata = d; csr_write = 1'b1;
    @(negedge clk); csr_write = 1'b0;
  endtask
  task automatic csr_rd(input bit i, input logic [7:0] a, output logic [31:0] d);
    @(negedge clk); sel = i; csr_addr = a; csr_read = 1'b1;
    #2; d = csr_rdata;
    @(negedge clk); csr_read = 1'b0;
  endtask

  // configure comparator 0 of instance i as a full-width level match on `val`
  task automatic set_cmp0_level(input bit i, input logic [31:0] val);
    csr_wr(i, 8'(CSR_CMP_SEL), 32'(CMP_FIELD_MASK) << 2);  csr_wr(i, 8'(CSR_CMP_LANE_BASE), 32'hFFFF_FFFF);
    csr_wr(i, 8'(CSR_CMP_SEL), 32'(CMP_FIELD_VALUE) << 2); csr_wr(i, 8'(CSR_CMP_LANE_BASE), val);
  endtask

  logic [31:0] bufA[DEPTH], bufB[DEPTH];
  task automatic drain_buf(input bit i, output logic [31:0] b[DEPTH]);
    logic [31:0] d;
    csr_wr(i, 8'(CSR_BUF_CTRL), 32'h1);            // reset drain pointer
    for (int unsigned k = 0; k < DEPTH; k++) begin csr_rd(i, 8'(CSR_BUF_DATA), d); b[k] = d; end
  endtask

  initial begin
    repeat (8) @(negedge clk); rst = 1'b0; repeat (2) @(negedge clk);

    // identity: both CSR buses live + return the shared magic (independent front-ends)
    csr_rd(0, 8'(CSR_ID), v); if (v != SCOPE_ID_REG) fail("A CSR_ID");
    csr_rd(1, 8'(CSR_ID), v); if (v != SCOPE_ID_REG) fail("B CSR_ID");

    // A: comparator trigger on cntA==TARGET_A, no pretrig, 1 window
    csr_wr(0, 8'(CSR_PRETRIG), 32'd0); csr_wr(0, 8'(CSR_WINDOWS), 32'd1);
    set_cmp0_level(0, TARGET_A);
    csr_wr(0, 8'(CSR_TRIG_COMBINE), 32'h0000_0001);   // stage0 selects cmp0 (OR)
    csr_wr(0, 8'(CSR_SEQ_CNT_BASE), 32'd1);
    // B: no comparator trigger — external only
    csr_wr(1, 8'(CSR_PRETRIG), 32'd0); csr_wr(1, 8'(CSR_WINDOWS), 32'd1);
    csr_wr(1, 8'(CSR_TRIG_COMBINE), 32'h0);

    // arm B first (so it is watching when A fires), then A
    csr_wr(1, 8'(CSR_CTRL), 32'h1);
    csr_wr(0, 8'(CSR_CTRL), 32'h1);

    // wait for both to finish
    do csr_rd(0, 8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_DONE));
    if (!v[3]) fail("A not triggered");
    do csr_rd(1, 8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_DONE));
    if (!v[3]) fail("B not triggered (cross-instance trig_ext failed)");

    csr_rd(0, 8'(CSR_TRIG_INDEX), tiA);
    csr_rd(1, 8'(CSR_TRIG_INDEX), tiB);

    // drain both buffers; the trigger sample sits at buf[trig_index]
    drain_buf(0, bufA);
    drain_buf(1, bufB);

    if (bufA[tiA[DEPTH_LOG2-1:0]] != TARGET_A)
      fail($sformatf("A trigger sample %h != TARGET_A %h", bufA[tiA[DEPTH_LOG2-1:0]], TARGET_A));
    // B triggered contemporaneously with A: its stored trigger sample is A's + OFFSET.
    if (bufB[tiB[DEPTH_LOG2-1:0]] != TARGET_A + OFFSET)
      fail($sformatf("B trigger sample %h != %h (cross-instance not aligned)",
                     bufB[tiB[DEPTH_LOG2-1:0]], TARGET_A + OFFSET));
    if ((bufB[tiB[DEPTH_LOG2-1:0]] & 32'hFFFF_0000) == 32'h0)
      fail("B captured A's probe — instances not independent");

    $display("-- A cmp-fired @%h, B ext-triggered contemporaneously @%h (latency 0 capture cycles)",
             TARGET_A, TARGET_A + OFFSET);
    $display("-- two scope_top instances captured independently; no singleton state");
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin #5ms; fail("timeout"); end

endmodule
