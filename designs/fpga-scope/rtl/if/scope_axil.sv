// scope_axil — AXI4-Lite slave front-end for the scope's native CSR bus (issue #11).
//
// A THIN protocol adapter: zero scope logic. Maps the five AXI4-Lite channels onto the native
// CSR bus (word-addressed, combinational read, single-cycle strobes). One transaction at a time
// through a tiny FSM — AXI4-Lite does not require concurrent read+write, and serializing keeps
// the single-cycle `csr_write`/`csr_read` strobes (and the BUF_DATA pop-on-read side effect)
// exactly once per transaction.
//
//   * Address: AXI byte address; low 2 bits ignored; ADDR[9:2] is the CSR word index.
//   * Write: accepted only when BOTH AW and W are valid (joint accept), so any AW/W arrival
//     order works. One `csr_write` strobe on the accept cycle, then BRESP=OKAY.
//   * Read: on AR handshake, one `csr_read` strobe; the combinational `csr_rdata` is latched
//     that cycle (so the BUF_DATA read pointer may advance underneath us), then RVALID/RDATA.
//   * Responses are always OKAY. Writes to read-only registers are silently ignored inside
//     scope_csr (no SLVERR in v1); config writes while capturing set the sticky cfg_err bit —
//     the adapter is oblivious. Documented in docs/INTERFACES.md.
//   * Write has priority over read when both are offered in IDLE (arbitrary, documented).
//
// Clock-domain contract: runs in scope_csr's clock domain (`clk`, capture domain) for
// XPORT="CSR"; host-side CDC is the integrating fabric's problem. See docs/INTERFACES.md.

module scope_axil (
    input  logic        clk,
    input  logic        rst,          // synchronous, active high

    // AXI4-Lite slave (32-bit)
    input  logic [9:0]  awaddr,       // byte address; [9:2] = CSR word
    input  logic        awvalid,
    output logic        awready,
    input  logic [31:0] wdata,
    input  logic [3:0]  wstrb,        // accepted, not enforced (RMW is not a v1 CSR feature)
    input  logic        wvalid,
    output logic        wready,
    output logic [1:0]  bresp,
    output logic        bvalid,
    input  logic        bready,
    input  logic [9:0]  araddr,
    input  logic        arvalid,
    output logic        arready,
    output logic [31:0] rdata,
    output logic [1:0]  rresp,
    output logic        rvalid,
    input  logic        rready,

    // native CSR bus master
    output logic [7:0]  csr_addr,
    output logic [31:0] csr_wdata,
    output logic        csr_write,
    output logic        csr_read,
    input  logic [31:0] csr_rdata
);

  localparam logic [1:0] RESP_OKAY = 2'b00;

  typedef enum logic [1:0] { S_IDLE, S_WRESP, S_RRESP } state_e;
  state_e st;

  logic [31:0] rdata_q;

  // Combinational native-bus strobes: asserted only in IDLE on an accepted transaction.
  wire do_write = (st == S_IDLE) && awvalid && wvalid;
  wire do_read  = (st == S_IDLE) && !do_write && arvalid;  // write has priority

  assign csr_write = do_write;
  assign csr_read  = do_read;
  assign csr_addr  = do_write ? awaddr[9:2] : araddr[9:2];
  assign csr_wdata = wdata;

  // Channel readies / valids
  assign awready = do_write;
  assign wready  = do_write;
  assign arready = do_read;
  assign bresp   = RESP_OKAY;
  assign rresp   = RESP_OKAY;
  assign bvalid  = (st == S_WRESP);
  assign rvalid  = (st == S_RRESP);
  assign rdata   = rdata_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= S_IDLE;
      rdata_q <= '0;
    end else begin
      unique case (st)
        S_IDLE: begin
          if (do_write)     st <= S_WRESP;
          else if (do_read) begin
            rdata_q <= csr_rdata;   // latch the combinational read (pointer may advance next cycle)
            st      <= S_RRESP;
          end
        end
        S_WRESP: if (bready) st <= S_IDLE;
        S_RRESP: if (rready) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end

  wire _unused = &{1'b0, wstrb, awaddr[1:0], araddr[1:0]};

endmodule
