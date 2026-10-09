// tb_drain_cdc — scope_top end-to-end over the byte stream, xclk != clk (issue #8).
//
// Two legs, xclk:clk = 3:1 and 1:3, XPORT="STREAM", PROBE_W=32 / DEPTH_LOG2=8. Per leg:
//   * PING (ID_REG + ID_VALUE payload), WRITE_CSR config (ack carries cfg_err=0),
//     READ_CSR HWCFG — all frames CRC-checked with the TB's own CRC16 implementation;
//   * a deliberately corrupted frame -> NAK(BAD_CRC), then garbage bytes, then a clean
//     PING -> parser resynchronizes on the 0xA5 0x5C hunt;
//   * arm via WRITE_CSR(CTRL); the probe stream is aligned to the observed `armed` rise
//     (stored sample j = stim[j], the file's first two entries being the pre-arm idle
//     zeros — see the alignment note below); trig_ext_i fires at stored sample K;
//   * WHILE the capture runs, PINGs with random rx gaps + random tx_ready back-pressure
//     hammer the transport — the capture must be unaffected (proven by the byte-exact
//     drain compare, tracker rule 1 at system level);
//   * DRAIN: header frame verified field-by-field (flags/wdone/trig_index/per-window
//     meta vs the model; ts48 vs READ_CSR TSTRIG for consistency) + CRC; the DRAIN_DATA
//     frame is compared BYTE-EXACT against scope_ref.py's _dframes.mem.
// Alignment: sample_o = probe delayed 2 (scope_trigger); stores start at the `armed` rise
// cycle A; stored[j] = probe(A+j-2), so stored[0..1] are the pre-arm idle zeros and the TB
// drives probe(A+i) = stim[i+2] from the observation negedge on. trig_ext_i during cycle
// A+K makes stored K the trigger sample (trig_index = K mod DEPTH deterministically).
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */
// waiver: helper module deliberately co-located in its TB's file (not a standalone unit)
module tb_drain_leg
  import scope_pkg::*;
