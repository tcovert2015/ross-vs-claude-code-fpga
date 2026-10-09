// tb_jtag — the framed protocol over the scope_jtag byte bridge, byte-identical to STREAM (#15).
//
// scope_top(XPORT="STREAM") + scope_jtag: the TB plays the JTAG-to-Avalon master, moving frame
// bytes through the bridge's TXDATA/RXDATA/STATUS registers (send_byte polls can_write; recv_byte
// polls rx_avail). Runs PING / WRITE_CSR / READ_CSR / arm+capture / DRAIN, and compares the drained
// DRAIN_DATA frame BYTE-EXACT against scope_ref.py's drn_dframes.mem — the same golden bytes
// tb_drain_cdc checks over the raw stream, so a match proves the bridge is transparent.
// Reuses the run.sh `drn` vectors (K=300, seed 0xD4A1DA7A, idle-prefix 2). Single clock.
`timescale 1ns / 1ps

module tb_jtag
  import scope_pkg::*;
;

  localparam int unsigned PROBE_W = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned NB = 4;
  localparam int unsigned K = 300;                 // trigger at stored sample K (matches run.sh)
  localparam int unsigned N_STIM = K + DEPTH + 8;
  localparam logic [31:0] IDV = 32'hC0DE_0001;

  logic clk = 1'b0;  always #5 clk <= ~clk;
  logic rst = 1'b1;

  logic [PROBE_W-1:0] probe = '0;
  logic trig_ext_i = 1'b0;
  logic armed, triggered;

  // Avalon master side (driven by this TB)
  logic [7:0]  av_addr;
  logic        av_read, av_write;
  logic [31:0] av_wdata, av_rdata;

  // bridge <-> scope byte stream
  logic [7:0] s_rx_data, s_tx_data;
  logic       s_rx_valid, s_rx_ready, s_tx_valid, s_tx_ready;

  /* verilator lint_off PINCONNECTEMPTY */
  scope_jtag u_bridge (
      .clk(clk), .rst(rst),
      .address(av_addr), .read(av_read), .readdata(av_rdata),
      .write(av_write), .writedata(av_wdata), .waitrequest(),
      .rx_data(s_rx_data), .rx_valid(s_rx_valid), .rx_ready(s_rx_ready),
      .tx_data(s_tx_data), .tx_valid(s_tx_valid), .tx_ready(s_tx_ready));

  scope_top #(.PROBE_W(PROBE_W), .DEPTH_LOG2(DEPTH_LOG2), .XPORT("STREAM"), .ID_VALUE(IDV)) dut (
      .clk(clk), .rst(rst), .probe(probe), .trig_ext_i(trig_ext_i), .trig_ext_o(),
      .xclk(clk), .xrst(rst),
      .rx_data(s_rx_data), .rx_valid(s_rx_valid), .rx_ready(s_rx_ready),
      .tx_data(s_tx_data), .tx_valid(s_tx_valid), .tx_ready(s_tx_ready),
      .uart_rx(1'b1), .uart_tx(),
      .armed(armed), .triggered(triggered),
      .ext_csr_addr(8'h0), .ext_csr_wdata(32'h0), .ext_csr_write(1'b0),
      .ext_csr_read(1'b0), .ext_csr_rdata());
  /* verilator lint_on PINCONNECTEMPTY */

  logic [PROBE_W-1:0] stim[N_STIM];
  logic [7:0] exp_df[2048];
  initial begin
    $readmemh("sim/build/vectors/drn_stim.mem", stim);
    $readmemh("sim/build/vectors/drn_dframes.mem", exp_df);
  end

  wire unused = &{1'b0, triggered};

  task automatic fail(input string m); $display("TB_RESULT: FAIL"); $fatal(1, "%s", m); endtask

  /* verilator lint_off UNUSEDSIGNAL */  // status/rxdata reads use only a couple of bits
  // ---- Avalon register access (this TB is the JTAG-Avalon master) --------------------------
  task automatic av_wr(input logic [7:0] a, input logic [31:0] d);
    @(negedge clk); av_addr = a; av_wdata = d; av_write = 1'b1;
    @(negedge clk); av_write = 1'b0;
  endtask
  task automatic av_rd(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk); av_addr = a; av_read = 1'b1;
    #2; d = av_rdata;
    @(negedge clk); av_read = 1'b0;
  endtask

  // ---- byte stream over the bridge --------------------------------------------------------
  task automatic send_byte(input logic [7:0] b);
    logic [31:0] st;
    forever begin av_rd(8'd2, st); if (st[1]) break; end   // STATUS.can_write
    av_wr(8'd0, {24'h0, b});                                 // TXDATA
  endtask
  task automatic recv_byte(output logic [7:0] b);
    logic [31:0] r;
    int unsigned guard = 0;
    forever begin
      av_rd(8'd1, r);                                        // RXDATA: [8]=avail, [7:0]=byte
      if (r[8]) begin b = r[7:0]; break; end
      guard++; if (guard > 2_000_000) fail("recv_byte timeout");
    end
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- CRC + frame helpers (independent CRC, same as tb_drain_cdc) -------------------------
  function automatic logic [15:0] tb_crc16(input logic [7:0] q[$]);
    logic [15:0] c; c = 16'hFFFF;
    foreach (q[i]) begin c = c ^ {q[i], 8'h00}; repeat (8) c = c[15] ? ((c<<1)^16'h1021) : (c<<1); end
    return c;
  endfunction

  task automatic send_frame(input logic [7:0] cmd, input logic [7:0] payload[$]);
    logic [7:0] body[$]; logic [15:0] crc;
    body.delete(); body.push_back(cmd);
    body.push_back(8'(payload.size() >> 8)); body.push_back(8'(payload.size() & 'hFF));
    foreach (payload[i]) body.push_back(payload[i]);
    crc = tb_crc16(body);
    send_byte(SCOPE_SYNC0); send_byte(SCOPE_SYNC1);
    foreach (body[i]) send_byte(body[i]);
    send_byte(crc[15:8]); send_byte(crc[7:0]);
  endtask

  task automatic recv_frame(output logic [7:0] cmd, output logic [7:0] payload[$]);
    logic [7:0] b, lh, ll; logic [7:0] body[$]; logic [15:0] crc; int unsigned len;
    body.delete();
    recv_byte(b); if (b != SCOPE_SYNC0) fail($sformatf("sync0 %h", b));
    recv_byte(b); if (b != SCOPE_SYNC1) fail($sformatf("sync1 %h", b));
    recv_byte(cmd); body.push_back(cmd);
    recv_byte(lh); recv_byte(ll); body.push_back(lh); body.push_back(ll);
    len = 32'({lh, ll}); payload.delete();
    repeat (len) begin recv_byte(b); payload.push_back(b); body.push_back(b); end
    recv_byte(lh); recv_byte(ll); crc = tb_crc16(body);
    if ({lh, ll} != crc) fail($sformatf("response CRC wire %h vs %h", {lh, ll}, crc));
  endtask

  task automatic csr_write_j(input logic [7:0] a, input logic [31:0] v);
    logic [7:0] cmd; logic [7:0] pl[$];
    pl.delete(); pl.push_back(a);
    pl.push_back(v[31:24]); pl.push_back(v[23:16]); pl.push_back(v[15:8]); pl.push_back(v[7:0]);
    send_frame(SCOPE_OP_WRITE_CSR, pl); recv_frame(cmd, pl);
    if (cmd != SCOPE_OP_WRITE_CSR || pl[0] != 8'h0) fail("WRITE_CSR ack/cfg_err");
  endtask
  task automatic csr_read_j(input logic [7:0] a, output logic [31:0] v);
    logic [7:0] cmd; logic [7:0] pl[$];
    pl.delete(); pl.push_back(a);
    send_frame(SCOPE_OP_READ_CSR, pl); recv_frame(cmd, pl);
    if (cmd != SCOPE_OP_READ_CSR || pl.size() != 4) fail("READ_CSR resp");
    v = {pl[0], pl[1], pl[2], pl[3]};
  endtask

  // ---- probe stream aligned to the armed rise (same discipline as tb_drain_cdc) ------------
  logic armed_seen = 1'b0;
  int unsigned sidx = 0;
  always @(negedge clk) begin
    if (!rst && (armed_seen || armed)) begin
      armed_seen <= 1'b1;
      probe      <= (sidx + 2 < N_STIM) ? stim[sidx+2] : PROBE_W'(sidx);
      trig_ext_i <= (sidx == K);
      sidx       <= sidx + 1;
    end else begin
      probe <= '0; trig_ext_i <= 1'b0;
    end
  end

  logic [31:0] v;
  logic [7:0] rcmd, rpl[$];
  initial begin
    av_addr = 8'h0; av_read = 1'b0; av_write = 1'b0; av_wdata = 32'h0;
    repeat (10) @(negedge clk); rst = 1'b0; repeat (4) @(negedge clk);

    // liveness + identity
    begin logic [7:0] pl[$]; pl.delete(); send_frame(SCOPE_OP_PING, pl); recv_frame(rcmd, rpl); end
    if (rcmd != SCOPE_OP_PING || rpl.size() != 8) fail("PING resp");
    if ({rpl[0],rpl[1],rpl[2],rpl[3]} != SCOPE_ID_REG) fail("PING ID_REG");
    if ({rpl[4],rpl[5],rpl[6],rpl[7]} != IDV) fail("PING ID_VALUE");

    // config + HWCFG readback
    csr_write_j(8'(CSR_PRETRIG), 32'd0);
    csr_write_j(8'(CSR_WINDOWS), 32'd1);
    csr_read_j(8'(CSR_HWCFG), v);
    if (v != {13'h0, 1'b0, 4'd4, 4'(DEPTH_LOG2), 10'(PROBE_W)}) fail("HWCFG over JTAG");

    // arm; drive stimulus; wait DONE
    csr_write_j(8'(CSR_CTRL), 32'h1);
    do csr_read_j(8'(CSR_STATUS), v); while (v[2:0] != 3'(SCOPE_ST_DONE));
    if (!v[3]) fail("STATUS.triggered over JTAG");
    if (v != {16'h0, 8'd1, 2'b00, 1'b0, 1'b1, 1'b1, 3'(SCOPE_ST_DONE)}) fail("STATUS fields");

    // DRAIN: header + data. Verify header cmd, then the DATA frame BYTE-EXACT vs the model.
    begin
      logic [7:0] pl[$]; logic [7:0] b;
      pl.delete(); send_frame(SCOPE_OP_DRAIN, pl);
      recv_frame(rcmd, rpl);
      if (rcmd != SCOPE_OP_DRAIN || rpl.size() != 12) fail("DRAIN header");
      if (rpl[0] != 8'h02 || rpl[1] != 8'd1) fail("DRAIN flags/wdone");
      if ({rpl[2],rpl[3]} != 16'(K % DEPTH)) fail("DRAIN trig_index");
      // DRAIN_DATA frame: byte-exact vs scope_ref (envelope + CRC + 256*NB samples)
      for (int unsigned i = 0; i < 7 + 2 + 256 * NB; i++) begin
        recv_byte(b);
        if (b != exp_df[i]) fail($sformatf("DRAIN_DATA byte %0d: got %h want %h", i, b, exp_df[i]));
      end
    end

    $display("-- PING/CSR/DRAIN byte-exact over the scope_jtag byte bridge (== STREAM path)");
    $display("TB_RESULT: PASS");
    $finish;
  end

  initial begin #200ms; fail("timeout"); end

endmodule
