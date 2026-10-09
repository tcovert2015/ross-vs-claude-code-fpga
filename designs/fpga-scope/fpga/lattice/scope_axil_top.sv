// scope_axil_top — AXI4-Lite-attached fpga-scope instance for Lattice Radiant (Certus-NX).
//
// A THIN wrapper: scope_top with XPORT="CSR" (no byte transport, no CDC FIFOs) plus the
// scope_axil front-end on the native CSR bus. Zero logic of its own. The AXI4-Lite slave uses
// the standard s_axi_* names so it drops into a Lattice Propel / any AXI interconnect. Runs
// entirely in the capture domain (`clk`); host-side CDC is the integrating fabric's problem
// (same clock-domain contract as rtl/if/scope_axil.sv, see docs/INTERFACES.md).
//
// No vendor primitives: the capture buffer is inferred from rtl/prim/prim_ram_1r1w.sv.
module scope_axil_top #(
    parameter int unsigned PROBE_W    = 32,       // 1..512
    parameter int unsigned DEPTH_LOG2 = 12,       // 8..15
    parameter bit          RLE_EN     = 1'b1,     // STORE_W = PROBE_W+1 (matches README table)
    parameter logic [31:0] ID_VALUE   = 32'h0
) (
    input  logic               clk,
    input  logic               rst,        // synchronous, active high

    // capture
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,
    output logic               armed,
    output logic               triggered,

    // AXI4-Lite slave (32-bit data, 10-bit byte address; [9:2] = CSR word)
    input  logic [9:0]         s_axi_awaddr,
    input  logic [2:0]         s_axi_awprot,   // accepted, ignored
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
    input  logic [2:0]         s_axi_arprot,   // accepted, ignored
    input  logic               s_axi_arvalid,
    output logic               s_axi_arready,
    output logic [31:0]        s_axi_rdata,
    output logic [1:0]         s_axi_rresp,
    output logic               s_axi_rvalid,
    input  logic               s_axi_rready
);

  // native CSR bus: scope_axil (master) -> scope_top ext_csr_* (XPORT="CSR")
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

  // byte-stream / UART outputs are constant in CSR mode
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

  wire _unused = &{1'b0, s_axi_awprot, s_axi_arprot, unused_rx_ready, unused_tx_valid,
                   unused_uart_tx, unused_tx_data};

endmodule
