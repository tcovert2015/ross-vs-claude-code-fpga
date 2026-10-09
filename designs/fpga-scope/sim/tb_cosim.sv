// tb_cosim — Verilator co-simulation harness for the Python host (issue #10).
//
// The REAL scope_top (XPORT="STREAM") runs here; the Python host tool (host/fpgapa_scope,
// driven by host/tests/test_cosim.py) speaks the frame protocol to it over two dedicated
// pipe fds (see sim/cosim_io.cpp). The clock free-runs continuously; byte I/O is polled
// non-blocking each cycle, so the capture advances at its own pace regardless of host timing
// — exactly like real silicon over a UART.
//
// Stimulus contract (identical discipline to the proven tb_drain_cdc, so the captured buffer
// matches sim/model/scope_ref.py byte-for-byte):
//   * one clock for both domains (clk == xclk); CDC across xclk!=clk is proven separately by
//     tb_drain_cdc, so co-sim keeps it single-clock for a deterministic free-run.
//   * probe stimulus starts at the `armed` rise (FILLING entry). At armed-relative sample i
//     the probe carries gen_stim(seed, i) — the same address-seeded xorshift32 stream as
//     scope_ref.gen_stimulus() for PROBE_W=32. The 2-cycle scope_trigger pipeline makes the
//     first two stored samples the pre-arm idle zeros, matching `capture --idle-prefix 2`.
//   * trig_ext_i pulses at armed-relative sample `trig_sample` (plusarg), so the model's
//     `--trig-sample <trig_sample>` reproduces trig_index/wrapped exactly.
//
// RLE_EN (build param, set via verilator -GRLE_EN=1'b1) elaborates the scope_rle store path;
// the host enables runtime compression by writing RLE_CTRL and decodes in the word domain.
//
// Plusargs:  +seed=<hex32>   +trig_sample=<dec>   +dwell=<dec>   (dwell>1 holds each generated
// value for `dwell` cycles -> runs, so RLE emits count words)
`timescale 1ns / 1ps

module tb_cosim #(
    parameter bit RLE_EN = 1'b0
);

  localparam int unsigned PROBE_W    = 32;
  localparam int unsigned DEPTH_LOG2 = 8;
  localparam logic [31:0] IDV        = 32'hF00D_1234;

  // -- DPI byte bridge (sim/cosim_io.cpp) --------------------------------------------------
  import "DPI-C" function int  cosim_rx_byte();       // -2=EOF, -1=none, 0..255=byte
  import "DPI-C" function void cosim_tx_byte(input int b);

  // -- plusargs ----------------------------------------------------------------------------
  logic [31:0] seed = 32'hC0FFEE01;
  int unsigned trig_sample = 300;
  int unsigned dwell = 1;                 // hold each generated value this many cycles (runs)
  int unsigned probe_mode = 0;            // 0 = xorshift stimulus; 1 = free-running counter probe
  initial begin
    void'($value$plusargs("seed=%h", seed));
    void'($value$plusargs("trig_sample=%d", trig_sample));
    void'($value$plusargs("dwell=%d", dwell));
    void'($value$plusargs("probe_mode=%d", probe_mode));
    if (dwell == 0) dwell = 1;
    $fwrite(32'h8000_0002, "[tb_cosim] RLE_EN=%0d seed=%08h trig_sample=%0d dwell=%0d mode=%0d\n",
            RLE_EN, seed, trig_sample, dwell, probe_mode);
  end

  // -- single free-running clock + reset ---------------------------------------------------
  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic rst = 1'b1;
  initial begin
    repeat (10) @(negedge clk);
    rst = 1'b0;
  end

  // -- DUT wiring --------------------------------------------------------------------------
  logic [PROBE_W-1:0] probe = '0;
  logic               trig_ext_i = 1'b0;
  logic               unused_trig_ext_o, unused_uart_tx;
  logic [7:0]         rx_data = '0;
  logic               rx_valid = 1'b0;
  logic               rx_ready;
  logic [7:0]         tx_data;
  logic               tx_valid;
  wire                tx_ready = 1'b1;      // host is always ready to accept bytes
  logic               armed, triggered;
  logic [31:0]        unused_ext_rdata;

  scope_top #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .RLE_EN    (RLE_EN),
      .XPORT     ("STREAM"),
      .ID_VALUE  (IDV)
  ) dut (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .trig_ext_i   (trig_ext_i),
      .trig_ext_o   (unused_trig_ext_o),
      .xclk         (clk),          // single clock: transport domain == capture domain
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
      .ext_csr_rdata(unused_ext_rdata)
  );

  wire unused = &{1'b0, unused_trig_ext_o, unused_uart_tx, triggered, unused_ext_rdata};

  // -- stimulus generator: matches scope_ref.gen_stimulus() for PROBE_W=32 -----------------
  function automatic logic [31:0] xorshift32(input logic [31:0] xin);
    logic [31:0] x;
    x = xin;
    x = x ^ (x << 7);
    x = x ^ (x >> 9);
    x = x ^ (x << 8);
    return x;
  endfunction

  function automatic logic [31:0] gen_stim(input logic [31:0] s, input int unsigned k);
    // chunks=1, c=0:  x = xorshift32((seed + k) ^ 0x9E3779B9)
    return xorshift32((s + 32'(k)) ^ 32'h9E37_79B9);
  endfunction

  // -- probe stimulus, aligned to the armed (FILLING) rise (capture domain) ----------------
  logic        armed_seen = 1'b0;
  int unsigned sidx = 0;
  logic [31:0] free_cnt = 32'd0;          // free-running +1/clk counter probe (probe_mode=1)
  always_ff @(negedge clk) begin
    if (rst) begin
      probe      <= '0;
      trig_ext_i <= 1'b0;
      armed_seen <= 1'b0;
      sidx       <= 0;
      free_cnt   <= 32'd0;
    end else begin
      free_cnt <= free_cnt + 1'b1;
      if (probe_mode == 1) begin
        // free-running counter: decimation/qualification tests want exact, phase-independent
        // spacing between stored samples, so drive a clean +1/clk probe unconditionally.
        probe      <= free_cnt;
        trig_ext_i <= (armed_seen || armed) ? (sidx == trig_sample) : 1'b0;
        if (armed_seen || armed) begin armed_seen <= 1'b1; sidx <= sidx + 1; end
      end else if (armed_seen || armed) begin
        armed_seen <= 1'b1;
        probe      <= gen_stim(seed, sidx / dwell);   // dwell>1 -> runs (exercises RLE counts)
        trig_ext_i <= (sidx == trig_sample);
        sidx       <= sidx + 1;
      end else begin
        probe      <= '0;
        trig_ext_i <= 1'b0;
      end
    end
  end

  // -- rx byte plumbing: host -> DUT (non-blocking, never stalls the clock) -----------------
  logic fin = 1'b0;
  always_ff @(posedge clk) begin
    if (rst) begin
      rx_valid <= 1'b0;
      rx_data  <= 8'h0;
    end else begin
      automatic int b;
      if (rx_valid && rx_ready) rx_valid <= 1'b0;      // byte consumed this cycle
      if (!rx_valid || rx_ready) begin                 // input slot free -> fetch next
        b = cosim_rx_byte();
        if (b == -2) fin <= 1'b1;                       // parent closed the pipe -> finish
        else if (b >= 0) begin
          rx_data  <= b[7:0];
          rx_valid <= 1'b1;
        end
      end
    end
  end

  // -- tx byte plumbing: DUT -> host --------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst && tx_valid && tx_ready) cosim_tx_byte({24'h0, tx_data});
  end

  // -- termination: EOF from the parent, or a generous safety cap ---------------------------
  longint unsigned cycles = 0;
  always_ff @(posedge clk) begin
    cycles <= cycles + 1;
    if (fin) begin
      $fwrite(32'h8000_0002, "[tb_cosim] EOF after %0d cycles\n", cycles);
      $finish;
    end
    if (cycles > 200_000_000) begin
      $fwrite(32'h8000_0002, "[tb_cosim] safety cap hit\n");
      $finish;
    end
  end

endmodule
