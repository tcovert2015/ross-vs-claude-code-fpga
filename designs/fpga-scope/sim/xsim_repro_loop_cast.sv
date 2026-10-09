// xsim_repro_loop_cast — standalone reproducer for the two xsim 2025.2 defects that made the
// original sim/tb_csr.sv STATUS poll loops misbehave (see fpga/xilinx/README.md). Not a
// testbench of this design and not part of any regression; kept so the claim is checkable.
//
//   xvlog --sv sim/xsim_repro_loop_cast.sv && xelab -s repro work.xsim_repro_loop_cast && xsim repro --runall
//
// Expected (IEEE 1800) results are printed next to what the simulator computed.
`timescale 1ns / 1ps
package repro_pkg;
  typedef enum logic [2:0] {S0 = 3'd0, S2 = 3'd2, S4 = 3'd4} st_e;
endpackage

module xsim_repro_loop_cast
  import repro_pkg::*;
;
  logic clk = 1'b0;
  always #5 clk <= ~clk;
  logic [31:0] cnt = '0;
  always @(posedge clk) cnt <= cnt + 1;

  task automatic rd(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk);
    d = cnt + 32'(a);
  endtask

  logic [31:0] v;
  int n;

  initial begin
    // ---- 1: size-cast enum constant in a loop condition --------------------------------
    v = 32'h22;  // v[2:0] = 2, so (v[2:0] != S4) is TRUE
    if (v[2:0] != 3'(S4)) $display("1a if      (v[2:0] != 3'(S4)) : taken      (expect taken)");
    else                  $display("1a if      (v[2:0] != 3'(S4)) : NOT taken  (expect taken)");
    n = 0; while (v[2:0] != 3'(S4)) begin n++; if (n == 3) break; end
    $display("1b while   (v[2:0] != 3'(S4)) : %0d iterations (expect 3)", n);
    n = 0; do begin n++; if (n == 3) break; end while (v[2:0] != 3'(S4));
    $display("1c do-while(v[2:0] != 3'(S4)) : %0d iterations (expect 3)", n);
    n = 0; do begin n++; if (n == 3) break; end while (v[2:0] != S4);
    $display("1d do-while(v[2:0] != S4)     : %0d iterations (expect 3)", n);

    // ---- 2: bare task-call loop body with a cast argument: output copy-out ---------------
    v = 'x;
    do rd(8'(0), v); while (v[3:1] != 3'd4);
    $display("2a do rd(8'(0), v); while(..)           : v=%0d (expect a number with bits[3:1]==4)", v);
    v = 'x;
    do begin rd(8'(0), v); end while (v[3:1] != 3'd4);
    $display("2b do begin rd(8'(0), v); end while(..) : v=%0d (expect a number with bits[3:1]==4)", v);
    $finish;
  end

  initial begin
    #100000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
