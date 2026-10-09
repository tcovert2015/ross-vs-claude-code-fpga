// scope_axil_bd — plain-Verilog shim around scope_axil_top for Vivado IP Integrator.
//
// IP Integrator refuses a SystemVerilog file as the TOP of an RTL module reference
// ("[filemgmt 56-195] ... type SystemVerilog ... not allowed as the top file in the
// reference"), although SystemVerilog below the top is fine. This file is that Verilog-2001
// top: ports and parameters only, zero logic. Use it for block designs
//     create_bd_cell -type module -reference scope_axil_bd scope_0
// and use scope_axil_top.sv directly everywhere else (RTL instantiation, build.tcl).
// fpga/xilinx/check_ipi.tcl proves the s_axi AXI4-Lite interface is inferred from it.
module scope_axil_bd #(
    parameter integer PROBE_W    = 32,   // 1..512
    parameter integer DEPTH_LOG2 = 12,   // 8..15
    parameter integer RLE_EN     = 1,    // 0 | 1
    parameter [31:0]  ID_VALUE   = 32'h0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *)
    input  wire               clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire               aresetn,

    input  wire [PROBE_W-1:0] probe,
    input  wire               trig_ext_i,
    output wire               trig_ext_o,
    output wire               armed,
    output wire               triggered,

    input  wire [9:0]         s_axi_awaddr,
    input  wire [2:0]         s_axi_awprot,
    input  wire               s_axi_awvalid,
    output wire               s_axi_awready,
    input  wire [31:0]        s_axi_wdata,
    input  wire [3:0]         s_axi_wstrb,
    input  wire               s_axi_wvalid,
    output wire               s_axi_wready,
    output wire [1:0]         s_axi_bresp,
    output wire               s_axi_bvalid,
    input  wire               s_axi_bready,
    input  wire [9:0]         s_axi_araddr,
    input  wire [2:0]         s_axi_arprot,
    input  wire               s_axi_arvalid,
    output wire               s_axi_arready,
    output wire [31:0]        s_axi_rdata,
    output wire [1:0]         s_axi_rresp,
    output wire               s_axi_rvalid,
    input  wire               s_axi_rready
);

  scope_axil_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .RLE_EN    (RLE_EN != 0),
      .ID_VALUE  (ID_VALUE)
  ) u_top (
      .clk          (clk),
      .aresetn      (aresetn),
      .probe        (probe),
      .trig_ext_i   (trig_ext_i),
      .trig_ext_o   (trig_ext_o),
      .armed        (armed),
      .triggered    (triggered),
      .s_axi_awaddr (s_axi_awaddr),
      .s_axi_awprot (s_axi_awprot),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_wdata  (s_axi_wdata),
      .s_axi_wstrb  (s_axi_wstrb),
      .s_axi_wvalid (s_axi_wvalid),
      .s_axi_wready (s_axi_wready),
      .s_axi_bresp  (s_axi_bresp),
      .s_axi_bvalid (s_axi_bvalid),
      .s_axi_bready (s_axi_bready),
      .s_axi_araddr (s_axi_araddr),
      .s_axi_arprot (s_axi_arprot),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_rdata  (s_axi_rdata),
      .s_axi_rresp  (s_axi_rresp),
      .s_axi_rvalid (s_axi_rvalid),
      .s_axi_rready (s_axi_rready)
  );

endmodule
