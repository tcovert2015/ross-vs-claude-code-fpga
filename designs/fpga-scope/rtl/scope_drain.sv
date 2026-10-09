// scope_drain — frame engine: parses command frames, emits response frames (TRANSPORT domain).
//
// Normative frame contract: docs/INTERFACES.md "Drain frame format — v1" + the #8 semantics
// addendum (DRAIN header layout, len16 byte order, sample packing, chunking). Envelope:
//   0xA5 0x5C | cmd(1) | len16(2, BE) | payload(len16) | crc16(2, BE over cmd..payload)
//
// Command handling (request payloads are <= 8 bytes; anything longer NAKs BAD_LEN
// immediately and the parser returns to the sync hunt — resync happens on 0xA5 0x5C):
//   PING      (payload ignored)  -> response payload: ID_REG(4,BE) + ID_VALUE(4,BE)
//   READ_CSR  (payload: addr(1)) -> response payload: value(4,BE)
//   WRITE_CSR (addr(1)+val(4,BE))-> executes, then reads STATUS; response: {7'b0, cfg_err}
//   DRAIN     (payload empty)    -> header frame (cmd=DRAIN):
//                                     flags(1: bit0 rle, bit1 wrapped) | windows_done(1) |
//                                     trig_index(2,BE) | ts_at_trig(6,BE) |
//                                     per window w < windows_done: {wrapped,trig_index[14:0]}(2,BE)
//                                   then DEPTH/SPF data frames (cmd=DRAIN_DATA), each:
//                                     chunk_index(2,BE) | SPF samples x ceil(PROBE_W/8)
//                                     bytes, LITTLE-endian byte order within a sample, raw
//                                     buffer order (host reorders per DESIGN.md); SPF =
//                                     min(DEPTH, 256) samples per frame.
//   bad CRC / unknown cmd / bad length -> NAK frame, payload = 1 error-code byte.
//
// Architecture rules (tracker rules 1/5/7): this module lives ENTIRELY in the transport
// domain. It reaches the capture domain only through the cmd/rsp async-FIFO pair (the
// design's single CDC), issuing native-CSR operations serviced at the capture side's own
// pace — everything (buffer words, per-window metadata via WIN_SEL/WIN_META, ts_at_trig)
// travels through the same FIFOs; nothing is re-sampled in this domain. STRICT
// ONE-OUTSTANDING-REQUEST discipline: a new cmd is pushed only after the previous response
// was popped — that is what makes the FIFOs unoverflowable (formal (d)).
// Half-duplex: rx_ready is low while executing/responding (command/response protocol).
module scope_drain #(
    parameter int unsigned STORE_W    = 32,     // stored-word width (= PROBE_W, or PROBE_W+1 RLE)
    parameter int unsigned DEPTH_LOG2 = 8,
    parameter bit          RLE_EN     = 1'b0,    // stored words are {is_count,value} -> rle_flag=1
    parameter logic [31:0] ID_VALUE   = 32'h0
) (
    input  logic        xclk,
    input  logic        xrst,       // synchronous, active high

    // host byte stream
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,
    output logic        rx_ready,
    output logic [7:0]  tx_data,
    output logic        tx_valid,
    input  logic        tx_ready,

    // cmd FIFO write side (to the capture-domain CSR servicer): {write, addr, wdata}
    output logic [40:0] cmd_data,
    output logic        cmd_valid,
    input  logic        cmd_ready,

    // response FIFO read side (from the servicer): 32-bit result per cmd
    input  logic [31:0] rsp_data,
    input  logic        rsp_valid,
    output logic        rsp_ready
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned LANES = (STORE_W + 31) / 32;  // 32-bit BUF_DATA reads per stored word
  localparam int unsigned NB = (STORE_W + 7) / 8;   // bytes per stored word on the wire
  localparam int unsigned SPF = (DEPTH < 256) ? DEPTH : 256;  // samples per data frame
  localparam int unsigned CHUNKS = DEPTH / SPF;

  typedef enum logic [5:0] {
    // command receive
    HUNT, SYNC1, RCMD, RLENH, RLENL, RPAY, RCRCH, RCRCL, DISPATCH,
    // CSR-op microstates (one outstanding)
    CSR_PUSH, CSR_WAIT,
    // byte-emit microstate
    EMIT,
    // response envelope
    R_SYNC0, R_SYNC1, R_CMD, R_LENH, R_LENL, R_PBUF, R_CRCH, R_CRCL,
    // command execution flows
    RD_EXEC, RD_RESP,
    WR_EXEC, WR_RDSTAT, WR_RESP,
    // DRAIN flow
    D_RD_STATUS, D_RD_TI, D_RD_TSL, D_RD_TSH, D_RD_RLE, D_HDR,
    D_FLAGS, D_WD, D_TIH, D_TIL, D_TS, D_WSEL, D_WMETA, D_WMH, D_WML,
    D_BUFRST, D_DF, D_CHKH, D_CHKL, D_LANE, D_SBYTE, D_NEXT
  } st_e;

  st_e st, ret_e, ret_c, pl_state, after_crc;

  // rx frame registers
  logic [7:0] r_cmd;
  logic [15:0] r_len;
  logic [7:0] pbuf[8];
  logic [3:0] pidx, plen;
  logic [15:0] crc_rx, crc_rx_got;

  // response registers
  logic [7:0] emit_q;
  logic crc_en_q;
  logic [7:0] t_cmd;
  logic [15:0] t_len;
  logic [15:0] crc_tx, crc_hold;

  // CSR op registers
  logic c_write;
  logic [7:0] c_addr;
  logic [31:0] c_wdata, rsp_q;

  // DRAIN registers
  logic [31:0] status_q, ti_q, tsl_q, tsh_q, rle_q;
  logic [7:0] w_idx;
  logic [2:0] ts_idx;
  logic [7:0] chunk_q;
  logic [8:0] samp_q;
  logic [7:0] lane_q;  // lane counter (LANES <= 16) — 8 bits to match c_addr math
  logic [6:0] bidx_q;
  logic [LANES*32-1:0] lane_buf;

  assign rx_ready = (st == HUNT) || (st == SYNC1) || (st == RCMD) || (st == RLENH) ||
                    (st == RLENL) || (st == RPAY) || (st == RCRCH) || (st == RCRCL);
  assign tx_data = emit_q;
  assign tx_valid = (st == EMIT);
  assign cmd_data = {c_write, c_addr, c_wdata};
  assign cmd_valid = (st == CSR_PUSH);
  assign rsp_ready = (st == CSR_WAIT);

  wire [7:0] w_done = status_q[15:8];

  // CRC16-CCITT (poly 0x1021, init 0xFFFF), one byte per call, MSB-first shift — the
  // normative wire CRC (INTERFACES.md). Lives here rather than in scope_pkg because the
  // yosys formal flow cannot parse package functions; TBs/host reimplement independently.
  // (classic function form — no `return`, integer loop var — for yosys-formal parseability)
  function automatic logic [15:0] crc16_ccitt_byte(input logic [15:0] crc, input logic [7:0] b);
    logic [15:0] c;
    integer i;
    begin
      c = crc ^ {b, 8'h00};
      for (i = 0; i < 8; i = i + 1) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_ccitt_byte = c;
    end
  endfunction

  // WIN_META register value ({wrapped @ bit DEPTH_LOG2, trig_index}) normalized to the
  // frame's fixed 16-bit layout: {wrapped, trig_index[14:0]} (INTERFACES.md #8 addendum)
  wire [15:0] wmeta16 = {rsp_q[DEPTH_LOG2], 15'(rsp_q[DEPTH_LOG2-1:0])};

  // architecturally unused slices (32-bit CSR responses carry narrower fields; crc_hold
  // only needs its low byte — the high byte is emitted straight from crc_tx)
  // rle_q (RLE_CTRL readback) is architecturally unused now that the header flag is the
  // elaboration-time RLE_EN, not the runtime rle_enable bit — kept read for FSM symmetry.
  wire unused_slices = &{1'b0, crc_hold[15:8], status_q[31:16], status_q[7:5], status_q[3:0],
                         ti_q[31:16], tsh_q[31:16], rle_q};

  always_ff @(posedge xclk) begin
    if (xrst) begin
      st <= HUNT;
      ret_e <= HUNT;
      ret_c <= HUNT;
      pl_state <= HUNT;
      after_crc <= HUNT;
      crc_en_q <= 1'b0;
      emit_q <= 8'h00;
      pidx <= '0;
      plen <= '0;
      c_write <= 1'b0;
      c_addr <= '0;
      c_wdata <= '0;
    end else begin
      unique case (st)
        // ------------------------------ command receive ------------------------------
        HUNT: if (rx_valid && rx_data == scope_pkg::SCOPE_SYNC0) st <= SYNC1;
        SYNC1: begin
          if (rx_valid) begin
            if (rx_data == scope_pkg::SCOPE_SYNC1) st <= RCMD;
            else if (rx_data != scope_pkg::SCOPE_SYNC0) st <= HUNT;  // A5 A5 5C ... still syncs
          end
        end
        RCMD: begin
          if (rx_valid) begin
            r_cmd  <= rx_data;
            crc_rx <= crc16_ccitt_byte(16'hFFFF, rx_data);
            st     <= RLENH;
          end
        end
        RLENH: begin
          if (rx_valid) begin
            r_len[15:8] <= rx_data;
            crc_rx      <= crc16_ccitt_byte(crc_rx, rx_data);
            st          <= RLENL;
          end
        end
        RLENL: begin
          if (rx_valid) begin
            r_len[7:0] <= rx_data;
            crc_rx     <= crc16_ccitt_byte(crc_rx, rx_data);
            pidx       <= '0;
            if ({r_len[15:8], rx_data} > 16'd8) begin
              // oversized request: NAK immediately, then re-hunt (no payload consume)
              t_cmd     <= scope_pkg::SCOPE_OP_NAK;
              t_len     <= 16'd1;
              pbuf[0]   <= scope_pkg::SCOPE_NAK_BAD_LEN;
              plen      <= 4'd1;
              pl_state  <= R_PBUF;
              after_crc <= HUNT;
              st        <= R_SYNC0;
            end else if ({r_len[15:8], rx_data} == 16'd0) begin
              st <= RCRCH;
            end else begin
              st <= RPAY;
            end
          end
        end
        RPAY: begin
          if (rx_valid) begin
            pbuf[pidx[2:0]] <= rx_data;
            crc_rx <= crc16_ccitt_byte(crc_rx, rx_data);
            pidx <= pidx + 4'd1;
            if (32'(pidx) + 1 >= 32'(r_len)) st <= RCRCH;
          end
        end
        RCRCH: if (rx_valid) begin crc_rx_got[15:8] <= rx_data; st <= RCRCL; end
        RCRCL: if (rx_valid) begin crc_rx_got[7:0] <= rx_data; st <= DISPATCH; end
        DISPATCH: begin
          plen <= 4'd1;
          pl_state <= R_PBUF;
          after_crc <= HUNT;
          if ({crc_rx_got[15:8], crc_rx_got[7:0]} != crc_rx) begin
            t_cmd   <= scope_pkg::SCOPE_OP_NAK;
            t_len   <= 16'd1;
            pbuf[0] <= scope_pkg::SCOPE_NAK_BAD_CRC;
            st      <= R_SYNC0;
          end else if (r_cmd == scope_pkg::SCOPE_OP_PING) begin
            t_cmd   <= scope_pkg::SCOPE_OP_PING;
            t_len   <= 16'd8;
            plen    <= 4'd8;
            {pbuf[0], pbuf[1], pbuf[2], pbuf[3]} <= scope_pkg::SCOPE_ID_REG;
            {pbuf[4], pbuf[5], pbuf[6], pbuf[7]} <= ID_VALUE;
            st      <= R_SYNC0;
          end else if (r_cmd == scope_pkg::SCOPE_OP_READ_CSR) begin
            if (r_len != 16'd1) begin
              t_cmd <= scope_pkg::SCOPE_OP_NAK; t_len <= 16'd1; pbuf[0] <= scope_pkg::SCOPE_NAK_BAD_LEN;
              st <= R_SYNC0;
            end else st <= RD_EXEC;
          end else if (r_cmd == scope_pkg::SCOPE_OP_WRITE_CSR) begin
            if (r_len != 16'd5) begin
              t_cmd <= scope_pkg::SCOPE_OP_NAK; t_len <= 16'd1; pbuf[0] <= scope_pkg::SCOPE_NAK_BAD_LEN;
              st <= R_SYNC0;
            end else st <= WR_EXEC;
          end else if (r_cmd == scope_pkg::SCOPE_OP_DRAIN) begin
            if (r_len != 16'd0) begin
              t_cmd <= scope_pkg::SCOPE_OP_NAK; t_len <= 16'd1; pbuf[0] <= scope_pkg::SCOPE_NAK_BAD_LEN;
              st <= R_SYNC0;
            end else st <= D_RD_STATUS;
          end else begin
            t_cmd   <= scope_pkg::SCOPE_OP_NAK;
            t_len   <= 16'd1;
            pbuf[0] <= scope_pkg::SCOPE_NAK_BAD_CMD;
            st      <= R_SYNC0;
          end
        end

        // ------------------------------ CSR op (one outstanding) ----------------------
        CSR_PUSH: if (cmd_ready) st <= CSR_WAIT;
        CSR_WAIT: if (rsp_valid) begin rsp_q <= rsp_data; st <= ret_c; end

        // ------------------------------ byte emit -------------------------------------
        EMIT: begin
          if (tx_ready) begin
            if (crc_en_q) crc_tx <= crc16_ccitt_byte(crc_tx, emit_q);
            st <= ret_e;
          end
        end

        // ------------------------------ response envelope -----------------------------
        R_SYNC0: begin
          crc_tx <= 16'hFFFF;
          emit_q <= scope_pkg::SCOPE_SYNC0; crc_en_q <= 1'b0; ret_e <= R_SYNC1; st <= EMIT;
        end
        R_SYNC1: begin emit_q <= scope_pkg::SCOPE_SYNC1; crc_en_q <= 1'b0; ret_e <= R_CMD; st <= EMIT; end
        R_CMD: begin emit_q <= t_cmd; crc_en_q <= 1'b1; ret_e <= R_LENH; st <= EMIT; end
        R_LENH: begin emit_q <= t_len[15:8]; crc_en_q <= 1'b1; ret_e <= R_LENL; st <= EMIT; end
        R_LENL: begin
          emit_q <= t_len[7:0]; crc_en_q <= 1'b1; ret_e <= pl_state; st <= EMIT;
          pidx <= '0;
        end
        R_PBUF: begin
          if (pidx >= plen) st <= R_CRCH;
          else begin
            emit_q <= pbuf[pidx[2:0]]; crc_en_q <= 1'b1; ret_e <= R_PBUF; st <= EMIT;
            pidx <= pidx + 4'd1;
          end
        end
        R_CRCH: begin
          crc_hold <= crc_tx;
          emit_q <= crc_tx[15:8]; crc_en_q <= 1'b0; ret_e <= R_CRCL; st <= EMIT;
        end
        R_CRCL: begin emit_q <= crc_hold[7:0]; crc_en_q <= 1'b0; ret_e <= after_crc; st <= EMIT; end

        // ------------------------------ READ_CSR / WRITE_CSR --------------------------
        RD_EXEC: begin
          c_write <= 1'b0; c_addr <= pbuf[0]; c_wdata <= '0;
          ret_c <= RD_RESP; st <= CSR_PUSH;
        end
        RD_RESP: begin
          t_cmd <= scope_pkg::SCOPE_OP_READ_CSR; t_len <= 16'd4; plen <= 4'd4;
          {pbuf[0], pbuf[1], pbuf[2], pbuf[3]} <= rsp_q;  // big-endian on the wire
          pl_state <= R_PBUF; after_crc <= HUNT; st <= R_SYNC0;
        end
        WR_EXEC: begin
          c_write <= 1'b1; c_addr <= pbuf[0];
          c_wdata <= {pbuf[1], pbuf[2], pbuf[3], pbuf[4]};  // big-endian payload
          ret_c <= WR_RDSTAT; st <= CSR_PUSH;
        end
        WR_RDSTAT: begin
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_STATUS); c_wdata <= '0;
          ret_c <= WR_RESP; st <= CSR_PUSH;
        end
        WR_RESP: begin
          t_cmd <= scope_pkg::SCOPE_OP_WRITE_CSR; t_len <= 16'd1; plen <= 4'd1;
          pbuf[0] <= {7'h0, rsp_q[5]};  // cfg_err after the write
          pl_state <= R_PBUF; after_crc <= HUNT; st <= R_SYNC0;
        end

        // ------------------------------ DRAIN: gather header fields --------------------
        D_RD_STATUS: begin
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_STATUS); c_wdata <= '0;
          ret_c <= D_RD_TI; st <= CSR_PUSH;
        end
        D_RD_TI: begin
          status_q <= rsp_q;
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_TRIG_INDEX); ret_c <= D_RD_TSL; st <= CSR_PUSH;
        end
        D_RD_TSL: begin
          ti_q <= rsp_q;
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_TSTRIG_LO); ret_c <= D_RD_TSH; st <= CSR_PUSH;
        end
        D_RD_TSH: begin
          tsl_q <= rsp_q;
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_TSTRIG_HI); ret_c <= D_RD_RLE; st <= CSR_PUSH;
        end
        D_RD_RLE: begin
          tsh_q <= rsp_q;
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_RLE_CTRL); ret_c <= D_HDR; st <= CSR_PUSH;
        end
        D_HDR: begin
          rle_q <= rsp_q;
          t_cmd <= scope_pkg::SCOPE_OP_DRAIN;
          t_len <= 16'd10 + {7'h0, w_done, 1'b0};  // 10 + 2*windows_done
          pl_state <= D_FLAGS; after_crc <= D_BUFRST; st <= R_SYNC0;
          w_idx <= 8'h00;
        end

        // ------------------------------ DRAIN: header payload --------------------------
        D_FLAGS: begin
          // bit1 wrapped, bit0 rle. rle_flag = RLE_EN (elaboration): the stored words are
          // STORE_W-wide {is_count,value} whenever the build carries the extra bit, so the host
          // unpacks STORE_W and rle_decodes — correct even when runtime rle_enable=0 (all
          // is_count=0 words decode to the raw stream). rle_q (RLE_CTRL) only gates compression.
          emit_q <= {6'h0, status_q[4], RLE_EN};
          crc_en_q <= 1'b1; ret_e <= D_WD; st <= EMIT;
        end
        D_WD: begin emit_q <= w_done; crc_en_q <= 1'b1; ret_e <= D_TIH; st <= EMIT; end
        D_TIH: begin emit_q <= ti_q[15:8]; crc_en_q <= 1'b1; ret_e <= D_TIL; st <= EMIT; end
        D_TIL: begin
          emit_q <= ti_q[7:0]; crc_en_q <= 1'b1; ret_e <= D_TS; st <= EMIT;
          ts_idx <= 3'd5;
        end
        D_TS: begin
          // ts48 = {TSTRIG_HI[15:0], TSTRIG_LO[31:0]}, big-endian on the wire
          unique case (ts_idx)
            3'd5: emit_q <= tsh_q[15:8];
            3'd4: emit_q <= tsh_q[7:0];
            3'd3: emit_q <= tsl_q[31:24];
            3'd2: emit_q <= tsl_q[23:16];
            3'd1: emit_q <= tsl_q[15:8];
            default: emit_q <= tsl_q[7:0];
          endcase
          crc_en_q <= 1'b1;
          if (ts_idx == 3'd0) ret_e <= D_WSEL;
          else begin ret_e <= D_TS; ts_idx <= ts_idx - 3'd1; end
          st <= EMIT;
        end
        D_WSEL: begin
          if (w_idx >= w_done) st <= R_CRCH;  // header payload complete
          else begin
            c_write <= 1'b1; c_addr <= 8'(scope_pkg::CSR_WIN_SEL); c_wdata <= 32'(w_idx);
            ret_c <= D_WMETA; st <= CSR_PUSH;
          end
        end
        D_WMETA: begin
          c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_WIN_META); c_wdata <= '0;
          ret_c <= D_WMH; st <= CSR_PUSH;
        end
        D_WMH: begin emit_q <= wmeta16[15:8]; crc_en_q <= 1'b1; ret_e <= D_WML; st <= EMIT; end
        D_WML: begin
          emit_q <= wmeta16[7:0]; crc_en_q <= 1'b1; ret_e <= D_WSEL; st <= EMIT;
          w_idx <= w_idx + 8'd1;
        end

        // ------------------------------ DRAIN: data frames ------------------------------
        D_BUFRST: begin
          c_write <= 1'b1; c_addr <= 8'(scope_pkg::CSR_BUF_CTRL); c_wdata <= 32'h1;
          ret_c <= D_DF; st <= CSR_PUSH;
          chunk_q <= 8'h00;
        end
        D_DF: begin
          t_cmd <= scope_pkg::SCOPE_OP_DRAIN_DATA;
          t_len <= 16'(2 + SPF * NB);
          pl_state <= D_CHKH;
          after_crc <= (32'(chunk_q) + 1 >= CHUNKS) ? HUNT : D_DF;
          samp_q <= '0;
          st <= R_SYNC0;
        end
        D_CHKH: begin emit_q <= 8'h00; crc_en_q <= 1'b1; ret_e <= D_CHKL; st <= EMIT; end
        D_CHKL: begin
          emit_q <= chunk_q; crc_en_q <= 1'b1; ret_e <= D_LANE; st <= EMIT;
          lane_q <= 8'h00;
        end
        D_LANE: begin
          if (32'(lane_q) >= LANES) begin
            bidx_q <= '0;
            st <= D_SBYTE;
          end else begin
            c_write <= 1'b0; c_addr <= 8'(scope_pkg::CSR_BUF_DATA); c_wdata <= '0;
            ret_c <= D_NEXT; st <= CSR_PUSH;
          end
        end
        D_NEXT: begin
          lane_buf[32*lane_q[3:0]+:32] <= rsp_q;
          lane_q <= lane_q + 8'd1;
          st <= D_LANE;
        end
        D_SBYTE: begin
          if (32'(bidx_q) >= NB) begin
            samp_q <= samp_q + 9'd1;
            lane_q <= 8'h00;
            if (32'(samp_q) + 1 >= SPF) begin
              chunk_q <= chunk_q + 8'd1;
              st <= R_CRCH;
            end else st <= D_LANE;
          end else begin
            emit_q <= lane_buf[8*bidx_q[5:0]+:8];  // little-endian within a sample
            crc_en_q <= 1'b1; ret_e <= D_SBYTE; st <= EMIT;
            bidx_q <= bidx_q + 7'd1;
          end
        end

        default: st <= HUNT;
      endcase
    end
  end

endmodule
