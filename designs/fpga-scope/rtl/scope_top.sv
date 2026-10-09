// scope_top — the assembled embedded logic analyzer: trigger + core + CSR + drain + transport.
//
// Frozen host contract: docs/INTERFACES.md (parameters, ports, CSR map, frame format).
// Architecture: docs/DESIGN.md. Block wiring (PLAN.md §5):
//
//   probe ─►[scope_trigger]──trig──►┐
//   probe ─►(sample_o, RLE stub)──► [scope_core]  ◄── arm/config ── [scope_csr]
//                                        │ rd ports                     ▲ native CSR bus
//                                     capture domain (clk)          [servicer FSM]
//   ═════════ prim_fifo_async x2 (cmd in / rsp out — THE single CDC) ══╪═══════════
//                                     transport domain (xclk)       [scope_drain]
//                                                     [scope_uart | raw stream | (CSR mode)]
//
// Policy decisions:
//   * RLE stage (issue #9): with RLE_EN the trigger's aligned sample_o is run-length-encoded
//     by scope_rle into STORE_W=PROBE_W+1 {is_count,value} words; the core/csr/drain store and
//     drain WORDS, the trigger is re-aligned onto its (flushed) trigger word, and the host
//     reorders in the word domain then rle_decodes (rle_flag=1 in the DRAIN header). With
//     RLE_EN=0 the path is sample_o at PROBE_W, sample_valid tied 1 (PLAN.md §6.1) — the
//     datapath is byte-identical to the pre-#9 design (STORE_W==PROBE_W).
//   * Exactly ONE CDC (tracker rule 7): the cmd/rsp async-FIFO pair. It stays even when
//     xclk == clk (no bypass in v1 — correctness over area). The capture/write path never
//     sees transport back-pressure (tracker rule 1): the servicer only ever performs CSR
//     ops, which cannot stall the sample path.
//   * Servicer discipline: pop one cmd, execute one 1-cycle CSR strobe (side effects like
//     BUF_DATA pops must strobe exactly once), push one response, repeat. Combined with
//     the drain's one-outstanding rule the FIFOs can never overflow (formal (d)).
//   * XPORT selects the transport at elaboration: "UART" = scope_uart on uart_rx/uart_tx
//     (a small prim_fifo_sync absorbs rx bursts; UART has no flow control); "STREAM" =
//     raw rx_*/tx_* byte stream; "CSR" = no byte transport at all — the external native
//     CSR port (ext_csr_*, a v1 interface ADDITION for the #11 front-ends) owns the CSR
//     bus, and BUF_CTRL/BUF_DATA/WIN_SEL/WIN_META are the drain path.
//   * run (sequencer enable) = state==ARMED; trig_ext_i ORs into the trigger; trig_ext_o
//     never echoes trig_ext_i (no cross-instance loops). All identity comes from the
//     ID_VALUE parameter — no singleton state; two instances in one design work.
module scope_top #(
    parameter int unsigned PROBE_W    = 32,       // 1..512
    parameter int unsigned DEPTH_LOG2 = 8,        // 8..15
    parameter int unsigned NUM_CMP    = 4,
    parameter int unsigned SEQ_STAGES = 4,
    parameter bit          RLE_EN     = 1'b0,     // RLE lands in issue #9 (bypass stub now)
    parameter int unsigned TS_W       = 48,
    parameter              XPORT      = "UART",   // "UART" | "STREAM" | "CSR" (untyped: yosys)
    parameter int unsigned UART_DIV   = 16,       // xclk cycles per bit
    parameter logic [31:0] ID_VALUE   = 32'h0     // user tag, PING response
) (
    // capture domain
    input  logic               clk,
    input  logic               rst,        // synchronous, active high
    input  logic [PROBE_W-1:0] probe,
    input  logic               trig_ext_i,
    output logic               trig_ext_o,

    // transport domain (may be the same clock as clk)
    input  logic               xclk,
    input  logic               xrst,       // assert together with rst (async FIFO contract)

    // byte stream (XPORT=="STREAM"; tied off otherwise)
    input  logic [7:0]         rx_data,
    input  logic               rx_valid,
    output logic               rx_ready,
    output logic [7:0]         tx_data,
    output logic               tx_valid,
    input  logic               tx_ready,

    // UART pins (XPORT=="UART"; tied off otherwise)
    input  logic               uart_rx,
    output logic               uart_tx,

    // status
    output logic               armed,
    output logic               triggered,

    // external native CSR master (XPORT=="CSR" only — v1 addendum for the #11 front-ends)
    input  logic [7:0]         ext_csr_addr,
    input  logic [31:0]        ext_csr_wdata,
    input  logic               ext_csr_write,
    input  logic               ext_csr_read,
    output logic [31:0]        ext_csr_rdata
);

  // ------------------------------ capture domain --------------------------------------

  // Stored-word width: with RLE the core/csr/drain store {is_count,value} words (PROBE_W+1);
  // without RLE it is the raw probe width (datapath byte-identical to the pre-#9 design).
  localparam int unsigned STORE_W = RLE_EN ? (PROBE_W + 1) : PROBE_W;

  // native CSR bus (master = servicer, or ext_csr_* in CSR mode)
  logic [7:0] csr_addr;
  logic [31:0] csr_wdata;
  logic csr_write, csr_read;
  logic [31:0] csr_rdata;

  logic arm, disarm, force_trig;
  logic [DEPTH_LOG2-1:0] pretrig;
  logic [7:0] windows;
  logic rle_enable;
  logic [23:0] decim;              // SMPL_CTRL (issue #17/#20)
  logic qual_en;
  logic [1:0] qual_sel;
  logic [2:0] state;
  logic wrapped, cfg_err;
  logic [7:0] windows_done;
  logic [DEPTH_LOG2-1:0] trig_index;
  logic [TS_W-1:0] ts, ts_at_trig;
  logic [DEPTH_LOG2-1:0] buf_rd_addr;
  logic [STORE_W-1:0] buf_rd_data;
  logic [7:0] win_rd_addr;
  logic [DEPTH_LOG2:0] win_rd_data;
  logic [NUM_CMP*PROBE_W-1:0] cmp_mask, cmp_value, cmp_edge_mask, cmp_edge_pol;
  logic [31:0] trig_combine;
  logic [SEQ_STAGES*32-1:0] seq_cnt;

  logic trig;
  logic [PROBE_W-1:0] sample_o;
  logic [NUM_CMP-1:0] cmp_hit;

  scope_trigger #(
      .PROBE_W   (PROBE_W),
      .NUM_CMP   (NUM_CMP),
      .SEQ_STAGES(SEQ_STAGES)
  ) u_trigger (
      .clk          (clk),
      .rst          (rst),
      .probe        (probe),
      .run          (state == 3'(scope_pkg::SCOPE_ST_ARMED)),
      .force_trig   (force_trig),
      .trig_ext_i   (trig_ext_i),
      .cmp_mask     (cmp_mask),
      .cmp_value    (cmp_value),
      .cmp_edge_mask(cmp_edge_mask),
      .cmp_edge_pol (cmp_edge_pol),
      .trig_combine (trig_combine),
      .seq_cnt      (seq_cnt),
      .trig         (trig),
      .trig_ext_o   (trig_ext_o),
      .sample_o     (sample_o),
      .cmp_hit      (cmp_hit)
  );

  // ---- decimation + storage qualification (issue #17/#20) -----------------------------
  // A per-cycle sample-enable gates what the capture path actually stores. Both knobs live in
  // SMPL_CTRL (scope_csr) and default to 0 => sample_en high every cycle => byte-identical to
  // the pre-feature datapath.
  //   * decimation: store 1 sample every (decim+1) probe clocks (a downcounter tick).
  //   * qualification: store only when the selected comparator matches. cmp_hit is registered
  //     one stage before sample_o, so realign it by 1 cycle to gate the right sample.
  //   * a trigger that fires between store ticks is HELD until the next one, so the trigger
  //     always lands on a stored sample (on-grid in the decimated/qualified domain).
  logic [NUM_CMP-1:0] cmp_hit_d1;
  logic [23:0] dec_cnt;
  logic trig_pend;
  always_ff @(posedge clk) begin
    if (rst) begin
      cmp_hit_d1 <= '0;
      dec_cnt    <= 24'd0;
      trig_pend  <= 1'b0;
    end else begin
      cmp_hit_d1 <= cmp_hit;
      dec_cnt    <= (dec_cnt == 24'd0) ? decim : (dec_cnt - 24'd1);
      if (sample_en)  trig_pend <= 1'b0;   // consumed on a store tick
      else if (trig)  trig_pend <= 1'b1;   // held between ticks
    end
  end
  wire dec_tick  = (dec_cnt == 24'd0);
  wire qual_hit  = qual_en ? cmp_hit_d1[qual_sel] : 1'b1;
  wire sample_en = dec_tick & qual_hit;
  wire trig_fire = (trig | trig_pend) & sample_en;

  // ---- optional RLE stage (issue #9) --------------------------------------------------
  // RLE_EN=1: scope_rle run-length-encodes the aligned sample stream into STORE_W
  // {is_count,value} words and re-aligns the trigger onto the trigger word; the core, CSR
  // and drain all run at STORE_W and the host reorders in the word domain then rle_decodes.
  // RLE_EN=0: pure passthrough at PROBE_W (byte-identical to the pre-#9 datapath).
  logic [STORE_W-1:0] sample_data;
  logic               sample_valid;
  logic               core_trig;

  if (RLE_EN) begin : g_rle
    logic [PROBE_W:0] rle_word;
    logic             rle_word_valid, rle_trig_out;
    scope_rle #(
        .PROBE_W(PROBE_W),
        .CNT_W  (DEPTH_LOG2)
    ) u_rle (
        .clk       (clk),
        .rst       (rst),
        .enable    (rle_enable),   // RLE_CTRL[0]: 0 => bypass (still STORE_W words, is_count=0)
        .in_data   (sample_o),
        .in_valid  (sample_en),    // decimation/qualification gate (SMPL_CTRL); 1 every cycle by default
        .flush     (1'b0),         // no window-DONE flush: capture stops on slice-full-of-words
        .trig_in   (trig_fire),
        .word      (rle_word),
        .word_valid(rle_word_valid),
        .trig_out  (rle_trig_out)
    );
    assign sample_data  = rle_word;
    assign sample_valid = rle_word_valid;
    assign core_trig    = rle_trig_out;
  end else begin : g_norle
    assign sample_data  = sample_o;
    assign sample_valid = sample_en;
    assign core_trig    = trig_fire;
    wire unused_rle = &{1'b0, rle_enable};
  end

  scope_core #(
      .PROBE_W   (STORE_W),        // stores RLE words when RLE_EN, else raw probe samples
      .DEPTH_LOG2(DEPTH_LOG2),
      .TS_W      (TS_W)
  ) u_core (
      .clk         (clk),
      .rst         (rst),
      .sample_data (sample_data),
      .sample_valid(sample_valid),
      .trig        (core_trig),
      .arm         (arm),
      .disarm      (disarm),
      .pretrig     (pretrig),
      .windows     (windows),
      .state       (state),
      .triggered   (triggered),
      .wrapped     (wrapped),
      .windows_done(windows_done),
      .trig_index  (trig_index),
      .armed       (armed),
      .rd_addr     (buf_rd_addr),
      .rd_data     (buf_rd_data),
      .win_rd_addr (win_rd_addr),
      .win_rd_data (win_rd_data),
      .ts          (ts),
      .ts_at_trig  (ts_at_trig)
  );

  scope_csr #(
      .PROBE_W   (PROBE_W),
      .STORE_W   (STORE_W),
      .DEPTH_LOG2(DEPTH_LOG2),
      .NUM_CMP   (NUM_CMP),
      .SEQ_STAGES(SEQ_STAGES),
      .RLE_EN    (RLE_EN),
      .TS_W      (TS_W)
  ) u_csr (
      .clk          (clk),
      .rst          (rst),
      .csr_addr     (csr_addr),
      .csr_wdata    (csr_wdata),
      .csr_write    (csr_write),
      .csr_read     (csr_read),
      .csr_rdata    (csr_rdata),
      .arm          (arm),
      .disarm       (disarm),
      .force_trig   (force_trig),
      .pretrig      (pretrig),
      .windows      (windows),
      .rle_enable   (rle_enable),
      .decim        (decim),
      .qual_en      (qual_en),
      .qual_sel     (qual_sel),
      .state        (state),
      .triggered    (triggered),
      .wrapped      (wrapped),
      .windows_done (windows_done),
      .trig_index   (trig_index),
      .ts           (ts),
      .ts_at_trig   (ts_at_trig),
      .buf_rd_addr  (buf_rd_addr),
      .buf_rd_data  (buf_rd_data),
      .win_rd_addr  (win_rd_addr),
      .win_rd_data  (win_rd_data),
      .cmp_mask     (cmp_mask),
      .cmp_value    (cmp_value),
      .cmp_edge_mask(cmp_edge_mask),
      .cmp_edge_pol (cmp_edge_pol),
      .trig_combine (trig_combine),
      .seq_cnt      (seq_cnt),
      .cfg_err      (cfg_err)
  );

  wire unused_status = &{1'b0, cfg_err, wrapped, windows_done, trig_index};

  // ------------------------------ transport --------------------------------------------

  if (XPORT == "CSR") begin : g_csr_mode
    // no byte transport: the external front-end (#11) is the CSR master
    assign csr_addr  = ext_csr_addr;
    assign csr_wdata = ext_csr_wdata;
    assign csr_write = ext_csr_write;
    assign csr_read  = ext_csr_read;
    assign ext_csr_rdata = csr_rdata;
    assign rx_ready = 1'b0;
    assign tx_data = 8'h00;
    assign tx_valid = 1'b0;
    assign uart_tx = 1'b1;
    wire unused_csr_mode = &{1'b0, xclk, xrst, rx_data, rx_valid, tx_ready, uart_rx};
  end else begin : g_xport
    // ---- capture-domain CSR servicer + the single CDC (two prim_fifo_async) ----------
    logic [40:0] cmd_wr_data, cmd_rd_data;
    logic cmd_wr_valid, cmd_wr_ready, cmd_rd_valid, cmd_rd_ready;
    logic [31:0] rsp_wr_data, rsp_rd_data;
    logic rsp_wr_valid, rsp_wr_ready, rsp_rd_valid, rsp_rd_ready;

    prim_fifo_async #(
        .WIDTH     (41),
        .DEPTH_LOG2(2)
    ) u_cmd_fifo (
        .wclk    (xclk),
        .wrst    (xrst),
        .wr_data (cmd_wr_data),
        .wr_valid(cmd_wr_valid),
        .wr_ready(cmd_wr_ready),
        .rclk    (clk),
        .rrst    (rst),
        .rd_data (cmd_rd_data),
        .rd_valid(cmd_rd_valid),
        .rd_ready(cmd_rd_ready)
    );

    prim_fifo_async #(
        .WIDTH     (32),
        .DEPTH_LOG2(2)
    ) u_rsp_fifo (
        .wclk    (clk),
        .wrst    (rst),
        .wr_data (rsp_wr_data),
        .wr_valid(rsp_wr_valid),
        .wr_ready(rsp_wr_ready),
        .rclk    (xclk),
        .rrst    (xrst),
        .rd_data (rsp_rd_data),
        .rd_valid(rsp_rd_valid),
        .rd_ready(rsp_rd_ready)
    );

    // servicer: pop cmd -> 1-cycle CSR strobe (capture rdata) -> push response
    typedef enum logic [1:0] {
      SV_IDLE,
      SV_EXEC,
      SV_PUSH
    } sv_e;
    sv_e sv;
    logic sv_write;
    logic [7:0] sv_addr;
    logic [31:0] sv_wdata, sv_result;

    assign cmd_rd_ready = (sv == SV_IDLE);
    assign csr_addr = sv_addr;
    assign csr_wdata = sv_wdata;
    assign csr_write = (sv == SV_EXEC) && sv_write;
    assign csr_read = (sv == SV_EXEC) && !sv_write;
    assign rsp_wr_valid = (sv == SV_PUSH);
    assign rsp_wr_data = sv_result;
    assign ext_csr_rdata = 32'h0;
    wire unused_ext_csr = &{1'b0, ext_csr_addr, ext_csr_wdata, ext_csr_write, ext_csr_read};

    always_ff @(posedge clk) begin
      if (rst) begin
        sv <= SV_IDLE;
        sv_write <= 1'b0;
        sv_addr <= '0;
        sv_wdata <= '0;
        sv_result <= '0;
      end else begin
        unique case (sv)
          SV_IDLE: begin
            if (cmd_rd_valid) begin
              {sv_write, sv_addr, sv_wdata} <= cmd_rd_data;
              sv <= SV_EXEC;
            end
          end
          SV_EXEC: begin
            // csr_rdata is combinational: capture it in the strobe cycle
            sv_result <= sv_write ? sv_wdata : csr_rdata;
            sv <= SV_PUSH;
          end
          SV_PUSH: begin
            if (rsp_wr_ready) sv <= SV_IDLE;
          end
          default: sv <= SV_IDLE;
        endcase
      end
    end

    // ---- transport-domain drain engine -------------------------------------------------
    logic [7:0] drx_data, dtx_data;
    logic drx_valid, drx_ready, dtx_valid, dtx_ready;

    scope_drain #(
        .STORE_W   (STORE_W),
        .DEPTH_LOG2(DEPTH_LOG2),
        .RLE_EN    (RLE_EN),
        .ID_VALUE  (ID_VALUE)
    ) u_drain (
        .xclk     (xclk),
        .xrst     (xrst),
        .rx_data  (drx_data),
        .rx_valid (drx_valid),
        .rx_ready (drx_ready),
        .tx_data  (dtx_data),
        .tx_valid (dtx_valid),
        .tx_ready (dtx_ready),
        .cmd_data (cmd_wr_data),
        .cmd_valid(cmd_wr_valid),
        .cmd_ready(cmd_wr_ready),
        .rsp_data (rsp_rd_data),
        .rsp_valid(rsp_rd_valid),
        .rsp_ready(rsp_rd_ready)
    );

    if (XPORT == "UART") begin : g_uart
      logic [7:0] urx_data;
      logic urx_valid;
      logic unused_urx_ready;

      scope_uart #(
          .DIV(UART_DIV)
      ) u_uart (
          .clk     (xclk),
          .rst     (xrst),
          .uart_rx (uart_rx),
          .uart_tx (uart_tx),
          .tx_data (dtx_data),
          .tx_valid(dtx_valid),
          .tx_ready(dtx_ready),
          .rx_data (urx_data),
          .rx_valid(urx_valid)
      );

      // absorb rx bursts while the drain executes (UART has no flow control; the
      // command/response discipline bounds the backlog well under 16 bytes)
      prim_fifo_sync #(
          .WIDTH     (8),
          .DEPTH_LOG2(4)
      ) u_rx_fifo (
          .clk     (xclk),
          .rst     (xrst),
          .wr_data (urx_data),
          .wr_valid(urx_valid),
          .wr_ready(unused_urx_ready),  // overflow drops bytes; parser resyncs on the hunt
          .rd_data (drx_data),
          .rd_valid(drx_valid),
          .rd_ready(drx_ready)
      );

      assign rx_ready = 1'b0;
      assign tx_data = 8'h00;
      assign tx_valid = 1'b0;
      wire unused_stream = &{1'b0, rx_data, rx_valid, tx_ready};
    end else begin : g_stream
      assign drx_data = rx_data;
      assign drx_valid = rx_valid;
      assign rx_ready = drx_ready;
      assign tx_data = dtx_data;
      assign tx_valid = dtx_valid;
      assign dtx_ready = tx_ready;
      assign uart_tx = 1'b1;
      wire unused_uart = &{1'b0, uart_rx};
    end

`ifdef FORMAL
    // Formal property (d) — issue #8, run by formal/scope_top.sby (single-clock there:
    // xclk tied to clk). Checker in formal/scope_top_fchk.sv, instantiated inside the
    // generate scope so it sees the FIFO handshakes directly (same `ifdef pattern as
    // scope_core's checker; synthesis and Verilator never see it).
    scope_top_fchk u_fchk (
        .clk         (xclk),
        .rst         (xrst),
        .cmd_wr_valid(cmd_wr_valid),
        .cmd_wr_ready(cmd_wr_ready),
        .rsp_rd_valid(rsp_rd_valid),
        .rsp_rd_ready(rsp_rd_ready),
        .rsp_wr_valid(rsp_wr_valid),
        .rsp_wr_ready(rsp_wr_ready),
        .cmd_rd_valid(cmd_rd_valid),
        .cmd_rd_ready(cmd_rd_ready)
    );
`endif
  end

endmodule
