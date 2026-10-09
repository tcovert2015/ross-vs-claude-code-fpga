// prim_fifo_async — dual-clock FIFO, gray-coded pointers, FWFT (vendored fpgapa-prim primitive).
//
// What it is: the classic Cummings (SNUG) asynchronous FIFO. Binary write/read pointers are
// gray-encoded, crossed into the opposite domain through prim_ff_sync, and full/empty are
// derived from the synchronized opposite-domain pointer. Same valid/ready port contract as
// prim_fifo_sync, plus separate wclk/wrst and rclk/rrst. This module and prim_ff_sync are the
// ONLY CDC logic allowed in the design (tracker rule 7).
//
// Contract:
//   * Handshake rule as prim_fifo_sync. `wr_ready` is the write-domain view of not-full
//     (pessimistic while the read pointer is in flight through the synchronizer: it may hold
//     low up to 2×SYNC_STAGES cycles longer than strictly necessary, never overflows).
//     `rd_valid` is the read-domain view of not-empty (pessimistic likewise: a pushed word
//     appears after the gray pointer crosses, ~SYNC_STAGES+2 rclk; never underflows, never
//     reorders, never drops or duplicates).
//   * Usable capacity is 2^DEPTH_LOG2 + 1 items (RAM plus the FWFT output stage).
//   * `rd_data` is stable while `rd_valid && !rd_ready`.
//   * RESET: assert wrst and rrst together (overlapping), each held >= SYNC_STAGES+2 cycles
//     of its own clock, before first use. While its reset is asserted a side is inert
//     (`wr_ready` low / `rd_valid` low), so nothing crosses during reset. Releasing the two
//     resets at different times after the overlap is fine.
//
// Policy decisions:
//   * Storage is a flop/LUTRAM array with a combinational read mux into an rclk output
//     register — NOT prim_ram_1r1w (which is single-clock). Safe because a slot's content is
//     stable >= SYNC_STAGES rclk before the read side can see its pointer, and is never
//     rewritten until the read pointer passes it. Intended for shallow CDC crossings (the
//     scope's CSR/drain FIFOs), not deep capture buffers.
//   * No almost-full/almost-empty, no fill counts — keep the vendorable surface minimal.
//   * Full detection: wgray_next == (synchronized rgray with top two bits inverted); empty
//     detection: rgray_next == synchronized wgray. Both registered (Cummings ¶ style).
module prim_fifo_async #(
    parameter int unsigned WIDTH       = 8,
    parameter int unsigned DEPTH_LOG2  = 4,
    parameter int unsigned SYNC_STAGES = 2
) (
    // write domain
    input  logic             wclk,
    input  logic             wrst,      // synchronous to wclk, active high
    input  logic [WIDTH-1:0] wr_data,
    input  logic             wr_valid,
    output logic             wr_ready,  // low when full (write-domain view)

    // read domain
    input  logic             rclk,
    input  logic             rrst,      // synchronous to rclk, active high
    output logic [WIDTH-1:0] rd_data,   // FWFT
    output logic             rd_valid,  // low when empty (read-domain view)
    input  logic             rd_ready
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned PTR_W = DEPTH_LOG2 + 1;
  // XOR mask inverting the top two gray bits: full = wgray_next == (rgray ^ TOP2_MASK).
  localparam logic [PTR_W-1:0] TOP2_MASK = PTR_W'(3 << (PTR_W - 2));

  logic [WIDTH-1:0] mem[DEPTH];  // written in wclk domain only; slots are quasi-static
                                 // by the time the read domain's pointer reaches them

  // ---------------- write domain ----------------
  logic [PTR_W-1:0] wbin, wgray;
  logic [PTR_W-1:0] wq_rgray;  // read pointer (gray) synchronized into wclk
  logic             wfull;

  wire              push = wr_valid && wr_ready;
  wire [PTR_W-1:0] wbin_next = wbin + PTR_W'(push);
  wire [PTR_W-1:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

  always_ff @(posedge wclk) begin
    if (wrst) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b1;  // inert (wr_ready low) during reset; recomputed 1 cycle after release
    end else begin
      wbin  <= wbin_next;
      wgray <= wgray_next;
      wfull <= (wgray_next == (wq_rgray ^ TOP2_MASK));
    end
  end

  assign wr_ready = !wfull;

  always_ff @(posedge wclk) begin
    if (push) mem[wbin[DEPTH_LOG2-1:0]] <= wr_data;
  end

  // ---------------- read domain ----------------
  logic [PTR_W-1:0] rbin, rgray;
  logic [PTR_W-1:0] rq_wgray;   // write pointer (gray) synchronized into rclk
  logic             ram_empty;
  logic             out_vld;    // FWFT output register holds a live item

  wire              pop = rd_valid && rd_ready;
  // Prefetch into the output register whenever the RAM ring is non-empty and the output
  // register is empty or being popped (same discipline as prim_fifo_sync).
  wire              rd_issue = !ram_empty && (!out_vld || pop);
  wire [PTR_W-1:0] rbin_next = rbin + PTR_W'(rd_issue);
  wire [PTR_W-1:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

  always_ff @(posedge rclk) begin
    if (rrst) begin
      rbin      <= '0;
      rgray     <= '0;
      ram_empty <= 1'b1;
      out_vld   <= 1'b0;
    end else begin
      rbin      <= rbin_next;
      rgray     <= rgray_next;
      // Compares against the CURRENT synchronized wgray (pre-edge value): pessimistic, safe.
      ram_empty <= (rgray_next == rq_wgray);
      if (rd_issue) begin
        rd_data <= mem[rbin[DEPTH_LOG2-1:0]];
        out_vld <= 1'b1;
      end else if (pop) begin
        out_vld <= 1'b0;
      end
    end
  end

  assign rd_valid = out_vld;

  // ---------------- pointer CDC ----------------
  // Gray-coded pointers change at most one bit per source edge — the documented safe
  // multi-bit use of prim_ff_sync.
  prim_ff_sync #(
      .WIDTH (PTR_W),
      .STAGES(SYNC_STAGES)
  ) u_sync_rgray_to_w (
      .clk(wclk),
      .rst(wrst),
      .d  (rgray),
      .q  (wq_rgray)
  );

  prim_ff_sync #(
      .WIDTH (PTR_W),
      .STAGES(SYNC_STAGES)
  ) u_sync_wgray_to_r (
      .clk(rclk),
      .rst(rrst),
      .d  (wgray),
      .q  (rq_wgray)
  );

endmodule
