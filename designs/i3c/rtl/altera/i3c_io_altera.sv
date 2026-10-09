// ============================================================================
// i3c_io_altera.sv  -  Thin tri-state IO wrapper (the ONLY vendor-specific RTL)
//
// Maps the device-agnostic open-drain/push-pull drive model onto physical pads.
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// This implementation uses an inferred tri-state, which Quartus maps to the SDA
// pad's true bidirectional buffer. To force a specific primitive, replace the
// `assign SDA = ...` line with an ALTIOBUF / `tri` IP instantiation; the port
// list and semantics are unchanged.
// ============================================================================
`ifndef I3C_IO_ALTERA_SV
`define I3C_IO_ALTERA_SV

module i3c_io_altera (
  // device-agnostic core side
  input  logic sda_oe,   // 1 = drive, 0 = release
  input  logic sda_o,    // value to drive when sda_oe=1
  output logic sda_i,    // sampled SDA
  output logic scl_i,    // sampled SCL
  // physical pads
  inout  wire  SDA,
  input  wire  SCL
);

  // Bidirectional SDA: drive when enabled, else high-Z (pull-up resolves High).
  assign SDA   = sda_oe ? sda_o : 1'bz;
  assign sda_i = SDA;

  // SCL is input only - the Target has no SCL driver (S1).
  assign scl_i = SCL;

endmodule
`endif
