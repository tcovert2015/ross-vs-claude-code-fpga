// scope_jtag — byte-stream front-end: bridges scope_top's XPORT="STREAM" rx/tx byte stream onto
// an Avalon-MM register window a JTAG-to-Avalon master drives (issue #15, JTAG transport).
//
// Unlike scope_avalon/scope_axil (which expose the native CSR bus), this exposes the BYTE STREAM,
// so the WHOLE framed protocol (0xA5 0x5C | cmd | len | payload | crc16) — including RLE captures —
// travels over JTAG and the *same* Python decoder works unchanged (frame.py / decode_drain). On a
// board it hangs off the existing JTAG-Avalon master next to the design's other CSRs; system-console
// moves frame bytes through the three registers below (see fpga/axc3000/sysconsole/scope_jtag.tcl).
//
// Register window (word-addressed on the Avalon master; register k at host byte 4*k):
//   0 TXDATA  W  [7:0] a byte host->scope; accepted only when STATUS.can_write=1 (1-deep buffer)
//   1 RXDATA  R  [8] rx_avail, [7:0] byte scope->host; the READ pops the scope's tx (iff avail)
//   2 STATUS  R  [1] can_write (tx buffer empty), [0] rx_avail (a byte is waiting)
//
// Half-duplex frame discipline (host writes a full request polling can_write, then reads the
// response polling rx_avail) means the 1-deep buffer + status polling never drops a byte; the JTAG
// read rate simply back-pressures the drain (tx_ready is asserted only on a RXDATA read). Zero wait
// states (waitrequest low): a byte-drop on a full write is impossible under the polling discipline.
module scope_jtag (
    input  logic        clk,
    input  logic        rst,          // synchronous, active high

    // Avalon-MM slave (32-bit, word-addressed)
    input  logic [7:0]  address,
    input  logic        read,
    output logic [31:0] readdata,
    input  logic        write,
    input  logic [31:0] writedata,
    output logic        waitrequest,

    // byte stream to scope_top (XPORT="STREAM")
    output logic [7:0]  rx_data,      // host -> scope
    output logic        rx_valid,
    input  logic        rx_ready,
    input  logic [7:0]  tx_data,      // scope -> host
    input  logic        tx_valid,
    output logic        tx_ready
);

  localparam logic [7:0] REG_TXDATA = 8'd0;
  localparam logic [7:0] REG_RXDATA = 8'd1;
  localparam logic [7:0] REG_STATUS = 8'd2;

  // 1-deep host->scope byte buffer
  logic       txb_valid;
  logic [7:0] txb_data;

  wire wr_tx = write && (address == REG_TXDATA);
  wire rd_rx = read  && (address == REG_RXDATA);

  always_ff @(posedge clk) begin
    if (rst) begin
      txb_valid <= 1'b0;
      txb_data  <= 8'h00;
    end else begin
      if (rx_ready && txb_valid) txb_valid <= 1'b0;         // scope consumed the buffered byte
      if (wr_tx && !txb_valid) begin                         // accept a new byte only when empty
        txb_data  <= writedata[7:0];
        txb_valid <= 1'b1;
      end
    end
  end

  assign rx_data  = txb_data;
  assign rx_valid = txb_valid;
  assign tx_ready = rd_rx && tx_valid;                       // pop the scope's tx on a RXDATA read

  always_comb begin
    unique case (address)
      REG_RXDATA: readdata = {23'h0, tx_valid, tx_data};      // [8]=avail, [7:0]=byte
      REG_STATUS: readdata = {30'h0, ~txb_valid, tx_valid};   // [1]=can_write, [0]=rx_avail
      default:    readdata = 32'h0;
    endcase
  end

  assign waitrequest = 1'b0;

  wire unused = &{1'b0, writedata[31:8]};

endmodule
