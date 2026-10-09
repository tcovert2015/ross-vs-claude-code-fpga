// scope_top_fchk — formal property (d) for the drain/servicer FIFO discipline (issue #8).
//
// Instantiated inside scope_top's transport generate scope under `ifdef FORMAL (same
// pattern as scope_core's checker; synthesis and Verilator never see it). Run by
// formal/scope_top.sby single-clock (xclk tied to clk), which keeps the async-FIFO gray
// logic degenerate-but-active and lets one induction cover both domains.
//
// (d) "the drain never pops an empty FIFO", made precise through the one-outstanding-
// request discipline:
//   * the drain only waits on (asserts rsp_rd_ready to) the response FIFO when it has
//     exactly one un-answered command in flight — it can never pop a response it did not
//     request, and the FIFOs can never overflow (occupancy is bounded by the outstanding
//     count, <= 1 <= capacity);
//   * mirrored on the capture side: the servicer answers each popped command exactly once.
module scope_top_fchk (
    input logic clk,
    input logic rst,
    // drain side (transport domain)
    input logic cmd_wr_valid,
    input logic cmd_wr_ready,
    input logic rsp_rd_valid,
    input logic rsp_rd_ready,
    // servicer side (capture domain; same clock in the formal run)
    input logic rsp_wr_valid,
    input logic rsp_wr_ready,
    input logic cmd_rd_valid,
    input logic cmd_rd_ready
);

  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (rst);

  wire cmd_push = cmd_wr_valid && cmd_wr_ready;  // drain issues a command
  wire rsp_pop = rsp_rd_valid && rsp_rd_ready;   // drain consumes its response
  wire cmd_pop = cmd_rd_valid && cmd_rd_ready;   // servicer accepts a command
  wire rsp_push = rsp_wr_valid && rsp_wr_ready;  // servicer answers

  // drain-side outstanding count (commands issued, responses not yet consumed)
  logic [1:0] f_out;
  always @(posedge clk) begin
    if (rst) f_out <= 2'd0;
    else f_out <= f_out + {1'b0, cmd_push} - {1'b0, rsp_pop};
  end

  // servicer-side in-flight count (commands accepted, responses not yet pushed)
  logic [1:0] f_svc;
  always @(posedge clk) begin
    if (rst) f_svc <= 2'd0;
    else f_svc <= f_svc + {1'b0, cmd_pop} - {1'b0, rsp_push};
  end

  always @(*) begin
    if (!rst) begin
      // one-outstanding discipline (drain)
      assert (f_out <= 2'd1);
      if (cmd_push) assert (f_out == 2'd0);
      // (d) the drain never waits on / pops a response it did not request
      if (rsp_rd_ready) assert (f_out == 2'd1);
      if (rsp_pop) assert (f_out == 2'd1);
      // servicer answers exactly the command it accepted
      assert (f_svc <= 2'd1);
      if (cmd_pop) assert (f_svc == 2'd0);
      if (rsp_push) assert (f_svc == 2'd1);
    end
  end

  // reachability: a full command/response round trip happens
  always @(posedge clk) if (!rst) cover (rsp_pop);

endmodule
