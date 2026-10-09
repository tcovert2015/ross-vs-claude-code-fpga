// scope_pkg — shared types, opcodes, and CSR offsets for the fpga-scope embedded logic analyzer.
//
// Single source of truth (no magic numbers elsewhere): the capture-FSM state encoding, the
// drain-frame protocol constants, the CSR word offsets, and the ID register value all live
// here. Interface contract: docs/INTERFACES.md (v0 DRAFT — offsets/opcodes freeze at M2,
// issue #5). Architecture: docs/DESIGN.md.
package scope_pkg;

  /* verilator lint_off UNUSEDPARAM */
  // waiver: this package is the single source of truth for the whole design; the frame
  // opcodes and CSR offsets are consumed by scope_csr/scope_drain (issues #5/#8) — they are
  // "unused" only until those modules land.

  // ------------------------------------------------------------------------------------
  // Capture FSM state encoding — these values ARE the STATUS.state[2:0] field read by the
  // host (INTERFACES.md CSR map), not just an internal enum. Do not renumber after M2.
  //   IDLE      0: not armed; buffer readable from the last completed capture
  //   FILLING   1: armed, storing the PRETRIG backlog; triggers not yet accepted
  //   ARMED     2: circular capture, write pointer free-running, triggers accepted
  //   TRIGGERED 3: trigger latched, storing the DEPTH-PRETRIG post-trigger samples
  //   DONE      4: capture window complete; write pointer frozen
  // ------------------------------------------------------------------------------------
  typedef enum logic [2:0] {
    SCOPE_ST_IDLE      = 3'd0,
    SCOPE_ST_FILLING   = 3'd1,
    SCOPE_ST_ARMED     = 3'd2,
    SCOPE_ST_TRIGGERED = 3'd3,
    SCOPE_ST_DONE      = 3'd4
  } scope_state_e;

  // ------------------------------------------------------------------------------------
  // ID register: magic | version (CSR word 0). The 32-bit user tag lives in the ID_VALUE
  // parameter of scope_top and is readable separately (placement fixed at the M2 freeze).
  // ------------------------------------------------------------------------------------
  localparam logic [31:0] SCOPE_ID_MAGIC = 32'h5C09E000;
  localparam logic [7:0]  SCOPE_VERSION  = 8'h01;
  localparam logic [31:0] SCOPE_ID_REG   = SCOPE_ID_MAGIC | {24'h0, SCOPE_VERSION};

  // ------------------------------------------------------------------------------------
  // Drain frame protocol (issue #8): 0xA5 0x5C | cmd | len16 | payload | crc16-ccitt.
  // CRC16-CCITT poly 0x1021 init 0xFFFF over cmd..payload, big-endian on the wire.
  // ------------------------------------------------------------------------------------
  localparam logic [7:0] SCOPE_SYNC0 = 8'hA5;
  localparam logic [7:0] SCOPE_SYNC1 = 8'h5C;

  localparam logic [7:0] SCOPE_OP_PING       = 8'h01;
  localparam logic [7:0] SCOPE_OP_READ_CSR   = 8'h02;
  localparam logic [7:0] SCOPE_OP_WRITE_CSR  = 8'h03;
  localparam logic [7:0] SCOPE_OP_DRAIN      = 8'h04;
  localparam logic [7:0] SCOPE_OP_DRAIN_DATA = 8'h05;  // response-only: sample chunk frames
  localparam logic [7:0] SCOPE_OP_NAK        = 8'h15;  // ASCII NAK; response to bad CRC/cmd

  // NAK payload error codes (1 byte)
  localparam logic [7:0] SCOPE_NAK_BAD_CRC = 8'h01;
  localparam logic [7:0] SCOPE_NAK_BAD_CMD = 8'h02;
  localparam logic [7:0] SCOPE_NAK_BAD_LEN = 8'h03;

  // ------------------------------------------------------------------------------------
  // CSR word offsets (byte offset = index * 4). These match docs/INTERFACES.md
  // "CSR map — v1 FROZEN" exactly, one for one — that section is the normative source;
  // do not change either without a documented interface-revision note there.
  // ------------------------------------------------------------------------------------
  localparam int unsigned CSR_ID             = 0;
  localparam int unsigned CSR_HWCFG          = 1;
  localparam int unsigned CSR_CTRL           = 2;   // W strobes: 0 arm, 1 disarm, 2 force_trig, 3 soft_rst
  localparam int unsigned CSR_STATUS         = 3;
  localparam int unsigned CSR_PRETRIG        = 4;
  localparam int unsigned CSR_WINDOWS        = 5;
  localparam int unsigned CSR_RLE_CTRL       = 6;
  localparam int unsigned CSR_TS_LO          = 7;   // read latches TS_HI shadow
  localparam int unsigned CSR_TS_HI          = 8;
  localparam int unsigned CSR_TRIG_INDEX     = 9;
  localparam int unsigned CSR_TSTRIG_LO      = 10;
  localparam int unsigned CSR_TSTRIG_HI      = 11;
  localparam int unsigned CSR_WIN_SEL        = 12;  // window selector for WIN_META (v1 #8 addendum)
  localparam int unsigned CSR_WIN_META       = 13;  // RO: {wrapped, trig_index} of selected window
  localparam int unsigned CSR_SMPL_CTRL      = 14;  // decimation + storage qualification (#17/#20):
                                                    //   [23:0] DECIM (store 1 / DECIM+1 cycles, 0=every)
                                                    //   [24] QUAL_EN  [26:25] QUAL_SEL (comparator k)
  localparam int unsigned CSR_CMP_SEL        = 15;  // [1:0] comparator k, [3:2] field
  localparam int unsigned CSR_CMP_LANE_BASE  = 16;  // 16..31: lane window of selected field
  localparam int unsigned CSR_CMP_LANE_WORDS = 16;
  localparam int unsigned CSR_TRIG_COMBINE   = 64;
  localparam int unsigned CSR_SEQ_CNT_BASE   = 65;  // 65..68 = SEQ_CNT0..3
  localparam int unsigned CSR_BUF_CTRL       = 96;
  localparam int unsigned CSR_BUF_DATA       = 97;

  // CMP_SEL field encoding ([3:2])
  localparam logic [1:0] CMP_FIELD_MASK      = 2'd0;
  localparam logic [1:0] CMP_FIELD_VALUE     = 2'd1;
  localparam logic [1:0] CMP_FIELD_EDGE_MASK = 2'd2;
  localparam logic [1:0] CMP_FIELD_EDGE_POL  = 2'd3;
  /* verilator lint_on UNUSEDPARAM */

endpackage
