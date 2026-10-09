module demo (input logic clk, input logic rstn, output logic [3:0] cnt);
  always_ff @(posedge clk)
    if (!rstn)            cnt <= 4'd0;
    else if (cnt == 4'd9) cnt <= 4'd0;
    else                  cnt <= cnt + 4'd1;
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rstn);                         // bus/device starts in reset
  always_ff @(posedge clk) begin
    if (f_past_valid) a_bound: assert (cnt <= 4'd9);
    c_wrap: cover (f_past_valid && $past(cnt)==4'd9 && cnt==4'd0);
  end
`endif
endmodule
