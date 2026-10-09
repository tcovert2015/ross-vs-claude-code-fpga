// ============================================================================
// i3c_sda_mux.sv  -  Single-owner SDA drive multiplexer (critique fix F-2)
//
// All internal SDA drivers feed this one mux. The architectural contract is that
// at most one source asserts its output-enable at a time; integration formally
// proves $onehot0(src_oe). The mux itself uses defensive lowest-index priority so
// the resolved output is well-defined even if the contract were violated, and
// proves its own resolution correctness in isolation.
// ============================================================================
`ifndef I3C_SDA_MUX_SV
`define I3C_SDA_MUX_SV
`include "i3c_pkg.sv"

module i3c_sda_mux #(
  parameter int unsigned N = i3c_pkg::SDA_NSRC
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] src_oe,   // per-source drive request / output-enable
  input  logic [N-1:0] src_o,    // per-source value to drive when its oe is set
  output logic         sda_oe,   // resolved output-enable to the pad
  output logic         sda_o     // resolved value to the pad
);

  // Defensive lowest-index-wins priority resolution (combinational).
  always_comb begin
    sda_oe = 1'b0;
    sda_o  = 1'b0;
    for (int unsigned i = 0; i < N; i++) begin
      if (src_oe[i] && !sda_oe) begin
        sda_oe = 1'b1;
        sda_o  = src_o[i];
      end
    end
  end

`ifdef FORMAL
  // ---- Unit proofs: resolution correctness (combinational, BMC depth 1) -----
  always_ff @(posedge clk) if (rst_n) begin
    // Output-enable asserted iff some source requests it.
    a_oe_iff_any : assert (sda_oe == (|src_oe));
    // When exactly one source drives, the pad value equals that source's value.
    // For a one-hot src_oe, |(src_oe & src_o) selects the active source's bit.
    // NOTE: immediate assertions use boolean implication (!a || b), never |->.
    a_onehot_val : assert (!$onehot(src_oe) || (sda_oe && (sda_o == (|(src_oe & src_o)))));
    // Never drive a value while released.
    a_z_quiet    : assert (sda_oe || (sda_o == 1'b0));
  end

  // Reachability sanity: a single source can drive a 1 and a 0.
  always_ff @(posedge clk) if (rst_n) begin
    c_drive1 : cover ($onehot(src_oe) &&  sda_o);
    c_drive0 : cover ($onehot(src_oe) && !sda_o && sda_oe);
    c_quiet  : cover (!sda_oe);
  end
`endif

endmodule
`endif
