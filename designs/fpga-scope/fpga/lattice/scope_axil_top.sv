// scope_axil_top — AXI4-Lite-attached fpga-scope for Lattice Radiant (Certus-NX build top).
//
// What it is: scope_top in XPORT="CSR" mode with the scope_axil front-end bolted onto its
// native CSR bus, exposing a standard AXI4-Lite slave port group (`s_axi_*`). Zero logic of
// its own beyond the reset polarity flip — this is the drop-in shape for a Propel / block
// design, and the top used by fpga/lattice/build.tcl for the utilization + timing numbers.
//
// Policy decisions:
//   * One clock: `clk` is both the capture clock and the AXI clock (scope_axil's clock-domain
//     contract: it runs in scope_csr's domain). In CSR mode scope_top's transport domain
//     (xclk/xrst, byte stream, UART) is unused and tied off here.
//   * Reset is the AXI-standard active-low `s_axi_aresetn`, treated as synchronous to `clk`
//     and inverted into the core's synchronous active-high `rst`.
//   * `s_axi_awprot` / `s_axi_arprot` are accepted for port-group completeness and ignored
//     (as `wstrb` is inside scope_axil). Responses are always OKAY.
//   * RLE_EN defaults to 1 to match the README "Logic usage" configuration (STORE_W =
//     PROBE_W+1, so the capture buffer is DEPTH x 33 at PROBE_W=32).
module scope_axil_top #(
    parameter int unsigned PROBE_W    = 32,       // 1..512
    parameter int unsigned DEPTH_LOG2 = 12,       // 8..15
    parameter bit          RLE_EN     = 1'b1,
    parameter logic [31:0] ID_VALUE   = 32'h0
) (
    input  logic               clk,            // capture clock == AXI clock (ACLK)
    input  logic               s_axi_aresetn,  // synchronous, active low

    // AXI4-Lite slave (32-bit data, 10-bit byte address; [9:2] = CSR word)
    input  logic [9:0]         s_axi_awaddr,
    input  logic [2:0]         s_axi_awprot,
    input  logic               s_axi_awvalid,
    output logic               s_axi_awready,
    input  logic [31:0]        s_axi_wdata,
    input  logic [3:0]         s_axi_wstrb,
    input  logic               s_axi_wvalid,
    output logic               s_axi_wready,
    output logic [1:0]         s_axi_bresp,
    output logic               s_axi_bvalid,
    input  logic               s_axi_bready,
    input  logic [9:0]         s_axi_araddr,
    input  logic [2:0]         s_axi_arprot,
    input  logic               s_axi_arvalid,
    output logic               s_axi_arready,
    output logic [31:0]        s_axi_rdata,
    output logic [1:0]         s_axi_rresp,
    output logic               s_axi_rvalid,
    input  logic               s_axi_rready,

    // scope
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,
    output logic               armed,
    output logic               triggered
);

  wire rst = ~s_axi_aresetn;

  logic [7:0]  csr_addr;
  logic [31:0] csr_wdata;
  logic        csr_write, csr_read;
  logic [31:0] csr_rdata;

  scope_axil u_axil (
      .clk      (clk),
      .rst      (rst),
      .awaddr   (s_axi_awaddr),
      .awvalid  (s_axi_awvalid),
      .awready  (s_axi_awready),
      .wdata    (s_axi_wdata),
      .wstrb    (s_axi_wstrb),
      .wvalid   (s_axi_wvalid),
      .wready   (s_axi_wready),
      .bresp    (s_axi_bresp),
      .bvalid   (s_axi_bvalid),
      .bready   (s_axi_bready),
      .araddr   (s_axi_araddr),
      .arvalid  (s_axi_arvalid),
      .arready  (s_axi_arready),
      .rdata    (s_axi_rdata),
      .rresp    (s_axi_rresp),
      .rvalid   (s_axi_rvalid),
      .rready   (s_axi_rready),
      .csr_addr (csr_addr),
      .csr_wdata(csr_wdata),
      .csr_write(csr_write),
      .csr_read (csr_read),
      .csr_rdata(csr_rdata)
  );

  // Transport-domain outputs are constant in CSR mode (scope_top g_csr_mode ties them off).
  logic       unused_rx_ready, unused_tx_valid, unused_uart_tx;
  logic [7:0] unused_tx_data;

  scope_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .RLE_EN    (RLE_EN),
      .XPORT     ("CSR"),
      .ID_VALUE  (ID_VALUE)
  ) u_scope (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .trig_ext_i   (trig_ext_i),
      .trig_ext_o   (trig_ext_o),
      .xclk         (clk),
      .xrst         (rst),
      .rx_data      (8'h00),
      .rx_valid     (1'b0),
      .rx_ready     (unused_rx_ready),
      .tx_data      (unused_tx_data),
      .tx_valid     (unused_tx_valid),
      .tx_ready     (1'b0),
      .uart_rx      (1'b1),
      .uart_tx      (unused_uart_tx),
      .armed        (armed),
      .triggered    (triggered),
      .ext_csr_addr (csr_addr),
      .ext_csr_wdata(csr_wdata),
      .ext_csr_write(csr_write),
      .ext_csr_read (csr_read),
      .ext_csr_rdata(csr_rdata)
  );

  wire _unused = &{1'b0, s_axi_awprot, s_axi_arprot, unused_rx_ready, unused_tx_data,
                   unused_tx_valid, unused_uart_tx};

endmodule
