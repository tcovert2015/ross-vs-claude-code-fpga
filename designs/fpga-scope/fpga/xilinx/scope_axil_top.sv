// scope_axil_top — AXI4-Lite wrapper of scope_top for AMD Vivado (IP Integrator friendly).
//
// A THIN structural wrapper: zero scope logic. Instantiates scope_top with XPORT="CSR" (no byte
// transport, no CDC FIFOs) and the rtl/if/scope_axil.sv front-end, and renames the bus to the
// standard `s_axi_*` port group so Vivado infers an AXI4-Lite slave interface when the module is
// dropped into a block design ("Add Module"). The X_INTERFACE_* attributes pin down the
// clock/reset association; every other tool ignores them.
//
//   * Clock: single domain. `clk` is the capture clock AND the AXI clock (scope_axil's
//     clock-domain contract, docs/INTERFACES.md) — connect it to the probed logic's clock and
//     put an AXI clock converter in front if the bus lives elsewhere.
//   * Reset: `s_axi_aresetn` is the AXI-standard active-low reset, sampled synchronously. It is
//     inverted (combinationally, no added latency, so the AXI "no handshake in reset" rule is
//     preserved) into the scope's synchronous active-high `rst`.
//   * Address: 10-bit byte address, [9:2] = CSR word (docs/INTERFACES.md CSR map), 1 KiB.
//   * s_axi_awprot/arprot are not implemented (optional for an AXI4-Lite slave).
//   * The transport-domain ports of scope_top are unused in CSR mode: xclk/xrst are tied to
//     clk/rst and the stream/UART inputs to their idle levels.
module scope_axil_top #(
    parameter int unsigned PROBE_W    = 32,      // 1..512
    parameter int unsigned DEPTH_LOG2 = 12,      // 8..15
    parameter bit          RLE_EN     = 1'b1,    // 1: buffer stores PROBE_W+1 bit RLE words
    parameter logic [31:0] ID_VALUE   = 32'h0    // user tag
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  logic               clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic               s_axi_aresetn,

    // AXI4-Lite slave (32-bit data, 10-bit byte address)
    input  logic [9:0]         s_axi_awaddr,
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
    input  logic               s_axi_arvalid,
    output logic               s_axi_arready,
    output logic [31:0]        s_axi_rdata,
    output logic [1:0]         s_axi_rresp,
    output logic               s_axi_rvalid,
    input  logic               s_axi_rready,

    // capture domain (same clock)
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,
    output logic               armed,
    output logic               triggered
);

  wire rst = ~s_axi_aresetn;

  // native CSR bus: scope_axil (master) -> scope_top ext_csr_* port
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

  // unused transport-domain outputs of scope_top in CSR mode (constant tie-offs inside)
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

  wire unused_xport = &{1'b0, unused_rx_ready, unused_tx_data, unused_tx_valid, unused_uart_tx};

endmodule
