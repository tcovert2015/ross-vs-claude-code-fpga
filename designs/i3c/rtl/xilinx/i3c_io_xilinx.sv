// ============================================================================
// i3c_io_xilinx.sv  -  Thin tri-state IO wrapper for AMD/Xilinx 7-series
//
// Drop-in equivalent of rtl/altera/i3c_io_altera.sv: same port list, same drive
// semantics. Select it in i3c_target_top with +define+I3C_IO_CELL=i3c_io_xilinx.
//   - SDA is bidirectional: drive Low / drive High (push-pull) / release (Hi-Z).
//   - SCL is INPUT ONLY: the Target never drives SCL (S1 / R-DRV-02/03).
//
// Drive model (docs/design_decisions.md §3):
//   sda_oe=1, sda_o=0 -> drive Low   (ACK / open-drain 0)
//   sda_oe=1, sda_o=1 -> drive High  (push-pull 1; only in push-pull phases)
//   sda_oe=0          -> release to Hi-Z (external pull-up / bus high-keeper -> 1)
//
// Why instantiated IOBUF/IBUF primitives rather than an inferred tri-state:
//   * The core is built out-of-context (syn/xilinx/build.tcl, -mode
//     out_of_context). OOC synthesis inserts no pad buffers, and with no pad
//     buffer to absorb it Vivado does NOT keep an inferred `1'bz` driver: it
//     rewrites it to plain logic (CRITICAL WARNING Synth 8-5799 "Converted
//     tricell instance to logic"). The resulting netlist drives
//     SDA = sda_oe & sda_o permanently and feeds that same net back into the
//     SDA synchronizer, i.e. the Target can neither release the bus nor see the
//     Controller. Evidence from that trial build is kept in
//     syn/xilinx/reports/trial_inferred_tristate/.
//   * Instantiated primitives survive OOC synthesis untouched, so the real
//     3-state pad cell (OBUFT + IBUF) is in the checkpoint, and they are equally
//     correct when this module is synthesized in-context as the device top
//     (Vivado does not add a second buffer to a port that already has one).
//   * SDA and SCL are true device pads (unlike the Avalon-MM ports, which are an
//     on-chip boundary), so the pad cells belong to the IP. SCL gets an IBUF so
//     that both bus pins are treated the same way; a parent that black-boxes
//     the OOC netlist must mark SDA/SCL as pad pins (black_box_pad_pin, or
//     IO_BUFFER_TYPE=none on its own ports) so it does not buffer them twice.
//   * IOBUF.T is active-high "tri-state", hence T = ~sda_oe.
// IOSTANDARD / SLEW / DRIVE / PULLUP are board decisions and belong in the
// board XDC (set_property ... [get_ports SDA]), not here.
// Simulation needs the unisims_ver library and glbl (see sim/run_xsim.ps1).
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
    .T  (~sda_oe),   // T=1 -> output buffer off
    .O  (sda_i)
  );

  // SCL is input only - the Target has no SCL driver (S1).
  IBUF u_scl_ibuf (
    .I (SCL),
    .O (scl_i)
  );

endmodule
`endif
