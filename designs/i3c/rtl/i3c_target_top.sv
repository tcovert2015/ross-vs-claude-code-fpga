// ============================================================================
// i3c_target_top.sv  -  Device-agnostic I3C Basic v1.2 SDR+IBI Target top level
//
// Instantiates the full Target (i3c_io_altera + i3c_bus_frontend + i3c_sda_mux +
// every functional block) and wires them per docs/interfaces.md §4 (FROZEN
// connectivity map). This is the only place the single-owner SDA mux is wired
// (critique F-2) and the only place the front-end's F-3 gate sees the resolved
// sda_oe.
//
// FORMAL (integration, critique F-1/F-2):
//   * Under `FORMAL` the physical pad / i3c_io_altera is replaced by an ABSTRACT
//     wired-AND bus: the sampled SDA seen by the front-end is the open-drain
//     resolution of the Target's resolved (sda_oe,sda_o) drive and a FREE
//     controller (f_ctl_oe,f_ctl_o), with a pull-up High default. SCL is driven
//     by the controller (the Target never drives SCL, S1).
//   * Cross-cutting SAFETY asserts live here where every internal signal is
//     visible: the CONTENTION MONITOR (F-1) and the SINGLE-OWNER $onehot0 of the
//     SDA drive-request set (F-2), plus integration cross-covers.
//   * The controller environment is constrained MINIMALLY and the assumes are
//     documented at the FORMAL block (CA1..CA3 + idealized SCL edge spacing).
// ============================================================================
`ifndef I3C_TARGET_TOP_SV
`define I3C_TARGET_TOP_SV
`include "i3c_pkg.sv"

module i3c_target_top #(
  // ---- identity straps (forwarded to i3c_regfile / i3c_daa / i3c_ccc) ----
  parameter logic [7:0]  BCR            = i3c_pkg::BCR_DEFAULT,
  parameter logic [7:0]  DCR            = i3c_pkg::DCR_DEFAULT,
  parameter logic [14:0] MFG_ID         = 15'h0000,
  parameter logic        PID_TYPE       = 1'b0,
  parameter logic [31:0] PID_VAL        = 32'h0000_0000,
  // ---- config defaults / maxima ----
  parameter logic [15:0] MWL_DEFAULT    = 16'd64,
  parameter logic [15:0] MRL_DEFAULT    = 16'd64,
  parameter logic [7:0]  MAXIBI_DEFAULT = 8'd0,
  parameter logic [7:0]  GETCAP3        = i3c_pkg::GETCAP3_DEFAULT,
  parameter bit          STATIC_ADDR_EN = 1'b1,
  // ---- FIFO depths ----
  parameter int unsigned RX_DEPTH       = 8,
  parameter int unsigned TX_DEPTH       = 8,
  // ---- front-end straps ----
  parameter int unsigned SYNC_STAGES      = 2,
  parameter int unsigned BUS_FREE_CYCLES  = 2,
  parameter int unsigned BUS_AVAIL_CYCLES = 4,
  parameter int unsigned BUS_IDLE_CYCLES  = 8,
  // ---- Avalon clock domain (0 = tie avl_clk = sys_clk) ----
  parameter bit          AVL_ASYNC      = 1'b0
) (
  input  logic clk,            // sys_clk
  input  logic rst_n,          // system reset (active-low, sync de-assert)
  input  logic avl_clk,        // Avalon clock (tie = clk if AVL_ASYNC=0)
  input  logic avl_rst_n,      // Avalon reset
  // ---- Avalon-MM agent ----
  input  logic [4:0]  avs_address,
  input  logic        avs_read,
  input  logic        avs_write,
  input  logic [31:0] avs_writedata,
  input  logic [3:0]  avs_byteenable,
  output logic [31:0] avs_readdata,
  output logic        avs_readdatavalid,
  output logic        avs_waitrequest,
  output logic        irq,
  // ---- I3C pads ----
`ifdef FORMAL
  // Formal-only abstract-bus controller drivers (replace the pad in proofs).
  input  logic f_ctl_oe,       // free controller output-enable
  input  logic f_ctl_o,        // free controller value
  input  logic f_scl_drive,    // free controller-driven SCL level
`endif
  inout  wire  SDA,            // I3C SDA pad
  input  wire  SCL             // I3C SCL pad (input only; Target never drives SCL)
);

  // --------------------------------------------------------------------------
  // FIFO occupancy-pointer widths (mirror i3c_fifo's AW computation).
  // --------------------------------------------------------------------------
  localparam int unsigned RX_AW = (RX_DEPTH <= 2) ? 1 : $clog2(RX_DEPTH);
  localparam int unsigned TX_AW = (TX_DEPTH <= 2) ? 1 : $clog2(TX_DEPTH);

  // --------------------------------------------------------------------------
  // Avalon clock/reset selection (single-clock default; FORMAL ties to sys clk).
  // --------------------------------------------------------------------------
`ifdef FORMAL
  wire clk_avl  = clk;
  wire rstn_avl = rst_n;
