// tb_prim_fifo_sync — fill/drain, boundary push+pop, randomized soak with scoreboard (issue #3).
//
// Checks on prim_fifo_sync (WIDTH=16, DEPTH_LOG2=4 => capacity exactly 16):
//   * scoreboard: every popped word equals the oldest un-popped pushed word (no drop, dup,
//     reorder, or corruption) across a 20k-transfer randomized soak (random wr_valid gaps,
//     random rd_ready back-pressure);
//   * full flag exact: wr_ready == (occupancy < DEPTH) checked EVERY cycle (the DUT's counter
//     and the TB's model update on the same handshake edges);
//   * empty flag: rd_valid == 1 implies occupancy > 0 checked every cycle; rd_valid settles
//     low after drain-to-empty (FWFT prefetch allows a bounded fill delay, never a phantom);
//   * directed fill-to-full then drain-to-empty; simultaneous push+pop at the full and empty
//     boundaries; FWFT stability (rd_data frozen while rd_valid && !rd_ready).
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps
module tb_prim_fifo_sync;

  localparam int unsigned WIDTH = 16;
  localparam int unsigned DEPTH_LOG2 = 4;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned N_SOAK = 20000;

  logic clk = 1'b0;
  always #5 clk <= ~clk;

  logic             rst = 1'b1;
  logic [WIDTH-1:0] wr_data;
  logic             wr_valid = 1'b0;
  logic             wr_ready;
  logic [WIDTH-1:0] rd_data;
  logic             rd_valid;
  logic             rd_ready = 1'b0;

  prim_fifo_sync #(
      .WIDTH     (WIDTH),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) dut (
      .clk     (clk),
      .rst     (rst),
      .wr_data (wr_data),
      .wr_valid(wr_valid),
      .wr_ready(wr_ready),
      .rd_data (rd_data),
      .rd_valid(rd_valid),
      .rd_ready(rd_ready)
  );

  // ---- scoreboard + drive knobs -----------------------------------------------------
  logic [WIDTH-1:0] sb[$];
  int unsigned pushed = 0, popped = 0;
  int unsigned push_pct = 0;  // % chance to present a word when idle
  int unsigned pop_pct = 0;   // % chance rd_ready is high each cycle
  logic [WIDTH-1:0] pat = 16'h1d0b;  // simple counting-ish pattern seed

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", msg);
  endtask

  // write driver: present wr_valid probabilistically; hold word until accepted.
  always @(posedge clk) begin
    if (rst) begin
      wr_valid <= 1'b0;
    end else begin
      if (wr_valid && wr_ready) begin
        sb.push_back(wr_data);
        pushed <= pushed + 1;
      end
      if (!wr_valid || wr_ready) begin  // free to (re)decide
        if ($urandom_range(99) < push_pct) begin
          wr_valid <= 1'b1;
          wr_data  <= pat;
          pat      <= pat * 16'h4e35 + 16'h0007;  // LCG-style pattern step
        end else begin
          wr_valid <= 1'b0;
        end
      end
    end
  end

  // read driver + compare
  always @(posedge clk) begin
    if (rst) begin
      rd_ready <= 1'b0;
    end else begin
      if (rd_valid && rd_ready) begin
        if (sb.size() == 0) fail("pop with empty scoreboard (duplicate/phantom data)");
        else begin
          automatic logic [WIDTH-1:0] exp = sb.pop_front();
          if (rd_data !== exp)
            fail($sformatf("data mismatch: got %h want %h (pop #%0d)", rd_data, exp, popped));
          popped <= popped + 1;
        end
      end
      rd_ready <= ($urandom_range(99) < pop_pct);
    end
  end

  // continuous flag checks (values are settled at negedge)
  always @(negedge clk) begin
    if (!rst) begin
      automatic int unsigned occ = pushed - popped;
      if (occ > DEPTH) fail($sformatf("occupancy %0d exceeds capacity %0d", occ, DEPTH));
      if (wr_ready !== (occ < DEPTH))
        fail($sformatf("full flag not exact: occ=%0d wr_ready=%b", occ, wr_ready));
      if (rd_valid && occ == 0) fail("rd_valid asserted while model empty");
    end
  end

  // FWFT stability: rd_data must not move while rd_valid && !rd_ready
  logic [WIDTH-1:0] stall_data;
  logic             stall_armed = 1'b0;
  always @(posedge clk) begin
    if (rst) stall_armed <= 1'b0;
    else if (rd_valid && !rd_ready) begin
      if (stall_armed && rd_data !== stall_data)
        fail("rd_data changed while stalled (FWFT stability violated)");
      stall_data  <= rd_data;
      stall_armed <= 1'b1;
    end else begin
      stall_armed <= 1'b0;
    end
  end

  task automatic wait_occ(input int unsigned want);
    while (pushed - popped != want) @(negedge clk);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // ---- phase 1: randomized soak (random gaps + back-pressure) ----------------------
    push_pct = 70;
    pop_pct  = 60;
    while (popped < N_SOAK) @(negedge clk);

    // ---- phase 2: fill to full --------------------------------------------------------
    push_pct = 100;
    pop_pct  = 0;
    wait_occ(DEPTH);
    repeat (10) begin
      @(negedge clk);
      if (wr_ready !== 1'b0) fail("wr_ready high at full");
      if (pushed - popped != DEPTH) fail("occupancy moved while full and read frozen");
    end

    // ---- phase 3: simultaneous push+pop at the full boundary --------------------------
    // popping at full frees one slot per pop; pushes continue: occupancy must ride the
    // DEPTH-1/DEPTH boundary without overflow (continuous checks above enforce exactness).
    pop_pct = 100;
    repeat (50) @(negedge clk);

    // ---- phase 4: drain to empty -------------------------------------------------------
    push_pct = 0;
    wait_occ(0);
    repeat (5) @(negedge clk);  // let FWFT pipeline settle
    if (rd_valid !== 1'b0) fail("rd_valid high after drain-to-empty");
    if (sb.size() != 0) fail("scoreboard not empty after drain (dropped words)");

    // ---- phase 5: push+pop at the empty boundary ---------------------------------------
    // single-word trickle with an always-ready consumer: each word falls through and is
    // popped as soon as rd_valid rises.
    pop_pct  = 100;
    push_pct = 25;
    begin
      automatic int unsigned start_popped = popped;
      while (popped - start_popped < 200) @(negedge clk);
    end

    // ---- wrap up ----------------------------------------------------------------------
    push_pct = 0;
    wait_occ(0);
    repeat (5) @(negedge clk);
    if (pushed != popped) fail($sformatf("pushed %0d != popped %0d", pushed, popped));
    $display("-- %0d transfers, final occupancy 0", popped);
    $display("TB_RESULT: PASS");
    $finish;
  end

  // watchdog
  initial begin
    #50ms;
    fail("timeout");
  end

endmodule
