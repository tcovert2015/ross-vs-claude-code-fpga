// ============================================================================
// i3c_avalon_mm.sv  -  Avalon-MM agent + FIFO / IBI / INT glue (architecture §1.12)
//
// Decodes the 32-bit, word-aligned register map (docs/architecture.md §3 /
// docs/interfaces.md §3) for the I3C Basic v1.2 SDR+IBI Target. Responsibilities:
//   * Avalon-MM agent (address/read/write/readdata/writedata/byteenable/
//     waitrequest/readdatavalid). Pipelined fixed-1-cycle read latency tracked by
//     an OUTSTANDING-TRANSACTION SCOREBOARD (design_decisions D-2), not $past.
//   * RX FIFO read side: RX_DATA pops ONLY on the readdatavalid beat (D-3) and
//     only when non-empty; never on command accept; no double-pop.
//   * TX FIFO write side: back-pressure (waitrequest) on TX_DATA write while full
//     so a byte is never silently dropped (V5 / no-overrun).
//   * INT_STATUS (W1C) + INT_ENABLE; irq = |(int_status & int_enable) (V6).
//   * CTRL bits to the core; IBI_CTRL trigger/MDB; live STATUS/DYN_ADDR/IBI_STATUS
//     assembly; RF-owned registers via the regfile app port.
//
// Open-source yosys formal subset: immediate assertions in clocked blocks only,
// boolean implication (!ant || cons), $past/$stable, f_past_valid, assume(!rst_n).
// ============================================================================
`ifndef I3C_AVALON_MM_SV
`define I3C_AVALON_MM_SV
`include "i3c_pkg.sv"

module i3c_avalon_mm #(
  parameter int unsigned AW = 5            // word address width (register map 0..17)
) (
  input  logic              clk,           // Avalon clock (default = sys_clk)
  input  logic              rst_n,

  // ---- Avalon-MM agent --------------------------------------------------------
  input  logic [AW-1:0]     avs_address,
  input  logic              avs_read,
  input  logic              avs_write,
  input  logic [31:0]       avs_writedata,
  input  logic [3:0]        avs_byteenable,
  output logic [31:0]       avs_readdata,
  output logic              avs_readdatavalid,
  output logic              avs_waitrequest,
  output logic              irq,

  // ---- regfile app port -------------------------------------------------------
  output logic              app_wr_en,
  output logic [4:0]        app_wr_idx,
  output logic [31:0]       app_wr_data,
  output logic [3:0]        app_wr_be,
  output logic [4:0]        app_rd_idx,
  input  logic [31:0]       app_rd_data,

  // ---- RX FIFO (read side) ----------------------------------------------------
  input  logic [10:0]       rx_rd_data,    // RX head word (RXF_* layout)
  input  logic              rx_empty,
  input  logic [7:0]        rx_level,
  input  logic              rx_overflow,
  output logic              rx_pop,         // pop only on readdatavalid of RX_DATA (D-3)

  // ---- TX FIFO (write side) ---------------------------------------------------
  input  logic              tx_full,
  input  logic [7:0]        tx_level,
  output logic              tx_push,
  output logic [8:0]        tx_wr_data,     // {last,data} (TXF_* layout)
  output logic              flush_rx,
  output logic              flush_tx,

  // ---- IBI control / status ---------------------------------------------------
  output logic              ibi_request,
  output logic [7:0]        mdb,
  output logic              mdb_is_prn,
  input  logic              ibi_busy,
  input  logic              ibi_acked,
  input  logic              ibi_nacked,
  input  logic              ibi_deferred,
  input  logic              ibi_arb_lost,

  // ---- CTRL outputs to core ---------------------------------------------------
  output logic              core_en,
  output logic              accept_en,
  output logic              ibi_en_app,
  output logic              soft_reset,
  output logic              static_addr_en,
  output logic              prn_send_en,

  // ---- status inputs from core ------------------------------------------------
  input  logic              da_valid,
  input  logic [6:0]        dyn_addr,
  input  logic              in_hdr_quiesce,
  input  logic              in_error,
  input  logic              bus_busy,
  input  logic              bus_free,
  input  logic              bus_available,
  input  logic              bus_idle,
  input  logic [3:0]        te_code,
  input  logic              proto_err_seen,

  // ---- INT sources (latched into INT_STATUS, W1C) -----------------------------
  input  logic              int_rx_ready,
  input  logic              int_tx_space,
  input  logic              int_priv_write_done,
  input  logic              int_priv_read_req,
  input  logic              int_ibi_done,
  input  logic              int_ibi_nacked,
  input  logic              int_da_changed,
  input  logic              int_periph_reset,
  input  logic              int_proto_err,
  input  logic              int_ccc_event
);

  // ---------------------------------------------------------------------------
  // Register-map word indices (docs/architecture.md §3 / interfaces.md §3).
  // ---------------------------------------------------------------------------
  localparam logic [4:0] IDX_CTRL     = 5'd0;
  localparam logic [4:0] IDX_STATUS   = 5'd1;
  localparam logic [4:0] IDX_INT_EN   = 5'd2;
  localparam logic [4:0] IDX_INT_ST   = 5'd3;
  localparam logic [4:0] IDX_DYN_ADDR = 5'd4;
  localparam logic [4:0] IDX_PID_LOW  = 5'd5;
  localparam logic [4:0] IDX_PID_HIGH = 5'd6;
  localparam logic [4:0] IDX_IDENT    = 5'd7;
  localparam logic [4:0] IDX_MWL      = 5'd8;
  localparam logic [4:0] IDX_MRL      = 5'd9;
  localparam logic [4:0] IDX_IBI_CTRL = 5'd10;
  localparam logic [4:0] IDX_IBI_ST   = 5'd11;
  localparam logic [4:0] IDX_RX_DATA  = 5'd12;
  localparam logic [4:0] IDX_TX_DATA  = 5'd13;
  localparam logic [4:0] IDX_FIFO_ST  = 5'd14;
  localparam logic [4:0] IDX_GS_CFG   = 5'd15;
  localparam logic [4:0] IDX_CAPS     = 5'd16;
  localparam logic [4:0] IDX_RESET    = 5'd17;

  // ---------------------------------------------------------------------------
  // Avalon decode helpers
  // ---------------------------------------------------------------------------
  logic [4:0] tgt;
  assign tgt = avs_address[4:0];

  // Regfile-owned indices that the application may WRITE. Identity (PID_LOW/
  // PID_HIGH/IDENT) is read-only from the Avalon side (V4/D-6): never forwarded.
  function automatic logic rf_writable(input logic [4:0] idx);
    rf_writable = (idx == IDX_MWL)   || (idx == IDX_MRL)  ||
                  (idx == IDX_GS_CFG)|| (idx == IDX_CAPS) || (idx == IDX_RESET);
  endfunction
  // Regfile-owned indices that the application may READ (identity included).
  function automatic logic rf_readable(input logic [4:0] idx);
    rf_readable = (idx == IDX_PID_LOW) || (idx == IDX_PID_HIGH) || (idx == IDX_IDENT) ||
                  (idx == IDX_MWL)     || (idx == IDX_MRL)      ||
                  (idx == IDX_GS_CFG)  || (idx == IDX_CAPS)     || (idx == IDX_RESET);
  endfunction

  // TX_DATA write while the FIFO is full is the only back-pressure source: hold
  // the command (waitrequest) so the byte is never dropped (V2/V5). Reads never
  // stall (fixed 1-cycle latency, RX_DATA returns valid=0 when empty).
  assign avs_waitrequest = avs_write && (tgt == IDX_TX_DATA) && tx_full;

  logic write_accept;
  logic read_accept;
  assign write_accept = avs_write && !avs_waitrequest;
  assign read_accept  = avs_read  && !avs_waitrequest;

  // ---------------------------------------------------------------------------
  // CTRL register (idx 0) - AV owned. Bits [5:0] persistent; [6]/[7] are
  // write-1 pulses (flush_rx/flush_tx, auto-clear).
  // ---------------------------------------------------------------------------
  logic [5:0] ctrl_reg;
  assign core_en        = ctrl_reg[0];
  assign accept_en      = ctrl_reg[1];
  assign ibi_en_app     = ctrl_reg[2];
  assign soft_reset     = ctrl_reg[3];
  assign static_addr_en = ctrl_reg[4];
  assign prn_send_en    = ctrl_reg[5];

  assign flush_rx = write_accept && (tgt == IDX_CTRL) && avs_byteenable[0] && avs_writedata[6];
  assign flush_tx = write_accept && (tgt == IDX_CTRL) && avs_byteenable[0] && avs_writedata[7];

  // ---------------------------------------------------------------------------
  // INT_ENABLE (idx 2) + INT_STATUS (idx 3, W1C). 10 valid bits each.
  // ---------------------------------------------------------------------------
  logic [9:0] int_enable;
  logic [9:0] int_status;

  // Edge/level sources latched into INT_STATUS (set side).
  logic [9:0] int_src;
  assign int_src = { int_ccc_event,        // [9]
                     int_proto_err,        // [8]
                     int_periph_reset,     // [7]
                     int_da_changed,       // [6]
                     int_ibi_nacked,       // [5]
                     int_ibi_done,         // [4]
                     int_priv_read_req,    // [3]
                     int_priv_write_done,  // [2]
                     int_tx_space,         // [1]
                     int_rx_ready };       // [0]

  // W1C clear vector for INT_STATUS (byteenable honored: [7:0]->be0, [9:8]->be1).
  logic [9:0] w1c_clear;
  always_comb begin
    w1c_clear = 10'b0;
    if (write_accept && (tgt == IDX_INT_ST)) begin
      if (avs_byteenable[0]) w1c_clear[7:0] = avs_writedata[7:0];
      if (avs_byteenable[1]) w1c_clear[9:8] = avs_writedata[9:8];
    end
  end

  assign irq = |(int_status & int_enable);   // V6

  // ---------------------------------------------------------------------------
  // IBI_CTRL (idx 10) - AV owned. ibi_request is W1S/auto-clear (pulse). mdb /
  // mdb_is_prn / payload_len persistent.
  // ---------------------------------------------------------------------------
  logic [7:0] ibi_mdb_q;
  logic       ibi_prn_q;
  logic [7:0] ibi_plen_q;
  assign mdb         = ibi_mdb_q;
  assign mdb_is_prn  = ibi_prn_q;
  assign ibi_request = write_accept && (tgt == IDX_IBI_CTRL) && avs_byteenable[0] && avs_writedata[0];

  // ---------------------------------------------------------------------------
  // Regfile app-write forwarding (V4/D-6). Only RF-writable indices; faithful
  // byteenable; never on a read.
  // ---------------------------------------------------------------------------
  assign app_wr_en   = write_accept && rf_writable(tgt);
  assign app_wr_idx  = tgt;               // 5-bit: reaches CAPS(16)/RESET(17) (bug-fix)
  assign app_wr_data = avs_writedata;
  assign app_wr_be   = avs_byteenable;

  // ---------------------------------------------------------------------------
  // TX FIFO push (idx 13). Push exactly when accepted (==!tx_full), so never
  // push-while-full (V5 no-overrun).
  // ---------------------------------------------------------------------------
  assign tx_push    = write_accept && (tgt == IDX_TX_DATA);
  assign tx_wr_data = { avs_writedata[i3c_pkg::TXF_LAST], avs_writedata[7:0] };

  // ---------------------------------------------------------------------------
  // Read pipeline + outstanding-transaction scoreboard (D-2). Registered 2-cycle
  // latency (issue #1): a read accepted at T is SAMPLED at T+1 (rdv_q / rd_data_comb)
  // and the REGISTERED result is DELIVERED at T+2 (rdv_q2 / rd_data_q). Registering
  // avs_readdata puts the launch flop next to the output pad, which closes the
  // RX-FIFO-read -> readback-mux -> output-pin path in standalone pin synthesis
  // (the combinational version missed timing by ~2.9 ns). Avalon-MM permits this:
  // latency is variable and signalled by readdatavalid.
  // ---------------------------------------------------------------------------
  logic        rdv_q;            // stage 1: read accepted last cycle (SAMPLE beat)
  logic        rdv_q2;           // stage 2: registered -> readdatavalid (DELIVERY beat)
  logic [4:0]  rd_idx_q;         // address of the in-flight read (valid on the sample beat)
  logic [31:0] rd_data_comb;     // combinational readback mux (valid on the sample beat)
  logic [31:0] rd_data_q;        // registered read data -> avs_readdata (delivery beat)
  logic [1:0]  outstanding;      // scoreboard count (bounded to 0..2: two pipe stages)

  assign avs_readdatavalid = rdv_q2;
  assign avs_readdata      = rd_data_q;
  assign app_rd_idx        = rd_idx_q;

  // RX_DATA pops on the SAMPLE beat (rdv_q) of an RX_DATA read, when non-empty
  // (D-3, no underflow). Sample-and-pop are atomic on the same head; the popped
  // word is captured into rd_data_q and delivered one cycle later with
  // readdatavalid -- so a pipelined second read still sees the advanced pointer.
  assign rx_pop = rdv_q && (rd_idx_q == IDX_RX_DATA) && !rx_empty;

  // ---------------------------------------------------------------------------
  // Live STATUS assembly
  // ---------------------------------------------------------------------------
  logic [2:0]  bus_state;
  assign bus_state = bus_busy      ? 3'd3 :
                     bus_available ? 3'd2 :
                     bus_free      ? 3'd1 : 3'd0;   // default idle = 0
  logic        i3c_mode;
  assign i3c_mode = da_valid;

  logic [31:0] status_word;
  assign status_word = { 18'b0,
                         rx_overflow,      // [13]
                         proto_err_seen,   // [12]
                         ibi_busy,         // [11]
                         te_code,          // [10:7]
                         bus_state,        // [6:4]
                         in_error,         // [3]
                         in_hdr_quiesce,   // [2]
                         i3c_mode,         // [1]
                         da_valid };       // [0]

  // ---------------------------------------------------------------------------
  // Read-data combinational readback mux (valid on the SAMPLE beat). Captured into
  // the rd_data_q output register below and delivered on the next cycle (issue #1).
  // ---------------------------------------------------------------------------
  always_comb begin
    unique case (rd_idx_q)
      IDX_CTRL    : rd_data_comb = { 26'b0, ctrl_reg };                          // flush bits read 0
      IDX_STATUS  : rd_data_comb = status_word;
      IDX_INT_EN  : rd_data_comb = { 22'b0, int_enable };
      IDX_INT_ST  : rd_data_comb = { 22'b0, int_status };
      IDX_DYN_ADDR: rd_data_comb = { 24'b0, da_valid, dyn_addr };
      IDX_PID_LOW,
      IDX_PID_HIGH,
      IDX_IDENT,
      IDX_MWL,
      IDX_MRL,
      IDX_GS_CFG,
      IDX_CAPS,
      IDX_RESET   : rd_data_comb = app_rd_data;
      IDX_IBI_CTRL: rd_data_comb = { 8'b0, ibi_plen_q, ibi_prn_q, 2'b0, ibi_mdb_q, 5'b0 };
      IDX_IBI_ST  : rd_data_comb = { 27'b0, ibi_deferred, ibi_arb_lost, ibi_nacked, ibi_acked, ibi_busy };
      IDX_RX_DATA : rd_data_comb = rx_empty ? 32'b0 : { 21'b0, rx_rd_data };
      IDX_TX_DATA : rd_data_comb = 32'b0;                                        // write-only
      IDX_FIFO_ST : rd_data_comb = { 14'b0, tx_full, rx_empty, tx_level, rx_level };
      default     : rd_data_comb = 32'b0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Sequential state
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctrl_reg    <= 6'b0;
      int_enable  <= 10'b0;
      int_status  <= 10'b0;
      ibi_mdb_q   <= 8'b0;
      ibi_prn_q   <= 1'b0;
      ibi_plen_q  <= 8'b0;
      rdv_q       <= 1'b0;
      rdv_q2      <= 1'b0;
      rd_idx_q    <= 5'b0;
      rd_data_q   <= 32'b0;
      outstanding <= 2'b0;
    end else begin
      // --- read pipeline + scoreboard (D-2): accept -> sample (rdv_q) ->
      //     deliver (rdv_q2 / rd_data_q). Count decrements on the delivery beat. ---
      rdv_q       <= read_accept;
      if (read_accept) rd_idx_q <= tgt;
      rdv_q2      <= rdv_q;
      rd_data_q   <= rd_data_comb;
      outstanding <= outstanding + (read_accept ? 2'd1 : 2'd0)
                                 - (rdv_q2      ? 2'd1 : 2'd0);

      // --- CTRL register write ---
      if (write_accept && (tgt == IDX_CTRL) && avs_byteenable[0])
        ctrl_reg <= avs_writedata[5:0];

      // --- INT_ENABLE write ---
      if (write_accept && (tgt == IDX_INT_EN)) begin
        if (avs_byteenable[0]) int_enable[7:0] <= avs_writedata[7:0];
        if (avs_byteenable[1]) int_enable[9:8] <= avs_writedata[9:8];
      end

      // --- INT_STATUS: set from sources, W1C clear (set wins same cycle) ---
      int_status <= (int_status & ~w1c_clear) | int_src;

      // --- IBI_CTRL write (mdb spans bytes 0/1, payload_len byte 2) ---
      if (write_accept && (tgt == IDX_IBI_CTRL)) begin
        if (avs_byteenable[0]) ibi_mdb_q[2:0] <= avs_writedata[7:5];
        if (avs_byteenable[1]) begin
          ibi_mdb_q[7:3] <= avs_writedata[12:8];
          ibi_prn_q      <= avs_writedata[15];
        end
        if (avs_byteenable[2]) ibi_plen_q <= avs_writedata[23:16];
      end
    end
  end

  // ===========================================================================
  // FORMAL
  // ===========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- Environment assumptions (assume-ledger) ------------------------------
  // A-AVMM-1: Avalon master never issues read and write in the same cycle.
  always_ff @(posedge clk) if (rst_n) begin
    am_excl : assume (!(avs_read && avs_write));
  end

  // A-AVMM-2 (V2 master-hold): while waitrequest holds a command, the master
  // keeps address/read/write/writedata/byteenable stable next cycle.
  always_ff @(posedge clk)
    if (f_past_valid && rst_n && $past(rst_n) &&
        $past((avs_read || avs_write) && avs_waitrequest)) begin
      am_hold_addr : assume (avs_address    == $past(avs_address));
      am_hold_rd   : assume (avs_read       == $past(avs_read));
      am_hold_wr   : assume (avs_write      == $past(avs_write));
      am_hold_wd   : assume (avs_writedata  == $past(avs_writedata));
      am_hold_be   : assume (avs_byteenable == $past(avs_byteenable));
    end

  // ---- Combinational / single-state safety ----------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    // V6 : irq is exactly the enabled-status reduction.
    v6_irq          : assert (irq == (|(int_status & int_enable)));

    // V1 / D-2 : scoreboard invariants (two pipe stages: rdv_q sample, rdv_q2 deliver).
    v1_inv_oc       : assert (outstanding == ((rdv_q ? 2'd1 : 2'd0) +
                                              (rdv_q2 ? 2'd1 : 2'd0)));   // helper invariant (inductive)
    v1_no_overflow  : assert (outstanding <= 2'd2);
    v1_rdv_gt0      : assert (!avs_readdatavalid || (outstanding != 2'd0));
    // underflow guard: the delivery beat (a pending decrement) implies count > 0.
    v1_no_underflow : assert (!rdv_q2 || (outstanding >= 2'd1));

    // V5 : FIFO no-overrun / no-underrun.
    v5_tx_push_ok   : assert (!tx_push || !tx_full);
    v5_rx_pop_ok    : assert (!rx_pop  || !rx_empty);

    // D-3 : RX pop discipline (only on the SAMPLE beat (rdv_q) of an RX_DATA read;
    // the popped word is then registered and delivered one cycle later).
    d3_pop_rdv      : assert (!rx_pop || (rdv_q && (rd_idx_q == IDX_RX_DATA)));
    d3_pop_nonempty : assert (!rx_pop || !rx_empty);

    // V2 : command hold / back-pressure correctness for the TX_DATA path.
    v2_no_push_full : assert (!(avs_write && (tgt == IDX_TX_DATA) && tx_full) || !tx_push);
    v2_push_accept  : assert (!tx_push || (avs_write && (tgt == IDX_TX_DATA) && !tx_full));

    // V4 / D-6 : regfile writes only to RF-writable indices, never identity,
    // never on a read, with faithful byteenable (so RF can protect RO bytes).
    v4_wr_writable  : assert (!app_wr_en || rf_writable(tgt));
    v4_identity_ro  : assert (!app_wr_en || ((tgt != IDX_PID_LOW) &&
                                             (tgt != IDX_PID_HIGH) &&
                                             (tgt != IDX_IDENT)));
    v4_wr_is_write  : assert (!app_wr_en || write_accept);
    v4_wr_not_read  : assert (!app_wr_en || !avs_read);
    v4_be_forward   : assert (!app_wr_en || (app_wr_be == avs_byteenable));
    // app_rd_idx only ever points at an RF-owned register when its value is used
    // (the SAMPLE beat (rdv_q) of an RF-owned read, where rd_data_comb is captured).
    v4_rd_idx_rf    : assert (!(rdv_q && rf_readable(rd_idx_q)) ||
                              (app_rd_idx == rd_idx_q));
  end

  // ---- Multi-cycle ($past) safety -------------------------------------------
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // V1 : 2-cycle pipeline -- readdatavalid (delivery) implies the sample beat one
    // cycle earlier, and the sample beat implies an accepted read the cycle before
    // that. Chained so readdatavalid => read accepted exactly two cycles earlier.
    v1_rdv_after_rd : assert (!avs_readdatavalid || $past(rdv_q));
    v1_rdv_chain    : assert (!rdv_q             || $past(read_accept));

    // V3 : W1C - a set bit that is W1C-cleared and not re-set is 0 next cycle.
    v3_w1c_clears   : assert ((int_status &
                               $past(int_status & w1c_clear & ~int_src)) == 10'b0);
    // V3 (set side) : a source-set bit is 1 next cycle (set wins over W1C).
    v3_set_wins     : assert ((~int_status & $past(int_src)) == 10'b0);

    // V4/D-6 : AV-owned registers stable unless their own offset was written
    // (a write to any other / RO offset cannot disturb them, incl. partial be).
    v4_ctrl_stable  : assert ((ctrl_reg == $past(ctrl_reg)) ||
                              $past(write_accept && (tgt == IDX_CTRL) && avs_byteenable[0]));
    v4_inten_stable : assert ((int_enable == $past(int_enable)) ||
                              $past(write_accept && (tgt == IDX_INT_EN)));
    v4_mdb_stable   : assert ((ibi_mdb_q == $past(ibi_mdb_q)) ||
                              $past(write_accept && (tgt == IDX_IBI_CTRL)));
  end

  // ---- Cover : reachability witnesses ---------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_read_done   : cover (avs_readdatavalid);
    c_rf_write    : cover (app_wr_en);
    c_tx_push     : cover (tx_push);
    c_rx_pop      : cover (rx_pop);
    c_irq         : cover (irq);
    c_waitreq     : cover (avs_waitrequest);
    c_outstanding : cover (outstanding == 2'd1);
    c_flush       : cover (flush_rx);
    c_ibi_req     : cover (ibi_request);
  end

  // multi-cycle covers
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    // a stalled TX write that later pushes when space frees (V2 forward progress).
    c_stall_push  : cover ($past(avs_waitrequest) && tx_push);
    // an INT_STATUS bit set then cleared via W1C.
    c_w1c_clear   : cover ($past(int_status[2]) && !int_status[2]);
    // two reads completing back-to-back (pipelined throughput).
    c_b2b_read    : cover ($past(avs_readdatavalid) && avs_readdatavalid);
  end
`endif

endmodule
`endif
