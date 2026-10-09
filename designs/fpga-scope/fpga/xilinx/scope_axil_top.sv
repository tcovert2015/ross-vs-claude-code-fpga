// scope_axil_top — AXI4-Lite-attached fpga-scope for AMD Vivado (IP Integrator friendly).
//
// A THIN structural wrapper: zero scope logic. It instantiates scope_top with XPORT="CSR" (no
// byte transport, no CDC FIFOs) and the scope_axil front-end, and renames the bus to the
// standard `s_axi_*` port group so Vivado IP Integrator infers one AXI4-Lite slave interface.
// (IPI will not take a SystemVerilog file as the top of an RTL module reference, so block
// designs reference the zero-logic Verilog shim scope_axil_bd.v, which wraps this module.)
//
// Policy decisions:
//   * ONE clock: `clk` is the probe/capture clock AND the AXI clock (scope_axil's documented
//     clock-domain contract, docs/INTERFACES.md). If the AXI master lives in another domain,
//     put an AXI clock converter in front — host-side CDC is the integrating fabric's problem.
//   * Reset is the AXI convention, `aresetn` (active low). The core wants a synchronous
//     active-high reset, so it is inverted and registered once here. AXI requires the master
//     to hold VALIDs low during reset, so the one-cycle release skew is harmless.
//   * `s_axi_awprot` / `s_axi_arprot` are accepted and ignored (AXI4-Lite slaves may ignore
//     PROT); they exist so the inferred interface is complete. Responses are always OKAY.
//   * Address is the 10-bit byte address of scope_axil ([9:2] = CSR word): a 1 KiB window.
//   * The X_INTERFACE_* attributes are Vivado-only hints (ignored by every other tool); they
//     associate `clk` with the s_axi bus + `aresetn` and declare the reset polarity. No vendor
//     primitives — the file still elaborates in Verilator / xsim / Yosys.
module scope_axil_top #(
    parameter int unsigned PROBE_W    = 32,       // 1..512
    parameter int unsigned DEPTH_LOG2 = 12,       // 8..15
    parameter int unsigned NUM_CMP    = 4,
    parameter int unsigned SEQ_STAGES = 4,
    parameter bit          RLE_EN     = 1'b1,     // 1 => stored word is PROBE_W+1 bits
    parameter int unsigned TS_W       = 48,
    parameter logic [31:0] ID_VALUE   = 32'h0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *)
    input  logic               clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic               aresetn,

    // capture
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,
    output logic               armed,
    output logic               triggered,

    // AXI4-Lite slave (32-bit data, 10-bit byte address)
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
    input  logic               s_axi_rready
);

  // synchronous active-high reset for the core, from the active-low AXI reset
  logic rst;
  always_ff @(posedge clk) rst <= !aresetn;

  // native CSR bus (scope_axil -> scope_top)
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

  // byte-stream / UART ports are tied off inside scope_top in CSR mode
  logic [7:0] unused_tx_data;
  logic       unused_rx_ready, unused_tx_valid, unused_uart_tx;

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

  wire unused_top = &{1'b0, s_axi_awprot, s_axi_arprot, unused_tx_data, unused_rx_ready,
                      unused_tx_valid, unused_uart_tx};

endmodule
