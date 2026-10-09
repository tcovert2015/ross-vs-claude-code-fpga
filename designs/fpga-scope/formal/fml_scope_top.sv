// fml_scope_top — formal wrapper for the scope_top property-(d) run (issue #8).
//
// Exists so the .sby script needs no string chparam (yosys string parameter handling is
// shaky): instantiates scope_top with XPORT="STREAM" (byte-per-cycle host access keeps BMC
// depths tractable), a reduced PROBE_W, and xclk/xrst tied to clk/rst (single-clock run;
// the async-FIFO logic stays fully active, per the documented same-reset usage contract).
module fml_scope_top (
    input  logic       clk,
    input  logic       rst,
    input  logic [3:0] probe,
    input  logic       trig_ext_i,
    output logic       trig_ext_o,
    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    output logic       rx_ready,
    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_ready,
    output logic       armed,
    output logic       triggered
);

  logic unused_uart_tx;

  scope_top #(
      .PROBE_W   (4),
      .DEPTH_LOG2(8),
      .XPORT     ("STREAM"),
      .ID_VALUE  (32'hF0F0_0001)
  ) dut (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .trig_ext_i   (trig_ext_i),
      .trig_ext_o   (trig_ext_o),
      .xclk         (clk),
      .xrst         (rst),
      .rx_data      (rx_data),
      .rx_valid     (rx_valid),
      .rx_ready     (rx_ready),
      .tx_data      (tx_data),
      .tx_valid     (tx_valid),
      .tx_ready     (tx_ready),
      .uart_rx      (1'b1),
      .uart_tx      (unused_uart_tx),
      .armed        (armed),
      .triggered    (triggered),
      .ext_csr_addr (8'h0),
      .ext_csr_wdata(32'h0),
      .ext_csr_write(1'b0),
      .ext_csr_read (1'b0),
      .ext_csr_rdata()
  );

endmodule
