// ============================================================================
// i3c_io_lattice.sv  -  Thin tri-state IO wrapper for Lattice Nexus devices
//                       (Certus-NX / CrossLink-NX / CertusPro-NX / MachXO5-NX)
//
// Drop-in counterpart of rtl/altera/i3c_io_altera.sv: identical port list and
// identical drive semantics. Selected at build time with
//   +define+I3C_IO_SHIM=i3c_io_lattice      (see i3c_target_top.sv)
//
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// Why an INFERRED tri-state rather than explicit BB / IB primitives:
//   * Synplify Pro maps a top-level `assign pad = oe ? o : 1'bz` on an inout
//     port to the Nexus bidirectional buffer BB (I=sda_o, T=~sda_oe, O=sda_i)
//     and a plain input port to IB, so the netlist is the same as a
//     hand-instantiated one. The build confirms this: see the cell usage in
//     syn/lattice/reports/i3c_target_impl_1.srr and the IO section of the
//     map report (.mrp) next to it.
//   * It keeps this file plain SystemVerilog: it simulates in Icarus, Questa
//     and the formal flow without the Lattice primitive libraries (an explicit
//     BB would pull the Nexus simulation library and a GSR instance into every
//     testbench).
//   * Pad electricals (IO_TYPE, OPENDRAIN, PULLMODE, SLEWRATE, DRIVE) are set
//     where they belong for Nexus, on the port in the .pdc
//     (ldc_set_port -iobuf {...} [get_ports SDA]), not in RTL.
//   To force the primitive anyway, replace the SDA/SCL assigns with
//     BB u_sda (.I(sda_o), .T(~sda_oe), .O(sda_i), .B(SDA));
//     IB u_scl (.I(SCL), .O(scl_i));
//   The port list and semantics are unchanged.
//
// Note: I3C needs BOTH open-drain and push-pull drive on the same pad, so the
// pad must NOT be configured OPENDRAIN=ON; open-drain phases are produced by
// the core only ever asserting sda_oe with sda_o=0 in those phases.
// ============================================================================
`ifndef I3C_IO_LATTICE_SV
`define I3C_IO_LATTICE_SV

module i3c_io_lattice (
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
