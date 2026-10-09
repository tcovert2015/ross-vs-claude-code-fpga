// tb_prim_ram — executable statement of the prim_ram_1r1w read-during-write policy (issue #3).
//
// The whole design (capture buffer, FIFOs) assumes prim_ram_1r1w returns OLD DATA when the
// write and read ports hit the same address in the same cycle (tracker rule 2). This TB:
//   1. fills the memory and reads every location back (basic integrity + 1-cycle latency),
//   2. runs directed + randomized same-cycle write+read collisions and asserts the read
//      returns the PRE-write content, then re-reads and asserts the write landed,
//   3. checks rd_data holds its value while rd_en is low.
// Self-checking: $fatal (prints "TB_RESULT: FAIL") on mismatch; "TB_RESULT: PASS" on success.
`timescale 1ns / 1ps
module tb_prim_ram;

  localparam int unsigned WIDTH = 16;
  localparam int unsigned DEPTH_LOG2 = 6;
  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned N_RDW_TRIALS = 1000;

  logic clk = 1'b0;
  always #5 clk <= ~clk;

  logic                  wr_en;
  logic [DEPTH_LOG2-1:0] wr_addr;
  logic [WIDTH-1:0]      wr_data;
  logic                  rd_en;
  logic [DEPTH_LOG2-1:0] rd_addr;
  logic [WIDTH-1:0]      rd_data;

  prim_ram_1r1w #(
      .WIDTH     (WIDTH),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) dut (
      .clk    (clk),
      .wr_en  (wr_en),
      .wr_addr(wr_addr),
      .wr_data(wr_data),
      .rd_en  (rd_en),
      .rd_addr(rd_addr),
      .rd_data(rd_data)
  );

  // TB-side mirror of the memory contents.
  logic [WIDTH-1:0] model[DEPTH];

  task automatic fail(input string msg);
    $display("TB_RESULT: FAIL");
    $fatal(1, "%s", msg);
  endtask

  initial begin
    wr_en   = 1'b0;
    rd_en   = 1'b0;
    wr_addr = '0;
    rd_addr = '0;
    wr_data = '0;
    @(negedge clk);

    // ---- 1. fill + read-back sweep --------------------------------------------------
    for (int unsigned a = 0; a < DEPTH; a++) begin
      wr_en   = 1'b1;
      wr_addr = DEPTH_LOG2'(a);
      wr_data = WIDTH'(a * 32'h2b01 + 32'h0f0f);  // arbitrary distinct pattern
      model[a] = wr_data;
      @(negedge clk);
    end
    wr_en = 1'b0;

    for (int unsigned a = 0; a < DEPTH; a++) begin
      rd_en   = 1'b1;
      rd_addr = DEPTH_LOG2'(a);
      @(negedge clk);  // read sampled at the posedge inside this cycle
      rd_en = 1'b0;
      @(negedge clk);  // rd_data valid one cycle later
      if (rd_data !== model[a])
        fail($sformatf("read-back addr %0d: got %h want %h", a, rd_data, model[a]));
    end

    // ---- 2. same-cycle write+read collisions: OLD DATA policy -----------------------
    for (int unsigned t = 0; t < N_RDW_TRIALS; t++) begin
      automatic logic [DEPTH_LOG2-1:0] a = DEPTH_LOG2'($urandom());
      automatic logic [WIDTH-1:0] old_v = model[a];
      automatic logic [WIDTH-1:0] new_v = WIDTH'($urandom());
      // collision cycle: write new_v to a while reading a
      wr_en   = 1'b1;
      wr_addr = a;
      wr_data = new_v;
      rd_en   = 1'b1;
      rd_addr = a;
      model[a] = new_v;
      @(negedge clk);
      wr_en = 1'b0;
      rd_en = 1'b0;
      @(negedge clk);
      if (rd_data !== old_v)
        fail($sformatf("RDW trial %0d addr %0d: got %h, want OLD data %h (new was %h)",
                       t, a, rd_data, old_v, new_v));
      // re-read: the write must have landed
      rd_en   = 1'b1;
      rd_addr = a;
      @(negedge clk);
      rd_en = 1'b0;
      @(negedge clk);
      if (rd_data !== new_v)
        fail($sformatf("RDW trial %0d addr %0d: post-collision read got %h want %h",
                       t, a, rd_data, new_v));
    end

    // ---- 3. rd_data holds while rd_en is low -----------------------------------------
    begin
      automatic logic [WIDTH-1:0] held = rd_data;
      wr_en   = 1'b1;               // keep writing elsewhere; output must not move
      wr_addr = '0;
      wr_data = 16'hdead;
      model[0] = 16'hdead;
      repeat (5) begin
        @(negedge clk);
        if (rd_data !== held) fail("rd_data changed while rd_en was low");
      end
      wr_en = 1'b0;
    end

    $display("TB_RESULT: PASS");
    $finish;
  end

  // watchdog
  initial begin
    #10ms;
    fail("timeout");
  end

endmodule
