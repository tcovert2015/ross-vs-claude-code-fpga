// tb_axil_top — end-to-end check of fpga/xilinx/scope_axil_top.sv (the Vivado AXI4-Lite top).
//
// tb_csr / tb_csr_if prove the CSR file and the thin scope_axil adapter against scope_csr +
// scope_core. This TB closes the remaining gap for the Vivado port: the assembled wrapper
// (s_axi_* renames, active-low reset inversion, XPORT="CSR" tie-offs, parameter pass-through)
// with the real scope_trigger/scope_top datapath in between. Driven purely over AXI4-Lite:
//   * ID magic and HWCFG field packing vs the wrapper's PROBE_W / DEPTH_LOG2 / RLE_EN.
//   * arm -> `armed` pin; force_trig -> `triggered` pin; STATUS reaches DONE.
//   * BUF_DATA drain of all DEPTH samples: probe is a free-running 32-bit counter, so the
//     circular buffer must be +1 linear in address with exactly one seam (newest -> oldest,
//     delta = -(DEPTH-1)), and the seam must sit at (TRIG_INDEX - PRETRIG) mod DEPTH — the
//     host-side reconstruction rule (docs/DESIGN.md).
// Self-checking: "TB_RESULT: PASS" then $finish, or "TB_RESULT: FAIL" + $fatal.
`timescale 1ns / 1ps
module tb_axil_top
  import scope_pkg::*;
;
  localparam int unsigned PROBE_W = 32, DEPTH_LOG2 = 8, DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned PRETRIG = 40;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic aresetn = 1'b0;

  logic [9:0]  awaddr = '0, araddr = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;

  logic [PROBE_W-1:0] probe = '0;
  always_ff @(posedge clk) probe <= probe + 1'b1;
  logic trig_ext_o, armed, triggered;

  scope_axil_top #(
      .PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .RLE_EN(1'b0), .ID_VALUE(32'h0)
  ) dut (
      .clk(clk), .s_axi_aresetn(aresetn),
      .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
      .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
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

  logic [31:0] rd, trig_index;
  logic [31:0] v[DEPTH];
  int unsigned seams, seam_at;

  initial begin
    repeat (4) @(posedge clk);
    if (bvalid !== 1'b0 || rvalid !== 1'b0) fail("xVALID high in reset");
    @(negedge clk); aresetn = 1'b1;

    axi_rd(CSR_ID, rd);
    if (rd !== SCOPE_ID_REG) fail($sformatf("ID %h", rd));
    axi_rd(CSR_HWCFG, rd);
    if (rd !== {13'h0, 1'b0, 4'd4, 4'(DEPTH_LOG2), 10'(PROBE_W)}) fail($sformatf("HWCFG %h", rd));

    axi_wr(CSR_PRETRIG, PRETRIG);
    axi_wr(CSR_WINDOWS, 32'h1);
    if (armed !== 1'b0 || triggered !== 1'b0) fail("status pins not idle before arm");
    axi_wr(CSR_CTRL, 32'h1);                       // arm
    repeat (2) @(posedge clk);
    if (armed !== 1'b1) fail("armed pin did not rise");
    repeat (DEPTH + 37) @(posedge clk);            // let the circular buffer wrap
    axi_wr(CSR_CTRL, 32'h4);                       // force_trig
    repeat (4) @(posedge clk);
    if (triggered !== 1'b1) fail("triggered pin did not rise");
    begin
      int g; g = 0;
      do begin axi_rd(CSR_STATUS, rd); g++; end while (rd[2:0] != SCOPE_ST_DONE && g < 200);
      if (rd[2:0] != SCOPE_ST_DONE) fail($sformatf("never reached DONE (STATUS %h)", rd));
      if (!rd[3] || !rd[4]) fail($sformatf("STATUS triggered/wrapped not set: %h", rd));
    end
    if (armed !== 1'b0) fail("armed pin still high in DONE");
    axi_rd(CSR_TRIG_INDEX, trig_index);

    axi_wr(CSR_BUF_CTRL, 32'h1);                   // reset drain pointer
    for (int i = 0; i < DEPTH; i++) axi_rd(CSR_BUF_DATA, v[i]);
    seams = 0; seam_at = 0;
    for (int i = 0; i < DEPTH; i++) begin
      automatic int unsigned j = (i + 1) % DEPTH;
      if (v[j] == v[i] + 32'd1) continue;
      if (v[j] == v[i] - 32'(DEPTH - 1)) begin seams++; seam_at = j; end
      else fail($sformatf("buffer not linear @%0d: %h -> %h", i, v[i], v[j]));
    end
    if (seams != 1) fail($sformatf("expected exactly 1 seam, got %0d", seams));
    if (seam_at != ((trig_index - PRETRIG) % DEPTH))
      fail($sformatf("oldest sample @%0d, expected (TRIG_INDEX %0d - PRETRIG) mod DEPTH",
                     seam_at, trig_index));
    $display("-- scope_axil_top: ID/HWCFG, arm/trigger pins, %0d-sample drain, seam @%0d: ok",
             DEPTH, seam_at);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #2ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "tb_axil_top: timeout");
  end

  wire unused = &{1'b0, trig_ext_o};
endmodule
