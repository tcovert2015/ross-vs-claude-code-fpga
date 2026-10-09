// tb_uart — bit-level UART loop through scope_top, XPORT="UART" (issue #8).
//
// The TB implements its OWN serial reference model (independent code, not a copy of the
// RTL): it wiggles uart_rx bit by bit and samples uart_tx at bit centers. Two legs:
// UART_DIV = 4 and 16.
//
// FIRST TWO ASSERTIONS, in this order (tracker rule 6):
//   (1) UART byte serialization is LSB-FIRST — the first response byte (the 0xA5 sync) is
//       captured as raw line bits and must read start(0), 1,0,1,0,0,1,0,1, stop(1);
//   (2) CRC16 appears BIG-ENDIAN on the wire — the TB recomputes the PING response CRC
//       and asserts wire byte order {crc[15:8], crc[7:0]}.
// Then: READ_CSR(ID) round trip; a frame with corrupted CRC -> NAK(BAD_CRC); garbage bytes
// -> parser resyncs -> clean PING works.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_uart_leg
  import scope_pkg::*;
#(
    parameter int unsigned DIV  = 16,
    parameter string       NAME = "leg"
) (
    output bit done
);

  localparam int unsigned PROBE_W = 16;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam logic [31:0] IDV = 32'hBEEF_0042;

  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic uart_rx = 1'b1;  // idle high
  logic uart_tx;
  logic armed, triggered;
  logic [7:0] unused_tx_data;
  logic unused_tx_valid, unused_rx_ready, unused_trig_ext_o;

  scope_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .XPORT     ("UART"),
      .UART_DIV  (DIV),
      .ID_VALUE  (IDV)
  ) dut (
      .clk          (clk),
      .rst          (rst),
      .probe        ({PROBE_W{1'b0}}),
      .trig_ext_i   (1'b0),
      .trig_ext_o   (unused_trig_ext_o),
      .xclk         (clk),
      .xrst         (rst),
      .rx_data      (8'h00),
      .rx_valid     (1'b0),
      .rx_ready     (unused_rx_ready),
      .tx_data      (unused_tx_data),
      .tx_valid     (unused_tx_valid),
      .tx_ready     (1'b0),
      .uart_rx      (uart_rx),
      .uart_tx      (uart_tx),
      .armed        (armed),
      .triggered    (triggered),
      .ext_csr_addr (8'h0),
      .ext_csr_wdata(32'h0),
      .ext_csr_write(1'b0),
      .ext_csr_read (1'b0),
      .ext_csr_rdata(unused_ext_rdata)
  );

  logic [31:0] unused_ext_rdata;

  wire unused_status = &{1'b0, armed, triggered};

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // TB-side CRC16-CCITT (independent implementation)
  // NOTE: statement init, not declaration init — Verilator 5.020 does not re-run automatic
  // declaration initializers on every call, which leaks CRC state between frames.
  function automatic logic [15:0] tb_crc16(input logic [7:0] bytes_q[$]);
    logic [15:0] c;
    c = 16'hFFFF;
    foreach (bytes_q[i]) begin
      c = c ^ {bytes_q[i], 8'h00};
      repeat (8) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    end
    return c;
  endfunction

  // ---- TB reference serial model -------------------------------------------------------
  task automatic bit_wait();
    repeat (DIV) @(negedge clk);
  endtask

  // drive one byte onto uart_rx, LSB first (the TB's own definition of a UART)
  task automatic uart_send(input logic [7:0] b);
    uart_rx = 1'b0;  // start
    bit_wait();
    for (int unsigned i = 0; i < 8; i++) begin
      uart_rx = b[i];  // LSB first
      bit_wait();
    end
    uart_rx = 1'b1;  // stop
    bit_wait();
    // no idle margin: the DUT may begin its response right after the final stop bit's
    // center — a margin here would make the TB's receiver miss the response start edge
  endtask

  // capture one byte from uart_tx; optionally return the raw 10 line samples
  task automatic uart_recv(output logic [7:0] b, output logic [9:0] raw);
    int unsigned guard = 0;
    while (uart_tx !== 1'b0) begin
      @(negedge clk);
      guard++;
      if (guard > 400_000) fail("uart_recv timeout");
    end
    repeat (DIV / 2) @(negedge clk);  // start-bit center
    raw[0] = uart_tx;
    for (int unsigned i = 0; i < 8; i++) begin
      repeat (DIV) @(negedge clk);
      raw[1+i] = uart_tx;
      b[i]     = uart_tx;  // LSB first per the reference model
    end
    repeat (DIV) @(negedge clk);
    raw[9] = uart_tx;
    if (raw[9] !== 1'b1) fail("stop bit low");
    repeat (DIV / 2) @(negedge clk);  // run out the stop bit
  endtask

  task automatic send_frame(input logic [7:0] cmd, input logic [7:0] payload[$],
                            input bit corrupt_crc);
    logic [7:0] body[$];
    logic [15:0] crc;
    body.delete();  // workaround: task-local queues persist across loop-body calls (Verilator 5.020)
    body.push_back(cmd);
    body.push_back(8'(payload.size() >> 8));
    body.push_back(8'(payload.size() & 'hFF));
    foreach (payload[i]) body.push_back(payload[i]);
    crc = tb_crc16(body);
    uart_send(SCOPE_SYNC0);
    uart_send(SCOPE_SYNC1);
    foreach (body[i]) uart_send(body[i]);
    uart_send(crc[15:8]);
    uart_send(crc[7:0] ^ {7'h0, corrupt_crc});
  endtask

  task automatic recv_frame(output logic [7:0] cmd, output logic [7:0] payload[$],
                            output logic [9:0] cmd_raw, output logic [15:0] wire_crc);
    logic [7:0] b;
    logic [9:0] unused_raw;
    logic [7:0] body[$];
    logic [15:0] crc;
    int unsigned len;
    body.delete();  // workaround: task-local queues persist across loop-body calls (Verilator 5.020)
    uart_recv(b, unused_raw);
    if (b != SCOPE_SYNC0) fail($sformatf("resp sync0: got %h", b));
    uart_recv(b, unused_raw);
    if (b != SCOPE_SYNC1) fail("resp sync1");
    uart_recv(cmd, cmd_raw);  // line bits of the cmd byte, for the LSB-first assert
    body.push_back(cmd);
    uart_recv(b, unused_raw);
    body.push_back(b);
    len = 32'({b, 8'h00});
    uart_recv(b, unused_raw);
    body.push_back(b);
    len = len | 32'({8'h00, b});
    payload.delete();
    repeat (len) begin
      uart_recv(b, unused_raw);
      payload.push_back(b);
      body.push_back(b);
    end
    uart_recv(b, unused_raw);
    wire_crc[15:8] = b;
    uart_recv(b, unused_raw);
    wire_crc[7:0] = b;
    crc = tb_crc16(body);
    if (wire_crc != crc) fail($sformatf("resp CRC %h != computed %h", wire_crc, crc));
  endtask

  logic [7:0] rcmd;
  logic [7:0] rpl[$];
  logic [9:0] raw0;
  logic [15:0] wcrc;

  initial begin
    repeat (8) @(negedge clk);
    rst = 1'b0;
    repeat (8) @(negedge clk);

    // ---- assertion (1): LSB-first serialization; (2): CRC big-endian on the wire -------
    begin
      logic [7:0] pl[$];
      logic [7:0] body[$];
      logic [15:0] crc;
      pl.delete();
      send_frame(SCOPE_OP_PING, pl, 1'b0);
      recv_frame(rcmd, rpl, raw0, wcrc);
      // (1) the response cmd byte is 0x01 (PING) — NOT a bit-order palindrome (0xA5 is!)
      //     — so its raw line order proves LSB-first: start(0), 1,0,0,0,0,0,0,0, stop(1)
      if (raw0 !== 10'b1_00000001_0)  // {stop, d7..d0, start} as sampled into raw[9:0]
        fail($sformatf("UART not LSB-first: cmd raw=%b", raw0));
      // (2) CRC16 transmitted big-endian: recompute over cmd..payload and compare order
      body.push_back(rcmd);
      body.push_back(8'(rpl.size() >> 8));
      body.push_back(8'(rpl.size() & 'hFF));
      foreach (rpl[i]) body.push_back(rpl[i]);
      crc = tb_crc16(body);
      if (wcrc[15:8] != crc[15:8] || wcrc[7:0] != crc[7:0])
        fail("CRC16 not big-endian on the wire");
      // PING content
      if (rcmd != SCOPE_OP_PING || rpl.size() != 8) fail("PING response");
      if ({rpl[0], rpl[1], rpl[2], rpl[3]} != SCOPE_ID_REG) fail("PING ID_REG");
      if ({rpl[4], rpl[5], rpl[6], rpl[7]} != IDV) fail("PING ID_VALUE");
    end

    // ---- READ_CSR round trip -------------------------------------------------------------
    begin
      logic [7:0] pl[$];
      pl.delete();
      pl.push_back(8'(CSR_ID));
      send_frame(SCOPE_OP_READ_CSR, pl, 1'b0);
      recv_frame(rcmd, rpl, raw0, wcrc);
      if (rcmd != SCOPE_OP_READ_CSR || rpl.size() != 4) fail("READ_CSR response");
      if ({rpl[0], rpl[1], rpl[2], rpl[3]} != SCOPE_ID_REG) fail("READ_CSR(ID) value");
    end

    // ---- corrupted CRC -> NAK; garbage -> resync -> PING ok -------------------------------
    begin
      logic [7:0] pl[$];
      pl.delete();
      pl.push_back(8'(CSR_ID));
      send_frame(SCOPE_OP_READ_CSR, pl, 1'b1);
      recv_frame(rcmd, rpl, raw0, wcrc);
      if (rcmd != SCOPE_OP_NAK || rpl[0] != SCOPE_NAK_BAD_CRC) fail("NAK(BAD_CRC) via UART");
      uart_send(8'h00);
      uart_send(8'hF7);
      uart_send(SCOPE_SYNC0);
      uart_send(8'h99);  // false sync
      pl.delete();
      send_frame(SCOPE_OP_PING, pl, 1'b0);
      recv_frame(rcmd, rpl, raw0, wcrc);
      if (rcmd != SCOPE_OP_PING) fail("resync after garbage");
    end

    $display("-- [%s] DIV=%0d: LSB-first + BE CRC asserted, NAK + resync clean", NAME, DIV);
    done = 1'b1;
  end

endmodule
/* verilator lint_on DECLFILENAME */

module tb_uart;

  bit done_a, done_b;

  tb_uart_leg #(
      .DIV (4),
      .NAME("div4")
  ) leg_a (
      .done(done_a)
  );

  tb_uart_leg #(
      .DIV (16),
      .NAME("div16")
  ) leg_b (
      .done(done_b)
  );

  initial begin
    wait (done_a && done_b);
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin
    #100ms;
    $display("TB_RESULT: FAIL");
    $fatal(1, "timeout: done=%b%b", done_a, done_b);
  end

endmodule
