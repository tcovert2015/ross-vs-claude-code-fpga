// prim_fifo_sync — single-clock FIFO, first-word-fall-through (vendored fpgapa-prim primitive).
//
// What it is: a 2^DEPTH_LOG2-entry FIFO with valid/ready handshakes on both sides. Storage is
// prim_ram_1r1w (block RAM); the RAM's 1-cycle read latency is hidden behind a prefetched
// output stage, so the interface is FWFT: `rd_data` is valid whenever `rd_valid` is high.
//
// Contract:
//   * Handshake rule: a transfer happens on the cycle where both valid and ready are high;
//     `wr_ready`/`rd_valid` never depend combinationally on the opposite-side handshake input.
//   * Capacity is exactly 2^DEPTH_LOG2 items (the FWFT output register is counted as part of
//     the capacity; the RAM keeps one slot spare while the output stage is occupied).
//   * `wr_ready` is low exactly when the FIFO holds 2^DEPTH_LOG2 items. `rd_valid` is low
//     exactly when the FIFO is empty, except for a <= 2-cycle prefetch delay after a push
//     into an empty FIFO (FWFT fill latency; data is never lost or reordered).
//   * `rd_data` is stable while `rd_valid && !rd_ready` (no data changes under a stalled
//     consumer). Full throughput: 1 transfer/cycle when neither side stalls.
//   * Synchronous active-high reset; contents are discarded on reset.
//
// Policy decisions: always prim_ram_1r1w storage (no flop-array special case — keep one
// inference path); the RAM's "old data" read-during-write policy is never exercised because
// the pointer discipline forbids same-address write+read with live data. No vendor primitives.
module prim_fifo_sync #(
    parameter int unsigned WIDTH      = 8,
    parameter int unsigned DEPTH_LOG2 = 4
) (
    input  logic             clk,
    input  logic             rst,       // synchronous, active high

    input  logic [WIDTH-1:0] wr_data,
    input  logic             wr_valid,
    output logic             wr_ready,  // low exactly when full

    output logic [WIDTH-1:0] rd_data,   // FWFT: valid whenever rd_valid
    output logic             rd_valid,  // low when empty (see prefetch note above)
    input  logic             rd_ready
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned CNT_W = DEPTH_LOG2 + 1;

  logic [DEPTH_LOG2-1:0] waddr, raddr;
  logic [CNT_W-1:0]      cnt;      // total items held (RAM + output stage), 0..DEPTH
  logic [CNT_W-1:0]      ram_cnt;  // items in RAM only
  logic                  out_vld;  // output stage (RAM rd_data register) holds a live item

  wire push = wr_valid && wr_ready;
  wire pop  = rd_valid && rd_ready;
  // Prefetch: move the oldest RAM item into the output stage whenever RAM has data and the
  // output stage is empty or being popped this cycle. rd_data (the RAM output register) only
  // changes on rd_issue, which preserves FWFT stability under a stalled consumer.
  wire rd_issue = (ram_cnt != '0) && (!out_vld || pop);

  assign wr_ready = (cnt != CNT_W'(DEPTH));
  assign rd_valid = out_vld;

  always_ff @(posedge clk) begin
    if (rst) begin
      waddr   <= '0;
      raddr   <= '0;
      cnt     <= '0;
      ram_cnt <= '0;
      out_vld <= 1'b0;
    end else begin
      if (push)     waddr <= waddr + 1'b1;
      if (rd_issue) begin
        raddr   <= raddr + 1'b1;
        out_vld <= 1'b1;
      end else if (pop) begin
        out_vld <= 1'b0;
      end
      cnt     <= cnt     + CNT_W'(push) - CNT_W'(pop);
      ram_cnt <= ram_cnt + CNT_W'(push) - CNT_W'(rd_issue);
    end
  end

  prim_ram_1r1w #(
      .WIDTH     (WIDTH),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_ram (
      .clk    (clk),
      .wr_en  (push),
      .wr_addr(waddr),
      .wr_data(wr_data),
      .rd_en  (rd_issue),
      .rd_addr(raddr),
      .rd_data(rd_data)
  );

endmodule
