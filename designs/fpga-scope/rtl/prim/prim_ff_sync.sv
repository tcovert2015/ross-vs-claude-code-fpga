// prim_ff_sync — N-stage flip-flop synchronizer (vendored fpgapa-prim primitive).
//
// What it is: a STAGES-deep (default 2) register chain that brings a signal from another
// clock domain into `clk`. `q` follows `d` after STAGES clk edges (plus metastability
// settling in the first stage). Pure synchronizer: no handshake, no feedback, no pulse
// stretching.
//
// Contract / safe uses ONLY:
//   (a) single-bit levels or quasi-static flags (stable for >> STAGES destination cycles), or
//   (b) multi-bit GRAY-CODED values where at most one bit changes per source-clock edge
//       (async-FIFO pointers — see prim_fifo_async).
//   NEVER use it on a multi-bit binary bus that can change arbitrarily per cycle: the bits
//   would tear (each bit resolves independently).
//
// Policy decisions:
//   * ASYNC_RST=0 (default): synchronous active-high reset. ASYNC_RST=1: asynchronous-assert
//     active-high reset (use when the destination clock may not be running at reset time,
//     e.g. reset-distribution synchronizers).
//   * RESET_VAL parameterizes the reset state (e.g. '1 for active-low signals so the
//     synchronized copy does not glitch-assert out of reset).
//   * No vendor primitives / attributes. Constrain the CDC in your flow by matching this
//     module name (set_false_path / set_max_delay onto prim_ff_sync first-stage registers).
module prim_ff_sync #(
    parameter int unsigned      WIDTH     = 1,
    parameter int unsigned      STAGES    = 2,      // >= 1
    parameter bit               ASYNC_RST = 1'b0,
    parameter logic [WIDTH-1:0] RESET_VAL = '0
) (
    input  logic             clk,   // destination domain
    input  logic             rst,   // active high (sync or async per ASYNC_RST)
    input  logic [WIDTH-1:0] d,     // source-domain signal (see contract above)
    output logic [WIDTH-1:0] q      // synchronized copy, STAGES clk edges later
);

  // Stage 0 (bits [WIDTH-1:0]) is the metastability boundary. Flat vector rather than a 2D
  // packed array: the yosys formal flow (0.33 baseline) cannot parse multiple packed dims.
  logic [STAGES*WIDTH-1:0] sync_q;

  if (ASYNC_RST) begin : g_arst
    always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
        sync_q <= {STAGES{RESET_VAL}};
      end else begin
        sync_q[0+:WIDTH] <= d;
        for (int unsigned i = 1; i < STAGES; i++) sync_q[i*WIDTH+:WIDTH] <= sync_q[(i-1)*WIDTH+:WIDTH];
      end
    end
  end else begin : g_srst
    always_ff @(posedge clk) begin
      if (rst) begin
        sync_q <= {STAGES{RESET_VAL}};
      end else begin
        sync_q[0+:WIDTH] <= d;
        for (int unsigned i = 1; i < STAGES; i++) sync_q[i*WIDTH+:WIDTH] <= sync_q[(i-1)*WIDTH+:WIDTH];
      end
    end
  end

  assign q = sync_q[(STAGES-1)*WIDTH+:WIDTH];

endmodule
