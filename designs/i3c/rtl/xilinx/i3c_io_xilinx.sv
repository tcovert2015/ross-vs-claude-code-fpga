// ============================================================================
// i3c_io_xilinx.sv  -  Thin tri-state IO wrapper for AMD/Xilinx 7-series
//
// Same port list and drive semantics as rtl/altera/i3c_io_altera.sv; selected in
// i3c_target_top with  +define+I3C_IO_CELL=i3c_io_xilinx.
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// Why explicit IOBUF / IBUF primitives instead of an inferred tri-state:
//   The Vivado flow for this core is out-of-context (synth_design -mode
//   out_of_context), and OOC synthesis does NOT insert I/O buffers on top-level
//   ports. An inferred `assign SDA = oe ? o : 1'bz` would therefore only become
//   a real pad buffer if a parent design happened to route the port straight to
//   a pin. SDA/SCL are the two ports of this IP that are always device pads, so
//   the buffers are instantiated here and travel with the IP (UG905 "I/O and
//   Clock Buffers": when an OOC port connects directly to an I/O buffer, move
//   the buffer inside the OOC module). The Avalon/clock/reset ports stay
//   buffer-less, as they are on-chip connections.
//
//   IOBUF.T is ACTIVE-HIGH tri-state (T=1 -> Hi-Z), hence T = ~sda_oe.
//   IOSTANDARD / DRIVE / SLEW / pull-ups are left to the XDC of the board.
//
// Simulation: needs the unisim library (xsim: -L unisims_ver + glbl).
// ============================================================================
`ifndef I3C_IO_XILINX_SV
`define I3C_IO_XILINX_SV

module i3c_io_xilinx (
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
  IOBUF u_sda_iobuf (
    .IO (SDA),
    .I  (sda_o),
    .T  (~sda_oe),     // active-high tri-state
    .O  (sda_i)
  );

  // SCL is input only - the Target has no SCL driver (S1).
  IBUF u_scl_ibuf (
    .I (SCL),
    .O (scl_i)
  );

endmodule
`endif
