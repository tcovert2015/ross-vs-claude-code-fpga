// ============================================================================
// i3c_io_lattice.sv  -  Thin tri-state IO wrapper for Lattice Nexus devices
//                       (Certus-NX / CrossLink-NX / CertusPro-NX / MachXO5-NX)
//
// Drop-in equivalent of rtl/altera/i3c_io_altera.sv: identical port list and
// drive semantics. Selected by compiling with
//   +define+I3C_IO_MODULE=i3c_io_lattice
// (see the `I3C_IO_MODULE hook in i3c_target_top.sv).
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// Why an inferred tri-state rather than explicit BB/IB primitives:
//   * Synplify Pro (and LSE) map `assign pad = oe ? o : 1'bz` on a top-level
//     inout straight onto the Nexus bidirectional pad buffer `BB` (I=sda_o,
//     T=~sda_oe, O=sda_i) and the SCL input onto `IB`. The Radiant build confirms
//     this: the synthesis resource report lists exactly one BB (see
//     syn/lattice/README.md), so the primitive buys nothing in QoR.
//   * The file stays plain SystemVerilog: it simulates in Questa/Icarus with no
//     Lattice simulation library (lfd2nx) compiled, and has no GSR/PUR hookup.
//   * I3C needs BOTH open-drain and push-pull on the same pad, switched at run
//     time by the core. That is exactly this 3-state model; do NOT set the pad's
//     OPENDRAIN=ON attribute (it would break push-pull High).
// Pad electricals (IO_TYPE, e.g. LVCMOS18/LVCMOS12, PULLMODE=NONE because the bus
// has its own pull-up / high-keeper, SLEWRATE, DRIVE) belong in the .pdc via
// ldc_set_port, not in RTL. To force the primitive anyway, replace the two SDA
// assigns with:
//   BB u_sda (.B(SDA), .I(sda_o), .T(~sda_oe), .O(sda_i));
//   IB u_scl (.I(SCL), .O(scl_i));
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
