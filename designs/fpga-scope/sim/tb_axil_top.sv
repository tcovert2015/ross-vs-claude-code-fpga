// tb_axil_top — end-to-end check of the Vivado wrapper fpga/xilinx/scope_axil_top.sv.
//
// tb_csr_if proves the scope_axil adapter against scope_csr + scope_core; this TB proves the
// WRAPPER wiring (s_axi_* naming, aresetn inversion, XPORT="CSR" hookup, status pins) by
// driving a whole capture through the AXI4-Lite port of the real synthesis top:
//   * ID magic + HWCFG readable; PRETRIG read-back.
//   * arm -> `armed` pin; CTRL.force_trig -> `triggered` pin; STATUS.state reaches DONE.
//   * drain DEPTH words over BUF_CTRL/BUF_DATA (RLE_EN=1 => STORE_W=33 => 2 lanes per word,
//     RLE_CTRL=0 => bypass, is_count lane must read 0). The probe is a free-running counter,
//     so the circular buffer read in address order is consecutive with exactly one wrap
//     discontinuity of -(DEPTH-1).
//   * second capture triggered from the trig_ext_i pin instead of force_trig.
// Self-checking: "TB_RESULT: PASS" / "TB_RESULT: FAIL" + $fatal, same contract as every TB.
`timescale 1ns / 1ps
module tb_axil_top
  import scope_pkg::*;
;
  localparam int unsigned PROBE_W = 32, DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic aresetn = 1'b0;

  logic [9:0]  awaddr = '0, araddr = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;

  logic [PROBE_W-1:0] probe = 32'h1000;
  always_ff @(posedge clk) probe <= probe + 1'b1;
  logic trig_ext_i = 1'b0;
  logic trig_ext_o, armed, triggered;

  scope_axil_top #(
      .PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .RLE_EN(1'b1), .ID_VALUE(32'hA7A7_0001)
  ) dut (
      .clk(clk), .aresetn(aresetn),
      .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .probe(probe), .trig_ext_i(trig_ext_i), .trig_ext_o(trig_ext_o),
      .armed(armed), .triggered(triggered));

  wire _unused = &{1'b0, trig_ext_o};

  task automatic fail(input string m);
    $display("TB_RESULT: FAIL");
    $fatal(1, "tb_axil_top: %s", m);
  endtask

  task automatic axw(input int unsigned word, input logic [31:0] d);
    @(negedge clk);
    awaddr = 10'(word << 2); awvalid = 1'b1; wdata = d; wvalid = 1'b1;
    do @(posedge clk); while (!(awready && wready));
    #1 awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
    do @(posedge clk); while (!bvalid);
    if (bresp !== 2'b00) fail("BRESP != OKAY");
    #1 bready = 1'b0;
  endtask

  task automatic axr(input int unsigned word, output logic [31:0] d);
    @(negedge clk);
    araddr = 10'(word << 2); arvalid = 1'b1;
    do @(posedge clk); while (!arready);
    #1 arvalid = 1'b0; rready = 1'b1;
    do @(posedge clk); while (!rvalid);
    if (rresp !== 2'b00) fail("RRESP != OKAY");
    #1 d = rdata; rready = 1'b0;
  endtask

  task automatic wait_state(input logic [2:0] want, input string what);
    logic [31:0] s;
    int g;
    g = 0;
    do begin
      axr(CSR_STATUS, s);
      g++;
      if (g > 4 * DEPTH) fail({"timeout waiting for state ", what});
    end while (s[2:0] !== want);
  endtask

  // one capture: arm, wait ARMED, trigger (force or ext pin), wait DONE, drain + check
  task automatic capture(input bit use_ext);
    logic [31:0] lo, hi, prev;
    int unsigned breaks;
    axw(CSR_CTRL, 32'h8);                    // soft_rst -> IDLE
    axw(CSR_PRETRIG, 32'd64);
    axw(CSR_WINDOWS, 32'd1);
    axr(CSR_PRETRIG, lo);
    if (lo !== 32'd64) fail($sformatf("PRETRIG read-back %h", lo));
    axw(CSR_CTRL, 32'h1);                    // arm
    wait_state(3'(SCOPE_ST_ARMED), "ARMED");
    if (!armed) fail("armed pin low in ARMED");
    if (triggered) fail("triggered pin high before trigger");
    if (use_ext) begin
      @(negedge clk); trig_ext_i = 1'b1;
      @(negedge clk); trig_ext_i = 1'b0;
    end else begin
      axw(CSR_CTRL, 32'h4);                  // force_trig
    end
    wait_state(3'(SCOPE_ST_DONE), "DONE");
    if (!triggered) fail("triggered pin low after capture");
    axw(CSR_BUF_CTRL, 32'h1);                // reset drain pointer
    breaks = 0;
    prev = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      axr(CSR_BUF_DATA, lo);                 // lane 0: value[31:0]
      axr(CSR_BUF_DATA, hi);                 // lane 1: {31'b0, is_count}
      if (hi !== 32'h0) fail($sformatf("word %0d: is_count lane = %h (RLE bypass)", i, hi));
      if (i != 0 && lo !== prev + 32'd1) begin
        breaks++;
        if (prev - lo !== 32'(DEPTH - 1))
          fail($sformatf("word %0d: %h after %h is not the ring wrap", i, lo, prev));
      end
      prev = lo;
    end
    if (breaks > 1) fail($sformatf("%0d discontinuities in the drained ring", breaks));
    $display("-- capture (%s trigger): %0d words drained, %0d wrap point", use_ext ? "ext" : "force",
             DEPTH, breaks);
  endtask

  logic [31:0] v;
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk); aresetn = 1'b1;
    repeat (2) @(posedge clk);
    axr(CSR_ID, v);
    if ((v & 32'hFFFF_F000) !== SCOPE_ID_MAGIC) fail($sformatf("ID magic %h", v));
    axr(CSR_HWCFG, v);
    $display("-- HWCFG = %h", v);
    capture(1'b0);
    capture(1'b1);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #20ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "tb_axil_top: global timeout");
  end
endmodule
