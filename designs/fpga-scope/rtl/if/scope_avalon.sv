// scope_avalon — Avalon-MM slave front-end for the scope's native CSR bus (issue #11).
//
// A THIN protocol adapter: zero scope logic. The native CSR bus (scope_csr) is word-addressed
// with a COMBINATIONAL read (`csr_rdata` valid the same cycle `csr_addr` is presented) and no
// wait states, so this front-end is a combinational rename with `waitrequest` tied low:
//
//   * word-addressed: Avalon `address` IS the CSR word index (register k at host byte 4*k),
//     the same convention as the hyperram bench CSR slave. No byte-address shifting here.
//   * fixed-latency-0 read: `readdata` is combinationally `csr_rdata`. A master drives `read`
//     for exactly one cycle (waitrequest low ⇒ the transfer completes immediately), so the
//     native `csr_read` strobe is high for exactly one cycle — the BUF_DATA pop-on-read side
//     effect fires exactly once per Avalon read.
//   * `write` likewise forwards to `csr_write` for its single active cycle.
//
// Purely combinational ⇒ no clock port (a zero-wait-state slave needs none). Reads to RO
// registers and writes to them are handled inside scope_csr (writes ignored, cfg_err on config
// writes while capturing) — the adapter is oblivious, exactly as "thin" requires.
//
// Clock-domain contract (INTERFACES.md): the CSR front-ends run in scope_csr's clock domain
// (`clk`, the capture domain) for XPORT="CSR" instantiations; any host-side CDC is the
// integrating fabric's responsibility. See docs/INTERFACES.md.

module scope_avalon (
    // Avalon-MM slave (32-bit, word-addressed)
    input  logic [7:0]  address,
    input  logic        read,
    output logic [31:0] readdata,
    input  logic        write,
    input  logic [31:0] writedata,
    output logic        waitrequest,

    // native CSR bus master (to scope_csr / scope_top ext_csr_*)
    output logic [7:0]  csr_addr,
    output logic [31:0] csr_wdata,
    output logic        csr_write,
    output logic        csr_read,
    input  logic [31:0] csr_rdata
);

  assign waitrequest = 1'b0;        // combinational native read ⇒ never stall
  assign csr_addr    = address;
  assign csr_wdata   = writedata;
  assign csr_write   = write;
  assign csr_read    = read;
  assign readdata    = csr_rdata;

endmodule