`else
  wire clk_avl  = AVL_ASYNC ? avl_clk   : clk;
  wire rstn_avl = AVL_ASYNC ? avl_rst_n : rst_n;
`endif

  // ==========================================================================
  // Inter-module nets (grouped by producing instance)
  // ==========================================================================
  // ---- i3c_sda_mux resolved drive ----
  logic        sda_oe, sda_o;

  // ---- i3c_io_altera / abstract-bus sampled lines ----
  logic        io_sda_i, io_scl_i;
  logic        fe_sda_i, fe_scl_i;

  // ---- i3c_bus_frontend ----
  logic fe_sda_sync, fe_scl_sync;
  logic fe_scl_rising, fe_scl_falling, fe_sda_rising, fe_sda_falling;
  logic fe_start_stb, fe_rstart_stb, fe_stop_stb;
  logic fe_bus_busy, fe_bus_free, fe_bus_available, fe_bus_idle;

  // ---- i3c_bit_engine ----
  logic [7:0] be_rx_byte;
  logic [3:0] be_bit_cnt;
  logic       be_byte_done, be_sda_bit, be_rdata_oe, be_rdata_o;

  // ---- i3c_framer ----
  logic fr_ninth_slot, fr_ack_slot, fr_tbit_slot;
  logic fr_parity_ok, fr_parity_err, fr_t_drive_val, fr_read_abort;
  logic fr_tbit_oe, fr_tbit_o;

  // ---- i3c_protocol_fsm ----
  logic [1:0]  pf_phase;
  logic        pf_state_idle, pf_state_ignore, pf_match_7e, pf_match_da;
  logic        pf_is_broadcast, pf_is_read, pf_addr_capture_armed, pf_post_rstart;
  logic        pf_ack_oe, pf_ack_o, pf_tx_load;
  logic [7:0]  pf_tx_byte_out;
  logic        pf_tx_drive_en, pf_more_read_data, pf_tx_pop, pf_rx_push;
  logic [10:0] pf_rx_wdata;
  logic        pf_to_ccc, pf_priv_write_done, pf_priv_read_req;

  // ---- i3c_daa ----
  logic [6:0] daa_dyn_addr;
  logic       daa_da_valid, daa_active, daa_done;
  logic       daa_oe, daa_o, daa_arb_lost, daa_par_err, daa_te4_event;
  logic       daa_rxda_enter;

  // ---- i3c_ccc ----
  logic [7:0]  ccc_code;
  logic        ccc_is_direct, ccc_supported, ccc_ack, ccc_getstatus_seg;
  logic        ccc_resp_valid;
  logic [7:0]  ccc_resp_byte;
  logic        ccc_resp_last, ccc_enthdr_seen;
  logic        ccc_entdaa_start, ccc_entdaa_active, ccc_rstdaa;
  logic        ccc_setdasa_load, ccc_setaasa_load, ccc_setnewda_load;
  logic [6:0]  ccc_load_addr;
  logic        ccc_set_mwl;   logic [15:0] ccc_mwl_val;
  logic        ccc_set_mrl;   logic [15:0] ccc_mrl_val;
  logic        ccc_set_maxibi; logic [7:0] ccc_maxibi_val;
  logic        ccc_ibi_en_set, ccc_ibi_en_clr, ccc_set_rstact;
  logic [7:0]  ccc_rstact_val;
  logic        ccc_getstatus_rd, ccc_code_parity_err, ccc_illegal_format, ccc_event;

  // ---- i3c_ibi ----
  logic       ibi_oe, ibi_o, ibi_pl_pop, ibi_active, ibi_busy;
  logic       ibi_acked, ibi_nacked, ibi_arb_lost, ibi_deferred, ibi_done;
  logic [6:0] ibi_addr;

  // ---- i3c_error_recovery ----
  logic       err_in_error, err_err_recoverable, err_ack_inhibit;
  logic       err_drive_inhibit, err_proto_err_set;
  logic [3:0] err_te_code;

  // ---- i3c_hdr_exit_detector ----
  logic hdr_exit_detected, hdr_trp_body_valid, hdr_trp_trigger;

  // ---- i3c_regfile ----
  logic [7:0]  rf_bcr, rf_dcr;
  logic [47:0] rf_pid;
  logic [15:0] rf_mwl, rf_mrl;
  logic [7:0]  rf_max_ibi_payload;
  logic        rf_ibi_en;
  logic [15:0] rf_getstatus_word;
  logic [31:0] rf_getcaps;
  logic [1:0]  rf_reset_action;
  logic        rf_escalation_armed, rf_last_reset_was_whole, rf_proto_err_seen;
  logic [31:0] rf_app_rd_data;

  // ---- i3c_avalon_mm ----
  logic        av_app_wr_en;
  logic [4:0]  av_app_wr_idx;
  logic [31:0] av_app_wr_data;
  logic [3:0]  av_app_wr_be;
  logic [4:0]  av_app_rd_idx;
  logic        av_rx_pop, av_tx_push;
  logic [8:0]  av_tx_wr_data;
  logic        av_flush_rx, av_flush_tx, av_ibi_request;
  logic [7:0]  av_mdb;
  logic        av_mdb_is_prn;
  logic        av_core_en, av_accept_en, av_ibi_en_app, av_soft_reset;
  logic        av_static_addr_en, av_prn_send_en;

  // ---- FIFOs ----
  logic            rxf_full, rxf_empty, rxf_overflow;
  logic [RX_AW:0]  rxf_wr_level, rxf_rd_level;
  logic [10:0]     rxf_rd_data;
  logic            txf_full, txf_empty, txf_overflow;
  logic [TX_AW:0]  txf_wr_level, txf_rd_level;
  logic [8:0]      txf_rd_data;

  // ---- reset-escalation glue (u_rstgen, N-10) ----
  logic rg_periph_reset, rg_whole_reset;

  // ==========================================================================
  // Reset-escalation glue (small always-on combinational logic inside top)
  //   trp_trigger fires a Target Reset whose scope follows the configured action:
  //     reset_action==2 (whole)               -> whole reset
  //     escalation_armed && action!=0         -> escalate peripheral -> whole
  //     otherwise                             -> peripheral reset
  //   soft_reset (CTRL[3]) requests a peripheral reset.
  // ==========================================================================
  always_comb begin
    rg_whole_reset  = hdr_trp_trigger &&
                      ((rf_reset_action == 2'd2) ||
                       (rf_escalation_armed && (rf_reset_action != 2'd0)));
    rg_periph_reset = (hdr_trp_trigger && !rg_whole_reset) || av_soft_reset;
  end

  // ==========================================================================
  // SDA single-owner mux (critique F-2). drive_inhibit (S3) masks all sources.
  // ==========================================================================
  logic [i3c_pkg::SDA_NSRC-1:0] src_oe, src_o;
  always_comb begin
    src_oe = '0;
    src_o  = '0;
    src_oe[i3c_pkg::SDA_ACK]   = pf_ack_oe;    src_o[i3c_pkg::SDA_ACK]   = pf_ack_o;
    src_oe[i3c_pkg::SDA_TBIT]  = fr_tbit_oe;   src_o[i3c_pkg::SDA_TBIT]  = fr_tbit_o;
    src_oe[i3c_pkg::SDA_RDATA] = be_rdata_oe;  src_o[i3c_pkg::SDA_RDATA] = be_rdata_o;
    src_oe[i3c_pkg::SDA_DAA]   = daa_oe;       src_o[i3c_pkg::SDA_DAA]   = daa_o;
    src_oe[i3c_pkg::SDA_IBI]   = ibi_oe;       src_o[i3c_pkg::SDA_IBI]   = ibi_o;
    // SDA_DBG tied off (0/0).
    if (err_drive_inhibit) src_oe = '0;        // S3: forbid any SDA drive
  end

  i3c_sda_mux #(.N(i3c_pkg::SDA_NSRC)) u_sda_mux (
    .clk    (clk),
    .rst_n  (rst_n),
    .src_oe (src_oe),
    .src_o  (src_o),
    .sda_oe (sda_oe),
    .sda_o  (sda_o)
  );

  // --------------------------------------------------------------------------
  // F-3 gate loop-break (top-level adapter, ADAPT-1).
  //   The frozen netlist feeds the front-end's F-3 gate with the COMBINATIONAL
  //   mux `sda_oe`. That closes a 0-delay loop:
  //     sda_oe -> u_fe.bus_ctrl(~sda_oe) -> rstart_stb -> u_framer.tbit_oe
  //            -> src_oe[SDA_TBIT] -> sda_oe.
  //   We register `sda_oe` one cycle before the gate. This is SAFE for F-3
  //   because the Target's own SDA edge only reaches `sda_sync` after
  //   SYNC_STAGES(>=2) flops, i.e. strictly later than the 1-cycle gate delay,
  //   so the gate is always asserted by the time the self-driven edge could be
  //   sampled. (Requires SYNC_STAGES >= 2; the v1 profile uses 2.)
  // --------------------------------------------------------------------------
  logic sda_oe_gate;
  always_ff @(posedge clk) begin
    if (!rst_n) sda_oe_gate <= 1'b0;
    else        sda_oe_gate <= sda_oe;
  end

  // ==========================================================================
  // Pad IO / abstract bus
  // ==========================================================================
`ifdef FORMAL
  // Abstract wired-AND bus (open-drain, pull-up High). The resolved sampled SDA
  // is Low iff the Target or the controller pulls it Low; push-pull High shows up
  // through the inverse. (Valid only in the no-contention states the monitor
  // proves; contention itself is flagged by a_contention below.)
  assign fe_sda_i = ~((sda_oe & ~sda_o) | (f_ctl_oe & ~f_ctl_o));
  assign fe_scl_i = f_scl_drive;            // controller drives SCL; Target never does
  assign io_sda_i = 1'b1;                    // unused under FORMAL
  assign io_scl_i = 1'b1;
`else
  i3c_io_altera u_io (
    .sda_oe (sda_oe),
    .sda_o  (sda_o),
    .sda_i  (io_sda_i),
    .scl_i  (io_scl_i),
    .SDA    (SDA),
    .SCL    (SCL)
  );
  assign fe_sda_i = io_sda_i;
  assign fe_scl_i = io_scl_i;
`endif

  // ==========================================================================
  // Bus front-end (sync, edges, START/STOP/Sr, timers). F-3 gate = resolved sda_oe.
  // ==========================================================================
  i3c_bus_frontend #(
    .SYNC_STAGES      (SYNC_STAGES),
    .BUS_FREE_CYCLES  (BUS_FREE_CYCLES),
    .BUS_AVAIL_CYCLES (BUS_AVAIL_CYCLES),
    .BUS_IDLE_CYCLES  (BUS_IDLE_CYCLES)
  ) u_fe (
    .clk           (clk),
    .rst_n         (rst_n),
    .sda_i         (fe_sda_i),
    .scl_i         (fe_scl_i),
    .sda_oe        (sda_oe_gate),          // F-3 gate (registered; ADAPT-1)
    .sda_sync      (fe_sda_sync),
    .scl_sync      (fe_scl_sync),
    .scl_rising    (fe_scl_rising),
    .scl_falling   (fe_scl_falling),
    .sda_rising    (fe_sda_rising),
    .sda_falling   (fe_sda_falling),
    .start_stb     (fe_start_stb),
    .rstart_stb    (fe_rstart_stb),
    .stop_stb      (fe_stop_stb),
    .bus_busy      (fe_bus_busy),
    .bus_free      (fe_bus_free),
    .bus_available (fe_bus_available),
    .bus_idle      (fe_bus_idle)
  );

  // ==========================================================================
  // Bit engine
  // ==========================================================================
  i3c_bit_engine u_be (
    .clk         (clk),
    .rst_n       (rst_n),
    .sda_sync    (fe_sda_sync),
    .scl_rising  (fe_scl_rising),
    .scl_falling (fe_scl_falling),
    .start_stb   (fe_start_stb),
    .rstart_stb  (fe_rstart_stb),
    .bit_resync  (daa_rxda_enter),
    .tx_load     (pf_tx_load),
    .tx_byte     (pf_tx_byte_out),
    .tx_drive_en (pf_tx_drive_en),
    .rx_byte     (be_rx_byte),
    .bit_cnt     (be_bit_cnt),
    .byte_done   (be_byte_done),
    .sda_bit     (be_sda_bit),
    .rdata_oe    (be_rdata_oe),
    .rdata_o     (be_rdata_o)
  );

  // ==========================================================================
  // Framer (9th-bit T/ACK, write parity, read T-bit)
  // ==========================================================================
  i3c_framer u_framer (
    .clk            (clk),
    .rst_n          (rst_n),
    .phase          (pf_phase),
    .is_read        (pf_is_read),
    .more_read_data (pf_more_read_data),
    .rx_byte        (be_rx_byte),
    .sda_bit        (be_sda_bit),
    .byte_done      (be_byte_done),
    .scl_rising     (fe_scl_rising),
    .scl_falling    (fe_scl_falling),
    .rstart_stb     (fe_rstart_stb),
    .ninth_slot     (fr_ninth_slot),
    .ack_slot       (fr_ack_slot),
    .tbit_slot      (fr_tbit_slot),
    .parity_ok      (fr_parity_ok),
    .parity_err     (fr_parity_err),
    .t_drive_val    (fr_t_drive_val),
    .read_abort     (fr_read_abort),
    .tbit_oe        (fr_tbit_oe),
    .tbit_o         (fr_tbit_o)
  );

  // ==========================================================================
  // Protocol FSM
  // ==========================================================================
  i3c_protocol_fsm u_pfsm (
    .clk               (clk),
    .rst_n             (rst_n),
    .start_stb         (fe_start_stb),
    .rstart_stb        (fe_rstart_stb),
    .stop_stb          (fe_stop_stb),
    .scl_rising        (fe_scl_rising),
    .scl_falling       (fe_scl_falling),
    .bus_available     (fe_bus_available),
    .rx_byte           (be_rx_byte),
    .byte_done         (be_byte_done),
    .bit_cnt           (be_bit_cnt),
    .ack_slot          (fr_ack_slot),
    .tbit_slot         (fr_tbit_slot),
    .ninth_slot        (fr_ninth_slot),
    .parity_err        (fr_parity_err),
    .read_abort        (fr_read_abort),
    .da_valid          (daa_da_valid),
    .dyn_addr          (daa_dyn_addr),
    .daa_active        (daa_active),
    .accept_en         (av_accept_en),
    .core_en           (av_core_en),
    .rx_can_accept     (~rxf_full),
    .ccc_ack           (ccc_ack),
    .ccc_getstatus_seg (ccc_getstatus_seg),
    .ccc_resp_valid    (ccc_resp_valid),
    .ccc_resp_byte     (ccc_resp_byte),
    .ccc_resp_last     (ccc_resp_last),
    .tx_empty          (txf_empty),
    .tx_byte           (txf_rd_data[i3c_pkg::TXF_DATA_LSB +: 8]),
    .tx_last           (txf_rd_data[i3c_pkg::TXF_LAST]),
    .in_error          (err_in_error),
    .ack_inhibit       (err_ack_inhibit),
    .in_hdr_quiesce    (ccc_enthdr_seen),
    .phase             (pf_phase),
    .state_idle        (pf_state_idle),
    .state_ignore      (pf_state_ignore),
    .match_7e          (pf_match_7e),
    .match_da          (pf_match_da),
    .is_broadcast      (pf_is_broadcast),
    .is_read           (pf_is_read),
    .addr_capture_armed(pf_addr_capture_armed),
    .post_rstart       (pf_post_rstart),
    .ack_oe            (pf_ack_oe),
    .ack_o             (pf_ack_o),
    .tx_load           (pf_tx_load),
    .tx_byte_out       (pf_tx_byte_out),
    .tx_drive_en       (pf_tx_drive_en),
    .more_read_data    (pf_more_read_data),
    .tx_pop            (pf_tx_pop),
    .rx_push           (pf_rx_push),
    .rx_wdata          (pf_rx_wdata),
    .to_ccc            (pf_to_ccc),
    .priv_write_done   (pf_priv_write_done),
    .priv_read_req     (pf_priv_read_req)
  );

  // ==========================================================================
  // DAA (owns dyn_addr/da_valid)
  // ==========================================================================
  i3c_daa #(.STATIC_ADDR_EN(STATIC_ADDR_EN)) u_daa (
    .clk           (clk),
    .rst_n         (rst_n),
    .scl_rising    (fe_scl_rising),
    .scl_falling   (fe_scl_falling),
    .sda_sync      (fe_sda_sync),
    .start_stb     (fe_start_stb),
    .rstart_stb    (fe_rstart_stb),
    .stop_stb      (fe_stop_stb),
    .bit_cnt       (be_bit_cnt),
    .byte_done     (be_byte_done),
    .rx_byte       (be_rx_byte),
    .pid           (rf_pid),
    .bcr           (rf_bcr),
    .dcr           (rf_dcr),
    .entdaa_start  (ccc_entdaa_start),
    .entdaa_active (ccc_entdaa_active),
    .rstdaa        (ccc_rstdaa),
    .setdasa_load  (ccc_setdasa_load),
    .setaasa_load  (ccc_setaasa_load),
    .setnewda_load (ccc_setnewda_load),
    .load_addr     (ccc_load_addr),
    .whole_reset   (rg_whole_reset),
    .dyn_addr      (daa_dyn_addr),
    .da_valid      (daa_da_valid),
    .daa_active    (daa_active),
    .daa_done      (daa_done),
    .daa_oe        (daa_oe),
    .daa_o         (daa_o),
    .arb_lost      (daa_arb_lost),
    .par_err       (daa_par_err),
    .te4_event     (daa_te4_event),
    .rxda_enter    (daa_rxda_enter)
  );

  // ==========================================================================
  // CCC decode + handlers
  // ==========================================================================
  i3c_ccc #(.STATIC_ADDR_EN(STATIC_ADDR_EN)) u_ccc (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start_stb           (fe_start_stb),
    .rstart_stb          (fe_rstart_stb),
    .stop_stb            (fe_stop_stb),
    .scl_rising          (fe_scl_rising),
    .scl_falling         (fe_scl_falling),
    .rx_byte             (be_rx_byte),
    .byte_done           (be_byte_done),
    .bit_cnt             (be_bit_cnt),
    .phase               (pf_phase),
    .ninth_slot          (fr_ninth_slot),
    .ack_slot            (fr_ack_slot),
    .match_7e            (pf_match_7e),
    .match_da            (pf_match_da),
    .is_broadcast        (pf_is_broadcast),
    .is_read             (pf_is_read),
    .da_valid            (daa_da_valid),
    .bcr                 (rf_bcr),
    .dcr                 (rf_dcr),
    .pid                 (rf_pid),
    .mwl                 (rf_mwl),
    .mrl                 (rf_mrl),
    .max_ibi_payload     (rf_max_ibi_payload),
    .getstatus_word      (rf_getstatus_word),
    .getcaps             (rf_getcaps),
    .ccc_code            (ccc_code),
    .ccc_is_direct       (ccc_is_direct),
    .ccc_supported       (ccc_supported),
    .ccc_ack             (ccc_ack),
    .ccc_getstatus_seg   (ccc_getstatus_seg),
    .ccc_resp_valid      (ccc_resp_valid),
    .ccc_resp_byte       (ccc_resp_byte),
    .ccc_resp_last       (ccc_resp_last),
    .enthdr_seen         (ccc_enthdr_seen),
    .entdaa_start        (ccc_entdaa_start),
    .entdaa_active       (ccc_entdaa_active),
    .rstdaa              (ccc_rstdaa),
    .setdasa_load        (ccc_setdasa_load),
    .setaasa_load        (ccc_setaasa_load),
    .setnewda_load       (ccc_setnewda_load),
    .load_addr           (ccc_load_addr),
    .ccc_set_mwl         (ccc_set_mwl),
    .ccc_mwl_val         (ccc_mwl_val),
    .ccc_set_mrl         (ccc_set_mrl),
    .ccc_mrl_val         (ccc_mrl_val),
    .ccc_set_maxibi      (ccc_set_maxibi),
    .ccc_maxibi_val      (ccc_maxibi_val),
    .ccc_ibi_en_set      (ccc_ibi_en_set),
    .ccc_ibi_en_clr      (ccc_ibi_en_clr),
    .ccc_set_rstact      (ccc_set_rstact),
    .ccc_rstact_val      (ccc_rstact_val),
    .getstatus_rd        (ccc_getstatus_rd),
    .ccc_code_parity_err (ccc_code_parity_err),
    .ccc_illegal_format  (ccc_illegal_format),
    .ccc_event           (ccc_event)
  );

  // ==========================================================================
  // IBI engine. TX FIFO read port is shared (N-5): payload bytes share the head.
  // ==========================================================================
  i3c_ibi u_ibi (
    .clk             (clk),
    .rst_n           (rst_n),
    .scl_rising      (fe_scl_rising),
    .scl_falling     (fe_scl_falling),
    .sda_sync        (fe_sda_sync),
    .start_stb       (fe_start_stb),
    .rstart_stb      (fe_rstart_stb),
    .stop_stb        (fe_stop_stb),
    .bus_available   (fe_bus_available),
    .post_rstart     (pf_post_rstart),
    .dyn_addr        (daa_dyn_addr),
    .da_valid        (daa_da_valid),
    .bcr             (rf_bcr),
    .ibi_en          (rf_ibi_en),
    .ibi_en_app      (av_ibi_en_app),
    .ibi_request     (av_ibi_request),
    .mdb             (av_mdb),
    .mdb_is_prn      (av_mdb_is_prn),
    .max_ibi_payload (rf_max_ibi_payload),
    .pl_byte         (txf_rd_data[i3c_pkg::TXF_DATA_LSB +: 8]),
    .pl_valid        (~txf_empty),
    .pl_last         (txf_rd_data[i3c_pkg::TXF_LAST]),
    .ibi_oe          (ibi_oe),
    .ibi_o           (ibi_o),
    .pl_pop          (ibi_pl_pop),
    .ibi_active      (ibi_active),
    .ibi_busy        (ibi_busy),
    .ibi_acked       (ibi_acked),
    .ibi_nacked      (ibi_nacked),
    .ibi_arb_lost    (ibi_arb_lost),
    .ibi_deferred    (ibi_deferred),
    .ibi_done        (ibi_done),
    .ibi_addr        (ibi_addr)
  );

  // ==========================================================================
  // Error recovery (TE0..TE6 + recovery FSM)
  // ==========================================================================
  i3c_error_recovery u_err (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start_stb           (fe_start_stb),
    .rstart_stb          (fe_rstart_stb),
    .stop_stb            (fe_stop_stb),
    .scl_rising          (fe_scl_rising),
    .scl_falling         (fe_scl_falling),
    .rx_byte             (be_rx_byte),
    .byte_done           (be_byte_done),
    .phase               (pf_phase),
    .match_7e            (pf_match_7e),
    .match_da            (pf_match_da),
    .is_read             (pf_is_read),
    .da_valid            (daa_da_valid),
    .daa_active          (daa_active),
    .parity_err          (fr_parity_err),
    .par_err             (daa_par_err),
    .te4_event           (daa_te4_event),
    .ccc_code_parity_err (ccc_code_parity_err),
    .ccc_illegal_format  (ccc_illegal_format),
    .ccc_supported       (ccc_supported),
    .hdr_exit_detected   (hdr_exit_detected),
    .in_error            (err_in_error),
    .err_recoverable     (err_err_recoverable),
    .ack_inhibit         (err_ack_inhibit),
    .drive_inhibit       (err_drive_inhibit),
    .proto_err_set       (err_proto_err_set),
    .te_code             (err_te_code)
  );

  // ==========================================================================
  // HDR-Exit / Target-Reset-Pattern detector
  // ==========================================================================
  i3c_hdr_exit_detector u_hdr (
    .clk               (clk),
    .rst_n             (rst_n),
    .sda_sync          (fe_sda_sync),
    .scl_sync          (fe_scl_sync),
    .sda_falling       (fe_sda_falling),
    .sda_rising        (fe_sda_rising),
    .rstart_stb        (fe_rstart_stb),
    .stop_stb          (fe_stop_stb),
    .exit_en           (err_err_recoverable | ccc_enthdr_seen),
    .hdr_exit_detected (hdr_exit_detected),
    .trp_body_valid    (hdr_trp_body_valid),
    .trp_trigger       (hdr_trp_trigger)
  );

  // ==========================================================================
  // Register file (identity + config + status + reset-action)
  //   pending_irq / activity_mode: see open-issue OI-1 (i3c_avalon_mm exposes no
  //   output for them) -> tied 0 at top.
  // ==========================================================================
  i3c_regfile #(
    .BCR            (BCR),
    .DCR            (DCR),
    .MFG_ID         (MFG_ID),
    .PID_TYPE       (PID_TYPE),
    .PID_VAL        (PID_VAL),
    .MWL_DEFAULT    (MWL_DEFAULT),
    .MRL_DEFAULT    (MRL_DEFAULT),
    .MAXIBI_DEFAULT (MAXIBI_DEFAULT),
    .GETCAP3        (GETCAP3)
  ) u_rf (
    .clk              (clk),
    .rst_n            (rst_n),
    .bcr              (rf_bcr),
    .dcr              (rf_dcr),
    .pid              (rf_pid),
    .mwl              (rf_mwl),
    .mrl              (rf_mrl),
    .max_ibi_payload  (rf_max_ibi_payload),
    .ibi_en           (rf_ibi_en),
    .getstatus_word   (rf_getstatus_word),
    .getcaps          (rf_getcaps),
    .reset_action     (rf_reset_action),
    .escalation_armed (rf_escalation_armed),
    .last_reset_was_whole (rf_last_reset_was_whole),
    .proto_err_seen   (rf_proto_err_seen),
    .ccc_set_mwl      (ccc_set_mwl),
    .ccc_mwl_val      (ccc_mwl_val),
    .ccc_set_mrl      (ccc_set_mrl),
    .ccc_mrl_val      (ccc_mrl_val),
    .ccc_set_maxibi   (ccc_set_maxibi),
    .ccc_maxibi_val   (ccc_maxibi_val),
    .ccc_ibi_en_set   (ccc_ibi_en_set),
    .ccc_ibi_en_clr   (ccc_ibi_en_clr),
    .ccc_set_rstact   (ccc_set_rstact),
    .ccc_rstact_val   (ccc_rstact_val),
    .getstatus_rd     (ccc_getstatus_rd),
    .proto_err_set    (err_proto_err_set),
    .pending_irq      (4'h0),                 // OI-1: no AV source
    .activity_mode    (2'h0),                 // OI-1: no AV source
    .trp_trigger      (hdr_trp_trigger),
    .start_clr        (fe_start_stb),
    .periph_reset     (rg_periph_reset),
    .whole_reset      (rg_whole_reset),
    .app_wr_en        (av_app_wr_en),
    .app_wr_idx       (av_app_wr_idx),
    .app_wr_data      (av_app_wr_data),
    .app_wr_be        (av_app_wr_be),
    .app_rd_idx       (av_app_rd_idx),
    .app_rd_data      (rf_app_rd_data)
  );

  // ==========================================================================
  // RX FIFO (bus -> app). wr side = sys (protocol FSM); rd side = avl (Avalon).
  // ==========================================================================
  i3c_fifo #(
    .DW    (i3c_pkg::RX_FIFO_W),
    .DEPTH (RX_DEPTH),
    .ASYNC (1'b0)
  ) u_rxfifo (
    .wr_clk   (clk),
    .wr_rst_n (rst_n),
    .wr_en    (pf_rx_push),
    .wr_data  (pf_rx_wdata),
    .clear    (av_flush_rx),
    .full     (rxf_full),
    .wr_level (rxf_wr_level),
    .overflow (rxf_overflow),
    .rd_clk   (clk_avl),
    .rd_rst_n (rstn_avl),
    .rd_en    (av_rx_pop),
    .rd_data  (rxf_rd_data),
    .empty    (rxf_empty),
    .rd_level (rxf_rd_level)
  );

  // ==========================================================================
  // TX FIFO (app -> bus). wr side = avl (Avalon); rd side = sys, shared (N-5):
  //   private-read pop (pf_tx_pop) OR IBI payload pop (ibi_pl_pop) -> rd_en.
  // ==========================================================================
  i3c_fifo #(
    .DW    (i3c_pkg::TX_FIFO_W),
    .DEPTH (TX_DEPTH),
    .ASYNC (1'b0)
  ) u_txfifo (
    .wr_clk   (clk_avl),
    .wr_rst_n (rstn_avl),
    .wr_en    (av_tx_push),
    .wr_data  (av_tx_wr_data),
    .clear    (av_flush_tx),
    .full     (txf_full),
    .wr_level (txf_wr_level),
    .overflow (txf_overflow),
    .rd_clk   (clk),
    .rd_rst_n (rst_n),
    .rd_en    (pf_tx_pop | ibi_pl_pop),
    .rd_data  (txf_rd_data),
    .empty    (txf_empty),
    .rd_level (txf_rd_level)
  );

  // ==========================================================================
  // Avalon-MM bridge. Level outputs zero-extended into the 8-bit status fields.
  // ==========================================================================
  logic [7:0] rx_level8, tx_level8;
  assign rx_level8 = rxf_rd_level;          // zero-extend
  assign tx_level8 = txf_wr_level;          // zero-extend

  i3c_avalon_mm #(.AW(5)) u_av (
    .clk                 (clk_avl),
    .rst_n               (rstn_avl),
    .avs_address         (avs_address),
    .avs_read            (avs_read),
    .avs_write           (avs_write),
    .avs_writedata       (avs_writedata),
    .avs_byteenable      (avs_byteenable),
    .avs_readdata        (avs_readdata),
    .avs_readdatavalid   (avs_readdatavalid),
    .avs_waitrequest     (avs_waitrequest),
    .irq                 (irq),
    .app_wr_en           (av_app_wr_en),
    .app_wr_idx          (av_app_wr_idx),
    .app_wr_data         (av_app_wr_data),
    .app_wr_be           (av_app_wr_be),
    .app_rd_idx          (av_app_rd_idx),
    .app_rd_data         (rf_app_rd_data),
    .rx_rd_data          (rxf_rd_data),
    .rx_empty            (rxf_empty),
    .rx_level            (rx_level8),
    .rx_overflow         (rxf_overflow),
    .rx_pop              (av_rx_pop),
    .tx_full             (txf_full),
    .tx_level            (tx_level8),
    .tx_push             (av_tx_push),
    .tx_wr_data          (av_tx_wr_data),
    .flush_rx            (av_flush_rx),
    .flush_tx            (av_flush_tx),
    .ibi_request         (av_ibi_request),
    .mdb                 (av_mdb),
    .mdb_is_prn          (av_mdb_is_prn),
    .ibi_busy            (ibi_busy),
    .ibi_acked           (ibi_acked),
    .ibi_nacked          (ibi_nacked),
    .ibi_deferred        (ibi_deferred),
    .ibi_arb_lost        (ibi_arb_lost),
    .core_en             (av_core_en),
    .accept_en           (av_accept_en),
    .ibi_en_app          (av_ibi_en_app),
    .soft_reset          (av_soft_reset),
    .static_addr_en      (av_static_addr_en),
    .prn_send_en         (av_prn_send_en),
    .da_valid            (daa_da_valid),
    .dyn_addr            (daa_dyn_addr),
    .in_hdr_quiesce      (ccc_enthdr_seen),
    .in_error            (err_in_error),
    .bus_busy            (fe_bus_busy),
    .bus_free            (fe_bus_free),
    .bus_available       (fe_bus_available),
    .bus_idle            (fe_bus_idle),
    .te_code             (err_te_code),
    .proto_err_seen      (rf_proto_err_seen),
    .int_rx_ready        (~rxf_empty),
    .int_tx_space        (~txf_full),
    .int_priv_write_done (pf_priv_write_done),
    .int_priv_read_req   (pf_priv_read_req),
    .int_ibi_done        (ibi_done),
    .int_ibi_nacked      (ibi_nacked),
    .int_da_changed      (daa_done),
    .int_periph_reset    (rg_periph_reset),
    .int_proto_err       (err_proto_err_set),
    .int_ccc_event       (ccc_event)
  );

  // ==========================================================================
  // Cross-cutting integration formal properties (critique F-1 / F-2)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // ---- raw SDA drive-request set (BEFORE the drive_inhibit mask) ------------
  wire [4:0] f_src_req = { ibi_oe, daa_oe, be_rdata_oe, fr_tbit_oe, pf_ack_oe };

  // ---- idealized SCL edge spacing: controller holds SCL >= 2 cycles ---------
  // (mirrors the standalone "edges >= K cycles apart" assume; discharged by D-1
  //  / STA + sim. Without it the integrated front-end could emit edges closer
  //  than any module's standalone proof assumed.)
  reg       f_scl_q;
  reg [1:0] f_scl_dwell;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      f_scl_q     <= 1'b1;
      f_scl_dwell <= 2'd0;
    end else begin
      f_scl_q <= f_scl_drive;
      if (f_scl_drive != f_scl_q) f_scl_dwell <= 2'd0;
      else if (~&f_scl_dwell)     f_scl_dwell <= f_scl_dwell + 2'd1;
    end
  end

  // ---- controller env (MINIMAL, documented) --------------------------------
  // The Target drives push-pull HIGH only in legal windows: read data / read
  // T-bit (tgt_read_pp) and an active IBI (open-drain arb + push-pull MDB).
  wire tgt_read_pp = be_rdata_oe | fr_tbit_oe;
  wire tgt_od_low  = sda_oe & ~sda_o;       // Target pulling Low (open-drain)

  always_ff @(posedge clk) if (rst_n) begin
    // SCL is held stable >= 2 cycles between toggles (idealized edges).
    am_scl_dwell : assume (f_scl_drive == f_scl_q || f_scl_dwell >= 2'd2);
    // CA1: a legal Controller releases SDA during the Target's push-pull read.
    am_ca1 : assume (!tgt_read_pp || !f_ctl_oe);
    // CA2: during an active IBI the Target owns SDA; the Controller is released.
    am_ca2 : assume (!ibi_active  || !f_ctl_oe);
    // CA3: a legal Controller never hard-drives HIGH while the Target pulls Low
    //      (open-drain phases: ACK / ENTDAA payload / IBI arbitration).
    am_ca3 : assume (!tgt_od_low  || !(f_ctl_oe && f_ctl_o));
  end

  // ---- SAFETY -------------------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    // F-2: at most one internal block requests the SDA drive (single owner).
    a_single_owner : assert ($onehot0(f_src_req));
    // F-1: no bus contention - Target and Controller never drive opposite values.
    a_contention   : assert (!(sda_oe && f_ctl_oe && (sda_o != f_ctl_o)));
    // Open-drain discipline: ENTDAA never push-pull-drives High (daa_o tied 0).
    a_daa_od       : assert (!daa_oe || !daa_o);
    // ACK is open-drain drive-Low only (never push-pull High).
    a_ack_od       : assert (!pf_ack_oe || !pf_ack_o);
    // F-3 at top: while the Target's drive is in effect at the front-end's gate, the
    // front-end reports no bus condition. The gate is REGISTERED (sda_oe_gate, ADAPT-1 --
    // a deliberate combinational-loop break: fr_tbit_oe depends on rstart_stb, so a
    // combinational gate on the resolved sda_oe would form sda_oe -> gate -> rstart_stb
    // -> fr_tbit_oe -> sda_oe). The Target's own drive edge reaches the detector only
    // AFTER the SYNC_STAGES synchronizer (>= 2 cyc), by which time sda_oe_gate is already
    // asserted, so a self-driven edge is always suppressed. Asserting against the resolved
    // (combinational) sda_oe instead is off by that one registration cycle and is NOT a
    // real F-3 guarantee (it can spuriously coincide with a controller-formed condition).
    a_f3_top       : assert (!sda_oe_gate || !(fe_start_stb || fe_rstart_stb || fe_stop_stb));
  end

  // ---- cross-covers (integration-reachable witnesses; non-vacuity evidence) -
  always_ff @(posedge clk) if (rst_n) begin
    // an Avalon CTRL write reaches the core enable (app -> core control path)
    c_core_en   : cover (av_core_en);
    // a complete bus frame is recognized by the front-end (START..STOP)
    c_frame     : cover (fe_stop_stb);
    // the 7E I3C broadcast address is matched (front-end -> bit engine -> PFSM)
    c_match_7e  : cover (pf_match_7e);
    // single-owner SDA drive actually occurs: the Target drives the address ACK
    // (exclusive owner SDA_ACK) -> exercises the F-2 $onehot0 path non-vacuously
    c_own_ack   : cover (f_src_req == 5'b00001);
    // a CCC byte traverses the full bus->RX datapath
    //   (front-end -> bit engine -> framer -> PFSM -> RX FIFO push)
    c_cccwr_rx  : cover (pf_rx_push &&  pf_rx_wdata[i3c_pkg::RXF_IS_CCC]);
    // NOTE (OI-INTEG-COV): the private-write/read, IBI-arbitration, DAA-payload
    // and read-T-bit owner covers all require a previously-ASSIGNED Dynamic
    // Address (a completed ENTDAA / SETDASA round, hundreds of cycles), which is
    // beyond a practical integration-BMC depth. Those datapaths are witnessed by
    // the per-module cover proofs (i3c_daa_cover / i3c_ibi_cover /
    // i3c_protocol_fsm_cover). Examples kept for reference:
    //   cover (pf_rx_push && !pf_rx_wdata[i3c_pkg::RXF_IS_CCC]);  // private write -> RX
    //   cover (ibi_active && ibi_oe);                             // IBI -> arbitration
  end
`endif

endmodule
`endif
