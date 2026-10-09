// tb_smoke — trivial self-checking testbench proving the sim harness + CI plumbing (issue #2).
//
// Contract (same as every TB in this repo, tracker rule 8): failure -> $fatal, which prints
// "TB_RESULT: FAIL" and exits non-zero; success -> prints "TB_RESULT: PASS" then $finish.
// This TB just runs a free-running counter for ~100 cycles and checks it increments by
// exactly 1 each cycle. Its only job is to prove `bash sim/run.sh` and GitHub Actions work
// end-to-end before any real RTL lands.
`timescale 1ns/1ps
module tb_smoke;

  logic clk = 1'b0;
  always #5 clk <= ~clk;           // 100 MHz

  logic [31:0] cnt = 32'd0;
  logic [31:0] cnt_d = 32'd0;
  int          cycles = 0;

  always_ff @(posedge clk) begin
    cnt    <= cnt + 32'd1;
    cnt_d  <= cnt;
    cycles <= cycles + 1;
    if (cycles > 1 && cnt != cnt_d + 32'd1) begin
      $display("TB_RESULT: FAIL");
      $fatal(1, "counter did not increment: cnt=%0d cnt_d=%0d", cnt, cnt_d);
    end
    if (cycles == 100) begin
      $display("TB_RESULT: PASS");
      $finish;
    end
  end

endmodule
