// tb_axil_top — end-to-end check of fpga/lattice/scope_axil_top.sv (the Radiant build top).
//
// The CSR matrix through scope_axil is proven in tb_csr_if; this TB proves the WRAPPER: the
// s_axi_* port group reaches scope_top's CSR bus in XPORT="CSR" mode, the active-low reset
// polarity is right, PROBE_W/DEPTH_LOG2 pass through (HWCFG-independent check: the buffer
// really is DEPTH deep), and the armed/triggered status pins follow the capture FSM.
//   * ID magic, PRETRIG read-back, CTRL self-clear over AXI4-Lite.
//   * arm -> `armed` pin; force_trig -> `triggered` pin; STATUS reaches DONE.
//   * BUF_DATA drain: probe is a free-running counter and RLE is in bypass (RLE_CTRL=0), so
//     with the default RLE_EN=1 each stored word is 33 bits = 2 lanes: lane 0 is the sample,
//     lane 1 is the is_count flag (0). DEPTH=256 makes the low byte of buffer[addr] linear in
//     addr, so DEPTH word pops must give lane0[7:0] == (v0+i) mod 256 and lane1 == 0.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

module tb_axil_top
  import scope_pkg::*;
;
  localparam int unsigned PROBE_W = 32, DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;

  logic clk = 1'b0;
  always #5 clk <= ~clk;           // 100 MHz
  logic aresetn = 1'b0;

  logic [9:0]  awaddr = '0, araddr = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;

  logic [PROBE_W-1:0] probe = '0;
  always_ff @(posedge clk) probe <= probe + 1'b1;
  logic trig_ext_o, armed, triggered;

  scope_axil_top #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2)) dut (
      .clk(clk), .s_axi_aresetn(aresetn),
      .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .probe(probe), .trig_ext_i(1'b0), .trig_ext_o(trig_ext_o),
      .armed(armed), .triggered(triggered));

  task automatic fail(input string m);
    $display("TB_RESULT: FAIL");
    $fatal(1, "tb_axil_top: %s", m);
  endtask

  task automatic axi_wr(input int unsigned word, input logic [31:0] d);
    @(negedge clk); awaddr = {8'(word), 2'b00}; awvalid = 1'b1; wdata = d; wvalid = 1'b1;
    do @(posedge clk); while (!(awready && wready));
    #1 awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
    do @(posedge clk); while (!bvalid);
    if (bresp !== 2'b00) fail("BRESP not OKAY");
    #1 bready = 1'b0;
  endtask

  task automatic axi_rd(input int unsigned word, output logic [31:0] d);
    @(negedge clk); araddr = {8'(word), 2'b00}; arvalid = 1'b1;
    do @(posedge clk); while (!arready);
    #1 arvalid = 1'b0; rready = 1'b1;
    do @(posedge clk); while (!rvalid);
    if (rresp !== 2'b00) fail("RRESP not OKAY");
    #1 d = rdata; rready = 1'b0;
  endtask

  logic [31:0] rd, v0, lane0, lane1;

  initial begin
    repeat (4) @(posedge clk);
    if (armed !== 1'b0 || triggered !== 1'b0) fail("status pins not low in reset");
    @(negedge clk); aresetn = 1'b1;

    axi_rd(CSR_ID, rd);
    if ((rd & 32'hFFFF_F000) != SCOPE_ID_MAGIC) fail($sformatf("ID magic %h", rd));
    axi_wr(CSR_PRETRIG, 32'h0000_002A);
    axi_rd(CSR_PRETRIG, rd);
    if (rd !== 32'h2A) fail($sformatf("PRETRIG read-back %h", rd));
    axi_wr(CSR_PRETRIG, 32'h0);
    axi_wr(CSR_WINDOWS, 32'h1);

    axi_wr(CSR_CTRL, 32'h1);                    // arm
    axi_rd(CSR_CTRL, rd);
    if (rd !== 32'h0) fail("CTRL strobe did not self-clear");
    begin : wait_armed
      int g; g = 0;
      while (!armed) begin @(posedge clk); g++; if (g > 4 * DEPTH) fail("armed pin never rose"); end
    end
    if (triggered) fail("triggered pin high before trigger");
    axi_wr(CSR_CTRL, 32'h4);                    // force_trig
    begin : wait_done
      int g; g = 0;
      forever begin
        axi_rd(CSR_STATUS, rd);
        if (rd[2:0] == 3'(SCOPE_ST_DONE)) break;
        g++; if (g > 4 * DEPTH) fail("STATUS never reached DONE");
      end
    end
    if (!triggered || !rd[3]) fail("triggered pin / STATUS.triggered not set at DONE");
    if (armed) fail("armed pin still high at DONE");

    axi_wr(CSR_BUF_CTRL, 32'h1);                // reset drain pointer
    for (int i = 0; i < DEPTH; i++) begin
      axi_rd(CSR_BUF_DATA, lane0);
      axi_rd(CSR_BUF_DATA, lane1);
      if (i == 0) v0 = lane0;
      if (lane0[7:0] !== 8'(v0 + 32'(i)))
        fail($sformatf("BUF_DATA word %0d lane0 %h, want low byte %h", i, lane0, 8'(v0 + 32'(i))));
      if (lane1 !== 32'h0) fail($sformatf("BUF_DATA word %0d lane1 %h, want 0", i, lane1));
    end
    // DEPTH passed through: pop DEPTH+1 wraps the drain pointer back to word 0
    axi_rd(CSR_BUF_DATA, lane0);
    if (lane0 !== v0) fail($sformatf("drain pointer did not wrap at DEPTH: %h vs %h", lane0, v0));

    $display("-- scope_axil_top: ID, CSR r/w, arm/trigger pins, %0d-word BUF_DATA drain: PASS", DEPTH);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("TB_RESULT: FAIL");
    $fatal(1, "tb_axil_top: global timeout");
  end

  wire _unused = &{1'b0, trig_ext_o};

endmodule
