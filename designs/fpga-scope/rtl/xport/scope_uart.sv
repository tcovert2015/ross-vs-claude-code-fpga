// scope_uart — minimal UART transport: 8N1, fixed divisor, byte-stream both directions.
//
// Contract (INTERFACES.md; tracker rule 6, asserted first in tb_uart):
//   * 8N1 framing, LSB-FIRST bit order (standard UART), no parity, 1 stop bit.
//   * Fixed DIV = clk cycles per bit (clk/baud); DIV >= 4. No auto-baud in v1.
//   * tx: valid/ready byte in -> serial out (start 0, data LSB first, stop 1).
//   * rx: serial in -> 1-cycle rx_valid pulse with rx_data. Line is synchronized through
//     prim_ff_sync; start is qualified by a half-bit delay to the first data-bit center,
//     then one SIMPLE MID-BIT SAMPLE per bit (policy choice, documented: a majority-of-3
//     buys little at the divisors this core targets and costs a state machine). A stop bit
//     sampled low is a framing error: the byte is DROPPED silently (frame parser resyncs
//     on the 0xA5 0x5C hunt).
//   * No flow control on rx (real UARTs have none): the consumer (scope_top puts a small
//     prim_fifo_sync behind rx) must keep up; the command/response discipline guarantees
//     the host never streams unsolicited bulk data.
// Vendor-free, clean-room (behavioral reference only; no code from other UART cores).
module scope_uart #(
    parameter int unsigned DIV = 16  // clk cycles per bit, >= 4
) (
    input  logic       clk,
    input  logic       rst,        // synchronous, active high

    // serial pins
    input  logic       uart_rx,
    output logic       uart_tx,

    // byte stream: transmit (into the UART, out the tx pin)
    input  logic [7:0] tx_data,
    input  logic       tx_valid,
    output logic       tx_ready,

    // byte stream: receive (from the rx pin)
    output logic [7:0] rx_data,
    output logic       rx_valid    // 1-cycle pulse per good byte
);

  localparam int unsigned CNT_W = (DIV <= 2) ? 2 : $clog2(DIV) + 1;

  // ---- tx ---------------------------------------------------------------------------------
  logic [9:0] tx_shift;  // {stop, data[7:0], start}; [0] never read (start driven at load)
  wire unused_txs = &{1'b0, tx_shift[0]};
  logic [3:0] tx_bits;   // bits remaining
  logic [CNT_W-1:0] tx_cnt;

  assign tx_ready = (tx_bits == 4'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_shift <= '1;
      tx_bits  <= 4'd0;
      tx_cnt   <= '0;
      uart_tx  <= 1'b1;  // idle high
    end else begin
      if (tx_bits == 4'd0) begin
        uart_tx <= 1'b1;
        if (tx_valid) begin
          tx_shift <= {1'b1, tx_data, 1'b0};  // stop, data (LSB first), start
          tx_bits  <= 4'd10;
          tx_cnt   <= CNT_W'(DIV - 1);
          uart_tx  <= 1'b0;                   // start bit begins immediately
        end
      end else if (tx_cnt != '0) begin
        tx_cnt <= tx_cnt - 1'b1;
      end else begin
        tx_bits <= tx_bits - 4'd1;
        if (tx_bits != 4'd1) begin
          uart_tx  <= tx_shift[1];
          tx_shift <= {1'b1, tx_shift[9:1]};
          tx_cnt   <= CNT_W'(DIV - 1);
        end else begin
          uart_tx <= 1'b1;  // back to idle after the stop bit
        end
      end
    end
  end

  // ---- rx ---------------------------------------------------------------------------------
  logic rx_sync;
  prim_ff_sync #(
      .WIDTH    (1),
      .STAGES   (2),
      .RESET_VAL(1'b1)  // idle-high so reset does not fake a start bit
  ) u_rx_sync (
      .clk(clk),
      .rst(rst),
      .d  (uart_rx),
      .q  (rx_sync)
  );

  typedef enum logic [1:0] {
    RX_IDLE,
    RX_START,
    RX_BITS,
    RX_STOP
  } rx_state_e;
  rx_state_e rx_st;
  logic [CNT_W-1:0] rx_cnt;
  logic [2:0] rx_bit;
  logic [7:0] rx_shift;

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_st    <= RX_IDLE;
      rx_cnt   <= '0;
      rx_bit   <= '0;
      rx_shift <= '0;
      rx_data  <= '0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      unique case (rx_st)
        RX_IDLE: begin
          if (!rx_sync) begin  // falling edge: start bit
            rx_st  <= RX_START;
            rx_cnt <= CNT_W'(DIV / 2);  // to the start-bit center
          end
        end
        RX_START: begin
          if (rx_cnt != '0) rx_cnt <= rx_cnt - 1'b1;
          else if (!rx_sync) begin  // start still low at its center: genuine
            rx_st  <= RX_BITS;
            rx_cnt <= CNT_W'(DIV - 1);
            rx_bit <= 3'd0;
          end else begin
            rx_st <= RX_IDLE;  // glitch, ignore
          end
        end
        RX_BITS: begin
          if (rx_cnt != '0) rx_cnt <= rx_cnt - 1'b1;
          else begin
            rx_shift <= {rx_sync, rx_shift[7:1]};  // LSB arrives first
            rx_cnt   <= CNT_W'(DIV - 1);
            if (rx_bit == 3'd7) rx_st <= RX_STOP;
            else rx_bit <= rx_bit + 3'd1;
          end
        end
        RX_STOP: begin
          if (rx_cnt != '0) rx_cnt <= rx_cnt - 1'b1;
          else begin
            if (rx_sync) begin  // good stop bit
              rx_data  <= rx_shift;
              rx_valid <= 1'b1;
            end
            // stop low = framing error: drop silently
            rx_st <= RX_IDLE;
          end
        end
        default: rx_st <= RX_IDLE;
      endcase
    end
  end

endmodule