#(
    parameter real   CLK_HALF  = 5.0,   // capture-domain half period (ns)
    parameter real   XCLK_HALF = 15.0,  // transport-domain half period (ns)
    parameter string NAME      = "leg"
) (
    output bit done
);

  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned NB = 4;
  localparam int unsigned K = 300;  // trigger at stored sample K (run.sh table must match)
  localparam int unsigned N_STIM = K + DEPTH + 8;
  localparam logic [31:0] IDV = 32'hC0DE_0001;

  logic clk = 1'b0, xclk = 1'b0;
  always #(CLK_HALF) clk <= ~clk;
  always #(XCLK_HALF) xclk <= ~xclk;
  logic rst = 1'b1, xrst = 1'b1;

  logic [PROBE_W-1:0] probe = '0;
  logic trig_ext_i = 1'b0;
  logic [7:0] rx_data = '0;
  logic rx_valid = 1'b0;
  logic rx_ready;
  logic [7:0] tx_data;
  logic tx_valid;
  logic tx_ready = 1'b0;
  logic armed, triggered;
  logic unused_trig_ext_o, unused_uart_tx;

  scope_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .XPORT     ("STREAM"),
      .ID_VALUE  (IDV)
  ) dut (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .trig_ext_i   (trig_ext_i),
      .trig_ext_o   (unused_trig_ext_o),
      .xclk         (xclk),
      .xrst         (xrst),
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
      .ext_csr_rdata(unused_ext_rdata)
  );

  logic [31:0] unused_ext_rdata;

  logic [PROBE_W-1:0] stim[N_STIM];
  logic [63:0] exp_meta[3];
  logic [7:0] exp_df[2048];  // expected DRAIN_DATA frame bytes (1 chunk = 1033 bytes)
  initial begin
    $readmemh("sim/build/vectors/drn_stim.mem", stim);
    $readmemh("sim/build/vectors/drn_meta.mem", exp_meta);
    $readmemh("sim/build/vectors/drn_dframes.mem", exp_df);
  end

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "[%s] %s", NAME, msg);
  endtask

  // TB-side CRC16-CCITT (independent implementation: table-free, bit loop over LSB view)
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

  // ---- transport byte plumbing (xclk domain) ---------------------------------------------
  logic [7:0] rxq[$];  // bytes received from the DUT
  int unsigned bp_pct = 30;  // tx_ready back-pressure probability

  always @(posedge xclk) begin
    if (xrst) tx_ready <= 1'b0;
    else begin
      if (tx_valid && tx_ready) rxq.push_back(tx_data);
      tx_ready <= ($urandom_range(99) >= bp_pct);
    end
  end

  task automatic send_byte(input logic [7:0] b);
    bit r;
    @(negedge xclk);
    while ($urandom_range(99) < 25) @(negedge xclk);  // random gaps
    rx_data  = b;
    rx_valid = 1'b1;
    // hold valid until the posedge at which ready was high consumed the byte: sample the
    // in-cycle ready at the negedge, cross the posedge, and only then decide
    forever begin
      r = rx_ready;
      @(negedge xclk);
      if (r) break;
    end
    rx_valid = 1'b0;
  endtask

  // send a frame; corrupt_crc flips the CRC low byte
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
    send_byte(SCOPE_SYNC0);
    send_byte(SCOPE_SYNC1);
    foreach (body[i]) send_byte(body[i]);
    send_byte(crc[15:8]);
    send_byte(crc[7:0] ^ {7'h0, corrupt_crc});
  endtask

  task automatic recv_byte(output logic [7:0] b);
    int unsigned guard = 0;
    while (rxq.size() == 0) begin
      @(negedge xclk);
      guard++;
      if (guard > 500_000) fail("recv_byte timeout");
    end
    b = rxq.pop_front();
  endtask

  // receive one response frame, verify envelope + CRC, return cmd/payload
  task automatic recv_frame(output logic [7:0] cmd, output logic [7:0] payload[$]);
    logic [7:0] b, lh, ll;
    logic [7:0] body[$];
    logic [15:0] crc;
    int unsigned len;
    body.delete();  // workaround: task-local queues persist across loop-body calls (Verilator 5.020)
    recv_byte(b);
    if (b != SCOPE_SYNC0) fail($sformatf("frame sync0: got %h", b));
    recv_byte(b);
    if (b != SCOPE_SYNC1) fail($sformatf("frame sync1: got %h", b));
    recv_byte(cmd);
    body.push_back(cmd);
    recv_byte(lh);
    recv_byte(ll);
    body.push_back(lh);
    body.push_back(ll);
    len = 32'({lh, ll});
    payload.delete();
    repeat (len) begin
      recv_byte(b);
      payload.push_back(b);
      body.push_back(b);
    end
    recv_byte(lh);
    recv_byte(ll);
    crc = tb_crc16(body);
    if ({lh, ll} != crc) fail($sformatf("response CRC: wire %h vs computed %h", {lh, ll}, crc));
  endtask

  task automatic csr_write_xport(input logic [7:0] a, input logic [31:0] v,
                                 input logic exp_cfg_err);
    logic [7:0] cmd;
    logic [7:0] pl[$];
    pl.delete();
    pl.push_back(a);
    pl.push_back(v[31:24]);
    pl.push_back(v[23:16]);
    pl.push_back(v[15:8]);
    pl.push_back(v[7:0]);
    send_frame(SCOPE_OP_WRITE_CSR, pl, 1'b0);
    recv_frame(cmd, pl);
    if (cmd != SCOPE_OP_WRITE_CSR) fail("WRITE_CSR response cmd");
    if (pl.size() != 1 || pl[0] != {7'h0, exp_cfg_err})
      fail($sformatf("WRITE_CSR ack: got %h want cfg_err=%b", pl[0], exp_cfg_err));
  endtask

  task automatic csr_read_xport(input logic [7:0] a, output logic [31:0] v);
    logic [7:0] cmd;
    logic [7:0] pl[$];
    pl.delete();
    pl.push_back(a);
    send_frame(SCOPE_OP_READ_CSR, pl, 1'b0);
    recv_frame(cmd, pl);
    if (cmd != SCOPE_OP_READ_CSR) fail("READ_CSR response cmd");
    if (pl.size() != 4) fail("READ_CSR response length");
    v = {pl[0], pl[1], pl[2], pl[3]};
  endtask

  task automatic ping_check();
    logic [7:0] cmd;
    logic [7:0] pl[$];
    pl.delete();
    send_frame(SCOPE_OP_PING, pl, 1'b0);
    recv_frame(cmd, pl);
    if (cmd != SCOPE_OP_PING) fail("PING response cmd");
    if (pl.size() != 8) fail("PING response length");
    if ({pl[0], pl[1], pl[2], pl[3]} != SCOPE_ID_REG) fail("PING ID_REG");
    if ({pl[4], pl[5], pl[6], pl[7]} != IDV) fail("PING ID_VALUE");
  endtask

  // ---- probe stream aligned to the armed rise (clk domain) --------------------------------
  logic stream_go = 1'b0;
  logic armed_seen = 1'b0;
  int unsigned sidx = 0;
  always @(negedge clk) begin
    if (stream_go && (armed_seen || armed)) begin
      armed_seen <= 1'b1;
      // at relative negedge i: probe carries stim[i+2]; ext trigger at i == K
      probe      <= (sidx + 2 < N_STIM) ? stim[sidx+2] : PROBE_W'($urandom());
      trig_ext_i <= (sidx == K);
      sidx       <= sidx + 1;
    end else begin
      probe      <= '0;
      trig_ext_i <= 1'b0;
    end
  end

  // ---- main script ---------------------------------------------------------------------------
  logic [31:0] v, tsl, tsh;
  logic [7:0] rcmd;
  logic [7:0] rpl[$];

  initial begin
    // overlapping resets (async FIFO contract), each held several cycles of its own clock
    repeat (8) @(negedge clk);
    repeat (8) @(negedge xclk);
    @(negedge clk) rst = 1'b0;
    @(negedge xclk) xrst = 1'b0;
    repeat (4) @(negedge xclk);

    // liveness + identity, config, HWCFG readback
    ping_check();
    csr_write_xport(8'(CSR_PRETRIG), 32'd0, 1'b0);
    csr_write_xport(8'(CSR_WINDOWS), 32'd1, 1'b0);
    csr_read_xport(8'(CSR_HWCFG), v);
    if (v != {13'h0, 1'b0, 4'd4, 4'(DEPTH_LOG2), 10'(PROBE_W)}) fail("HWCFG via transport");

    // corrupted CRC -> NAK, garbage -> resync -> clean PING works
    begin
      logic [7:0] pl[$];
      pl.delete();
      pl.push_back(8'(CSR_ID));
      send_frame(SCOPE_OP_READ_CSR, pl, 1'b1);  // corrupt CRC
      recv_frame(rcmd, rpl);
      if (rcmd != SCOPE_OP_NAK || rpl[0] != SCOPE_NAK_BAD_CRC) fail("NAK(BAD_CRC)");
      send_byte(8'hFF);
      send_byte(8'h00);
      send_byte(SCOPE_SYNC0);  // lone sync0 followed by junk
      send_byte(8'h11);
      ping_check();  // parser resynchronized
      // unknown command -> NAK(BAD_CMD)
      pl.delete();
      send_frame(8'h7E, pl, 1'b0);
      recv_frame(rcmd, rpl);
      if (rcmd != SCOPE_OP_NAK || rpl[0] != SCOPE_NAK_BAD_CMD) fail("NAK(BAD_CMD)");
    end

    // arm; the clk-domain stream block aligns itself to the armed rise
    stream_go = 1'b1;
    csr_write_xport(8'(CSR_CTRL), 32'h1, 1'b0);

    // hammer the transport while the capture runs (capture must be unaffected)
    repeat (6) ping_check();
    do csr_read_xport(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_DONE));
    if (v[3] !== 1'b1) fail("STATUS.triggered via transport");
    if (triggered !== 1'b1) fail("triggered output");

    // trigger metadata (deterministic by construction: trig_index = K mod DEPTH)
    csr_read_xport(8'(CSR_TRIG_INDEX), v);
    if (v != 32'(K % DEPTH)) fail($sformatf("TRIG_INDEX %0d != %0d", v, K % DEPTH));
    if (v != 32'(exp_meta[0])) fail("TRIG_INDEX vs model");
    csr_read_xport(8'(CSR_TSTRIG_LO), tsl);
    csr_read_xport(8'(CSR_TSTRIG_HI), tsh);
    if (tsh[31:16] != 16'h0) fail("TSTRIG_HI upper bits not zero");

    // DRAIN: header frame field-by-field, data frame byte-exact vs the model
    begin
      logic [7:0] pl[$];
      pl.delete();
      send_frame(SCOPE_OP_DRAIN, pl, 1'b0);
      recv_frame(rcmd, rpl);
      if (rcmd != SCOPE_OP_DRAIN) fail("DRAIN header cmd");
      if (rpl.size() != 12) fail($sformatf("DRAIN header len %0d != 12", rpl.size()));
      if (rpl[0] != 8'h02) fail("DRAIN flags (wrapped=1, rle=0)");
      if (rpl[1] != 8'd1) fail("DRAIN windows_done");
      if ({rpl[2], rpl[3]} != 16'(K % DEPTH)) fail("DRAIN trig_index");
      if ({rpl[4], rpl[5]} != tsh[15:0] || {rpl[6], rpl[7], rpl[8], rpl[9]} != tsl)
        fail("DRAIN ts48 vs TSTRIG readback");
      // per-window meta (1 window): {wrapped, trig_index[14:0]}
      if ({rpl[10], rpl[11]} != {1'b1, 15'(K % DEPTH)}) fail("DRAIN window meta");
      // data frame: byte-exact against scope_ref.py (includes envelope + CRC)
      for (int unsigned i = 0; i < 7 + 2 + 256 * NB; i++) begin
        logic [7:0] b;
        recv_byte(b);
        if (b != exp_df[i])
          fail($sformatf("DRAIN_DATA byte %0d: got %h want %h", i, b, exp_df[i]));
      end
    end

    $display("-- [%s] PING/CSR/NAK/resync + byte-exact DRAIN under back-pressure", NAME);
    done = 1'b1;
  end

endmodule
/* verilator lint_on DECLFILENAME */

module tb_drain_cdc;

  bit done_a, done_b;

  tb_drain_leg #(
      .CLK_HALF (15.0),
      .XCLK_HALF(5.0),
      .NAME     ("xclk3to1")
  ) leg_a (
      .done(done_a)
  );

  tb_drain_leg #(
      .CLK_HALF (5.0),
      .XCLK_HALF(15.0),
      .NAME     ("xclk1to3")
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
