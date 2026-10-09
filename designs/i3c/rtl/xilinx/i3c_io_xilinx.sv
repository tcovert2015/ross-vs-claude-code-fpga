// ============================================================================
// i3c_io_xilinx.sv  -  Thin tri-state IO wrapper for AMD/Xilinx 7-series
//
// Drop-in equivalent of rtl/altera/i3c_io_altera.sv: same port list, same drive
// semantics. Selected in i3c_target_top with `+define+I3C_IO_MODULE=i3c_io_xilinx`.
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// Why an explicit IOBUF instead of an inferred tri-state
// (`assign SDA = sda_oe ? sda_o : 1'bz`):
//   The IP is built out-of-context (synth_design -mode out_of_context), where
//   Vivado does NOT insert I/O buffers. An inferred tri-state therefore has no
//   pad buffer to map onto and is left as a floating-driver net on the module
//   boundary, whose fate depends on how the parent is later synthesized. SDA is
//   a real device pad in every deployment of this core, so the bidirectional
//   buffer belongs to the shim: instantiating the 7-series IOBUF primitive makes
//   the open-drain-capable 3-state driver explicit and identical in OOC and
//   in-context builds, and gives one place to hang pad attributes (IOSTANDARD,
//   DRIVE, SLEW, PULLUP) from the board XDC. IOBUF.T is active-HIGH tri-state,
//   hence T = ~sda_oe.
//
//   SCL deliberately gets no instantiated IBUF: it is a plain input, and leaving
//   it as a wire lets the integrator choose IBUF vs. an already-buffered net.
//
// Simulation needs the UNISIM library (xelab -L unisims_ver ... glbl).
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
    .T  (~sda_oe),   // IOBUF T is active-high tri-state
    .O  (sda_i)
  );

  // SCL is input only - the Target has no SCL driver (S1).
  assign scl_i = SCL;

endmodule
`endif
