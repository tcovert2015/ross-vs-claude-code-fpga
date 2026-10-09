// tb_axil_top — smoke test of the Radiant top fpga/lattice/scope_axil_top.sv through its
// s_axi_* AXI4-Lite port (Questa flow, sim/run_questa.ps1).
//
// Proves the wrapper wiring only (scope_axil + scope_top XPORT="CSR" are covered by tb_csr_if
// and the core TBs): ID magic reads back, a R/W register round-trips, arm + force_trig raises
// `armed` then `triggered`, and DEPTH BUF_DATA pops return the free-running probe counter as
// one contiguous run (at most the single circular-buffer wrap discontinuity).
// Contract: failure -> "TB_RESULT: FAIL" + $fatal; success -> "TB_RESULT: PASS" + $finish.
`timescale 1ns/1ps
module tb_axil_top
  import scope_pkg::*;
;
  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic [PROBE_W-1:0] probe = '0;
  always_ff @(posedge clk) probe <= probe + 32'd1;

  logic        armed, triggered, trig_ext_o;
  logic [9:0]  awaddr = '0, araddr = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;

  scope_axil_top #(
      .PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .RLE_EN(1'b0), .ID_VALUE(32'h1A77_1CE5)
  ) dut (
      .clk(clk), .rst(rst), .probe(probe), .trig_ext_i(1'b0), .trig_ext_o(trig_ext_o),
      .armed(armed), .triggered(triggered),
      .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid),
      .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid),
      .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
      .s_axi_rready(rready)
  );

  task automatic fail(input string m);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", m);
  endtask

  task automatic axi_write(input int unsigned word, input logic [31:0] d);
    @(negedge clk); awaddr = {8'(word), 2'b00}; awvalid = 1'b1; wdata = d; wvalid = 1'b1;
    do @(posedge clk); while (!(awready && wready));
    #1 awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
    do @(posedge clk); while (!bvalid);
    if (bresp !== 2'b00) fail("BRESP != OKAY");
    #1 bready = 1'b0;
  endtask

  task automatic axi_read(input int unsigned word, output logic [31:0] d);
    @(negedge clk); araddr = {8'(word), 2'b00}; arvalid = 1'b1;
    do @(posedge clk); while (!arready);
    #1 arvalid = 1'b0; rready = 1'b1;
    do @(posedge clk); while (!rvalid);
    if (rresp !== 2'b00) fail("RRESP != OKAY");
    #1 d = rdata; rready = 1'b0;
  endtask

  logic [31:0] v, prev;
  int unsigned breaks;

  initial begin
    repeat (4) @(posedge clk); @(negedge clk); rst = 1'b0;

    axi_read(CSR_ID, v);
    if (v !== SCOPE_ID_REG) fail($sformatf("ID: got %h want %h", v, SCOPE_ID_REG));
    axi_write(CSR_TRIG_COMBINE, 32'hA5A5_1234);
    axi_read(CSR_TRIG_COMBINE, v);
    if (v !== 32'hA5A5_1234) fail($sformatf("TRIG_COMBINE readback %h", v));
    if (armed || triggered) fail("armed/triggered high while idle");

    axi_write(CSR_PRETRIG, 32'h0);
    axi_write(CSR_WINDOWS, 32'h1);
    axi_write(CSR_CTRL, 32'h1);                 // arm
    begin
      automatic int g = 0;
      while (!armed) begin @(posedge clk); g++; if (g > 4 * DEPTH) fail("never armed"); end
    end
    axi_write(CSR_CTRL, 32'h4);                 // force_trig
    begin
      automatic int g = 0;
      while (!triggered) begin @(posedge clk); g++; if (g > 64) fail("never triggered"); end
    end
    repeat (DEPTH + 32) @(posedge clk);         // post-trigger fill -> DONE

    axi_write(CSR_BUF_CTRL, 32'h1);             // reset drain pointer
    axi_read(CSR_BUF_DATA, prev);
    breaks = 0;
    for (int i = 1; i < DEPTH; i++) begin
      axi_read(CSR_BUF_DATA, v);
      if (v !== prev + 32'd1) begin
        // the one allowed discontinuity: circular-buffer wrap (newest -> oldest sample)
        if (v !== prev - 32'(DEPTH - 1)) fail($sformatf("BUF_DATA @%0d: %h after %h", i, v, prev));
        breaks++;
      end
      prev = v;
    end
    if (breaks > 1) fail($sformatf("%0d discontinuities in capture", breaks));

    $display("-- scope_axil_top: ID, CSR R/W, arm/force_trig status, %0d-sample drain: PASS", DEPTH);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #5ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout");
  end

  wire _unused = &{1'b0, trig_ext_o};

endmodule
