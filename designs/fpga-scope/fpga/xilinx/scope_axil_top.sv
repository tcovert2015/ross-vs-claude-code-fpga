// scope_axil_top — AXI4-Lite-attached fpga-scope for AMD Vivado (Artix-7 flow in build.tcl).
//
// Pure structure, zero logic: scope_top (XPORT="CSR", no byte transport, no async FIFOs) with
// the rtl/if/scope_axil.sv front-end driving its native CSR port. The slave port group uses
// the standard `s_axi_*` names so Vivado IP Integrator infers one AXI4-Lite interface
// (the X_INTERFACE attributes below pin down the bus/clock/reset association explicitly).
//
//   * Address: 10-bit byte address (256 CSR words x 4); s_axi_awaddr/araddr[1:0] are ignored.
//   * s_axi_awprot/arprot are accepted and ignored (present because AXI4-Lite requires them).
//   * Reset: scope_top/scope_axil use a synchronous ACTIVE-HIGH reset; AXI uses active-low
//     `aresetn`. The only "logic" here is that inversion.
//   * Clocking: one clock. The AXI4-Lite port runs in the capture domain (`clk`), exactly as
//     scope_axil's contract states — put an AXI clock converter in front if the bus master
//     lives elsewhere.
//   * Unused scope_top transport ports (STREAM/UART) are tied off / left open.
//
// CSR map and semantics: docs/INTERFACES.md (BUF_CTRL/BUF_DATA at words 96/97 are the drain path).
module scope_axil_top #(
    parameter int unsigned PROBE_W    = 32,       // 1..512
    parameter int unsigned DEPTH_LOG2 = 12,       // 8..15
    parameter int unsigned NUM_CMP    = 4,
    parameter int unsigned SEQ_STAGES = 4,
    parameter bit          RLE_EN     = 1'b1,     // STORE_W = PROBE_W+1 (matches the README table)
    parameter int unsigned TS_W       = 48,
    parameter logic [31:0] ID_VALUE   = 32'h0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  logic               clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic               aresetn,     // synchronous to clk, active low

    // ---- AXI4-Lite slave (32-bit data, 10-bit byte address) ----
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

    // ---- scope ----
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,
    output logic               armed,
    output logic               triggered
);

  // active-high synchronous reset for the scope, registered once (keeps the aresetn fan-out
  // off the pin and gives the tools a local, replicable reset net)
  logic rst;
  always_ff @(posedge clk) rst <= ~aresetn;

  logic [7:0]  csr_addr;
  logic [31:0] csr_wdata, csr_rdata;
  logic        csr_write, csr_read;

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

  // transport outputs that do not exist in CSR mode (scope_top ties them to constants)
  logic       unused_rx_ready, unused_tx_valid, unused_uart_tx;
  logic [7:0] unused_tx_data;

  scope_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .NUM_CMP   (NUM_CMP),
      .SEQ_STAGES(SEQ_STAGES),
      .RLE_EN    (RLE_EN),
      .TS_W      (TS_W),
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

  wire unused_top = &{1'b0, s_axi_awprot, s_axi_arprot, unused_rx_ready, unused_tx_valid,
                      unused_tx_data, unused_uart_tx};

endmodule
