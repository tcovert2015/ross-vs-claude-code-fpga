// ============================================================================
// i3c_pkg.sv  -  Shared constants and types for the I3C Basic v1.2 SDR+IBI Target
//
// AUTHORITATIVE CONTRACT: every module codes against these constants/types.
// Do not redefine these locally. Source: docs/requirements.md (§7.5 CCC table,
// §7.6 GETSTATUS, §7.7 GETCAPS) and docs/design_decisions.md.
// ============================================================================
`ifndef I3C_PKG_SV
`define I3C_PKG_SV

package i3c_pkg;

  // ---------------------------------------------------------------------------
  // Addresses
  // ---------------------------------------------------------------------------
  localparam logic [6:0] I3C_BROADCAST_ADDR = 7'h7E;   // ADR-7E-01 / ACK-7E-01
  localparam logic       RNW_WRITE = 1'b0;
  localparam logic       RNW_READ  = 1'b1;

  // Restricted 7-bit addresses that MUST NOT be used as a Dynamic Address
  // (single-Hamming-distance neighbours of 0x7E plus 0x7E). Spec Table 10 / R-TE0-04.
  function automatic logic is_restricted_addr(input logic [6:0] a);
    is_restricted_addr =
        (a == 7'h7E) || (a == 7'h7F) || (a == 7'h7C) || (a == 7'h7A) ||
        (a == 7'h76) || (a == 7'h6E) || (a == 7'h5E) || (a == 7'h3E);
  endfunction

  // ---------------------------------------------------------------------------
  // Identity defaults (overridable via top-level parameters)
  // BCR: [7:6]=role(00 Target) [5]=adv(0) [4]=virt(0) [3]=offline(0)
  //      [2]=IBI-payload/MDB(1) [1]=IBI-capable(1) [0]=max-speed-limit(0)
  // ---------------------------------------------------------------------------
  localparam logic [7:0] BCR_DEFAULT = 8'h07;          // ID-BCR-02..08
  localparam logic [7:0] DCR_DEFAULT = 8'h00;          // ID-DCR-01 Generic Device

  // ---------------------------------------------------------------------------
  // Common Command Codes.  Broadcast: code[7]==0 (0x00..0x7F). Direct: code[7]==1.
  // 0xFF reserved.  (CCC-FRAME-01 / docs/requirements.md §7.5)
  // ---------------------------------------------------------------------------
  // Broadcast (B)
  localparam logic [7:0] CCC_ENEC_B    = 8'h00;
  localparam logic [7:0] CCC_DISEC_B   = 8'h01;
  localparam logic [7:0] CCC_ENTAS0_B  = 8'h02;   // ENTAS0..3 = 0x02..0x05
  localparam logic [7:0] CCC_ENTAS3_B  = 8'h05;
  localparam logic [7:0] CCC_RSTDAA_B  = 8'h06;
  localparam logic [7:0] CCC_ENTDAA_B  = 8'h07;
  localparam logic [7:0] CCC_DEFTGTS_B = 8'h08;
  localparam logic [7:0] CCC_SETMWL_B  = 8'h09;
  localparam logic [7:0] CCC_SETMRL_B  = 8'h0A;
  localparam logic [7:0] CCC_ENTTM_B   = 8'h0B;
  localparam logic [7:0] CCC_SETBUSCON_B = 8'h0C;
  localparam logic [7:0] CCC_ENDXFER_B = 8'h12;
  localparam logic [7:0] CCC_ENTHDR0_B = 8'h20;   // ENTHDR0..7 = 0x20..0x27
  localparam logic [7:0] CCC_ENTHDR7_B = 8'h27;
  localparam logic [7:0] CCC_SETAASA_B = 8'h29;
  localparam logic [7:0] CCC_RSTACT_B  = 8'h2A;
  localparam logic [7:0] CCC_DEFGRPA_B = 8'h2B;
  localparam logic [7:0] CCC_RSTGRPA_B = 8'h2C;
  // Direct (D)
  localparam logic [7:0] CCC_ENEC_D    = 8'h80;
  localparam logic [7:0] CCC_DISEC_D   = 8'h81;
  localparam logic [7:0] CCC_RSTDAA_D  = 8'h86;   // deprecated -> NACK
  localparam logic [7:0] CCC_SETDASA_D = 8'h87;
  localparam logic [7:0] CCC_SETNEWDA_D= 8'h88;
  localparam logic [7:0] CCC_SETMWL_D  = 8'h89;
  localparam logic [7:0] CCC_SETMRL_D  = 8'h8A;
  localparam logic [7:0] CCC_GETMWL_D  = 8'h8B;
  localparam logic [7:0] CCC_GETMRL_D  = 8'h8C;
  localparam logic [7:0] CCC_GETPID_D  = 8'h8D;
  localparam logic [7:0] CCC_GETBCR_D  = 8'h8E;
  localparam logic [7:0] CCC_GETDCR_D  = 8'h8F;
  localparam logic [7:0] CCC_GETSTATUS_D = 8'h90;
  localparam logic [7:0] CCC_GETACCCR_D  = 8'h91;  // not controller-capable -> NACK
  localparam logic [7:0] CCC_ENDXFER_D = 8'h92;
  localparam logic [7:0] CCC_SETBRGTGT_D = 8'h93;  // -> NACK
  localparam logic [7:0] CCC_GETMXDS_D = 8'h94;    // NACK unless BCR[0]=1
  localparam logic [7:0] CCC_GETCAPS_D = 8'h95;
  localparam logic [7:0] CCC_SETROUTE_D= 8'h96;    // -> NACK
  localparam logic [7:0] CCC_RSTACT_D  = 8'h9A;
  localparam logic [7:0] CCC_SETGRPA_D = 8'h9B;    // group N/A -> NACK
  localparam logic [7:0] CCC_RSTGRPA_D = 8'h9C;
  localparam logic [7:0] CCC_RESERVED_FF = 8'hFF;

  function automatic logic ccc_is_direct(input logic [7:0] code);
    ccc_is_direct = code[7];
  endfunction

  // ENEC/DISEC Events byte bits (CCC-ENEC table)
  localparam int unsigned EVT_ENINT = 0;   // IBI enable
  localparam int unsigned EVT_ENCR  = 1;   // controller-role request (ignored v1)
  localparam int unsigned EVT_ENHJ  = 3;   // hot-join (ignored v1)

  // ---------------------------------------------------------------------------
  // GETCAPS constant bytes (docs/requirements.md §7.7).
  //   GETCAP2[3:0]=4'b0010 (v1.2), [7:4]=0.  GETCAP3 bit index for Format-2 is an
  //   open question (design_decisions §6.4) -> single named param at top level.
  // ---------------------------------------------------------------------------
  localparam logic [7:0] GETCAP1_CONST = 8'h00;            // no HDR
  localparam logic [7:0] GETCAP2_CONST = 8'h02;            // {4'h0, 4'b0010}
  localparam logic [7:0] GETCAP3_DEFAULT = 8'h00;          // no timing-control/format2/PRN
  localparam logic [7:0] GETCAP4_CONST = 8'h00;            // no HDR CCCs

  // GETSTATUS Format-1 (16-bit) field positions (CCC-STAT-02/03)
  localparam int unsigned STAT_PENDINT_LSB = 0;   // [3:0] pending interrupt
  localparam int unsigned STAT_PROTOERR    = 5;   // sticky protocol-error, read-to-clear
  localparam int unsigned STAT_ACTMODE_LSB = 6;   // [7:6] activity mode

  // RSTACT defining bytes (CCC-RSTACT-01)
  localparam logic [7:0] RSTACT_NO_RESET   = 8'h00;
  localparam logic [7:0] RSTACT_PERIPHERAL = 8'h01;  // default

  // ---------------------------------------------------------------------------
  // SDA drive-source identifiers for the single-owner mux (i3c_sda_mux).
  // Index into the per-source request vectors; lower index = higher (defensive)
  // priority. Integration proves $onehot0 of the requests (critique F-2).
  // ---------------------------------------------------------------------------
  localparam int unsigned SDA_NSRC  = 6;
  localparam int unsigned SDA_ACK   = 0;   // protocol FSM address ACK
  localparam int unsigned SDA_TBIT  = 1;   // framer T-bit
  localparam int unsigned SDA_RDATA = 2;   // bit engine read data
  localparam int unsigned SDA_DAA   = 3;   // DAA payload shift
  localparam int unsigned SDA_IBI   = 4;   // IBI address/MDB/payload
  localparam int unsigned SDA_DBG   = 5;   // reserved / debug

  // ---------------------------------------------------------------------------
  // Frame phase (framer / protocol FSM): is the 9th bit an ACK slot or a T-bit?
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    PH_IDLE = 2'd0,
    PH_ADDR = 2'd1,   // 9th bit = ACK/NACK
    PH_DATA = 2'd2    // 9th bit = T-bit (parity on write / control on read)
  } phase_e;

  // ---------------------------------------------------------------------------
  // FIFO payload layout (added for the inter-module contract, docs/interfaces.md).
  // Shared so i3c_protocol_fsm / i3c_ccc / i3c_ibi / i3c_fifo / i3c_avalon_mm all
  // pack the same word. Mirrors the Avalon RX_DATA(0x30)/TX_DATA(0x34) registers.
  // ---------------------------------------------------------------------------
  // RX FIFO word: private-write / CCC-write bytes pushed bus->application.
  localparam int unsigned RX_FIFO_W   = 11;
  localparam int unsigned RXF_DATA_LSB = 0;   // [7:0]  byte
  localparam int unsigned RXF_VALID    = 8;   // entry valid (always 1 in FIFO)
  localparam int unsigned RXF_LAST     = 9;   // last byte of frame (STOP/Sr boundary)
  localparam int unsigned RXF_IS_CCC   = 10;  // byte belonged to a CCC (vs private write)
  // TX FIFO word: private-read / IBI-payload bytes pushed application->bus.
  localparam int unsigned TX_FIFO_W   = 9;
  localparam int unsigned TXF_DATA_LSB = 0;   // [7:0]  byte
  localparam int unsigned TXF_LAST     = 8;   // last byte (drives read T-bit = 0)

endpackage

`endif
