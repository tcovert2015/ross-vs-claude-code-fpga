// scope_csr — register file on the native CSR bus (capture domain).
//
// Normative register map: docs/INTERFACES.md "CSR map — v1 FROZEN" (offsets mirrored in
// rtl/scope_pkg.sv). Three masters share this one bus contract: the drain engine (issue #8),
// scope_avalon and scope_axil (issue #11).
//
// Native CSR bus (INTERFACES.md v1):
//   * word-addressed (csr_addr[7:0] = word index; host byte offset = 4*index), 32-bit data;
//   * zero wait states: csr_rdata is COMBINATIONAL on csr_addr — a synchronous master
//     samples csr_rdata at the same clock edge that consumes its csr_read strobe;
//   * csr_write/csr_read are 1-cycle strobes; csr_read is REQUIRED for registers with read
//     side effects (BUF_DATA pop, TS_LO shadow latch) and harmless elsewhere.
//
// Responsibilities / policy decisions (all frozen in INTERFACES.md v1):
//   * CTRL strobes (arm/disarm/force_trig/soft_rst) are self-clearing; CTRL reads as 0.
//   * cfg_err lockout: any write to the config address set {PRETRIG, WINDOWS, RLE_CTRL,
//     CMP_SEL, CMP_LANE window, TRIG_COMBINE, SEQ_CNTn} while state != IDLE is IGNORED and
//     sets sticky STATUS.cfg_err; cfg_err clears ONLY on soft_rst (accepted-write clearing
//     would hide earlier errors).
//   * force_trig latches as PENDING when strobed in FILLING or ARMED (ignored in IDLE/DONE:
//     no capture to force) and holds the core's trig input high until the trigger is
//     accepted (first ARMED cycle with a valid sample) or the run ends — so it works even
//     if comparators never match and across sample_valid gaps.
//   * soft_rst = disarm the core + clear cfg_err/force-pending/drain pointer/TS shadow.
//     It never writes the capture BRAM; a completed capture remains drainable after re-arm
//     config, and re-arm works normally.
//   * Comparator config addressing: CMP_SEL selects {field[3:2], comparator[1:0]}; words
//     16..31 are the 32-bit lanes of that field (lane j = probe bits [32j+31:32j]). Lanes
//     beyond ceil(PROBE_W/32) read 0 / drop writes. Bits beyond PROBE_W in the top lane
//     read 0.
//   * BUF_DATA pop: each csr_read returns the next 32-bit lane of the current sample and
//     advances lane-then-address; BUF_CTRL bit0 resets the drain pointer. First BUF_DATA
//     read must come >= 1 cycle after BUF_CTRL (RAM read latency) — any real transport
//     satisfies this.
//   * TS_LO read latches ts[47:32] into a shadow; TS_HI returns the shadow (coherent 48-bit
//     reads with two 32-bit accesses).
//   * WINDOWS writes of 0 are stored as 1 (range 1..255); values > DEPTH/2 (which would
//     make a window slice smaller than 2 samples) are rejected and set cfg_err (issue #7).
//   * Reserved/unmapped addresses read 0; writes to them are ignored (no cfg_err).
module scope_csr #(
    parameter int unsigned PROBE_W    = 32,   // 1..512 (user probe width: comparators, HWCFG)
    parameter int unsigned STORE_W    = PROBE_W,  // stored-word width (= PROBE_W+1 when RLE_EN)
    parameter int unsigned DEPTH_LOG2 = 8,    // 8..15
    parameter int unsigned NUM_CMP    = 4,    // fixed 4 in v1 (CMP_SEL[1:0])
    parameter int unsigned SEQ_STAGES = 4,    // fixed 4 in v1
    parameter bit          RLE_EN     = 1'b0,
    parameter int unsigned TS_W       = 48
) (
    input  logic                       clk,
    input  logic                       rst,        // synchronous, active high

    // native CSR bus
    input  logic [7:0]                 csr_addr,
    input  logic [31:0]                csr_wdata,
    input  logic                       csr_write,
    input  logic                       csr_read,
    output logic [31:0]                csr_rdata,  // combinational

    // control to scope_core
    output logic                       arm,
    output logic                       disarm,
    output logic                       force_trig,  // held-while-pending (see header)
    output logic [DEPTH_LOG2-1:0]      pretrig,
    output logic [7:0]                 windows,
    output logic                       rle_enable,
    output logic [23:0]                decim,       // SMPL_CTRL[23:0]: store 1 / (decim+1) cycles
    output logic                       qual_en,     // SMPL_CTRL[24]: storage qualification enable
    output logic [1:0]                 qual_sel,    // SMPL_CTRL[26:25]: qualifier comparator

    // status from scope_core
    input  logic [2:0]                 state,
    input  logic                       triggered,
    input  logic                       wrapped,
    input  logic [7:0]                 windows_done,
    input  logic [DEPTH_LOG2-1:0]      trig_index,
    input  logic [TS_W-1:0]            ts,
    input  logic [TS_W-1:0]            ts_at_trig,

    // capture-buffer drain (scope_core read port, same clock; STORE_W-wide words when RLE on)
    output logic [DEPTH_LOG2-1:0]      buf_rd_addr,
    input  logic [STORE_W-1:0]         buf_rd_data,

    // per-window metadata (scope_core sideband table; WIN_SEL/WIN_META, issue #8 addendum)
    output logic [7:0]                 win_rd_addr,
    input  logic [DEPTH_LOG2:0]        win_rd_data,

    // trigger-engine configuration (consumed by scope_trigger, issue #6; flat-packed:
    // comparator k occupies bits [k*PROBE_W +: PROBE_W] / stage n bits [n*32 +: 32])
    output logic [NUM_CMP*PROBE_W-1:0] cmp_mask,
    output logic [NUM_CMP*PROBE_W-1:0] cmp_value,
    output logic [NUM_CMP*PROBE_W-1:0] cmp_edge_mask,
    output logic [NUM_CMP*PROBE_W-1:0] cmp_edge_pol,
    output logic [31:0]                trig_combine,
    output logic [SEQ_STAGES*32-1:0]   seq_cnt,

    output logic                       cfg_err
);

  localparam int unsigned LANES = (PROBE_W + 31) / 32;
  localparam int unsigned PAD_W = LANES * 32;  // lane-padded comparator storage width
  // The buffer-drain lane window is sized to the STORED word width (PROBE_W+1 under RLE), which
  // may need one more 32-bit lane than the comparators — the BUF_DATA CSR read spans BUF_LANES.
  localparam int unsigned BUF_LANES = (STORE_W + 31) / 32;
  localparam int unsigned BUF_PAD_W = BUF_LANES * 32;

  // ---- decode ---------------------------------------------------------------------------
  wire wr_ctrl = csr_write && (csr_addr == 8'(scope_pkg::CSR_CTRL));
  wire soft_rst = wr_ctrl && csr_wdata[3];
  wire is_lane_addr = (csr_addr >= 8'(scope_pkg::CSR_CMP_LANE_BASE)) &&
                      (csr_addr < 8'(scope_pkg::CSR_CMP_LANE_BASE + scope_pkg::CSR_CMP_LANE_WORDS));
  wire is_seq_addr = (csr_addr >= 8'(scope_pkg::CSR_SEQ_CNT_BASE)) &&
                     (csr_addr < 8'(scope_pkg::CSR_SEQ_CNT_BASE + SEQ_STAGES));
  wire is_cfg_addr = (csr_addr == 8'(scope_pkg::CSR_PRETRIG)) || (csr_addr == 8'(scope_pkg::CSR_WINDOWS)) ||
                     (csr_addr == 8'(scope_pkg::CSR_RLE_CTRL)) || (csr_addr == 8'(scope_pkg::CSR_CMP_SEL)) ||
                     (csr_addr == 8'(scope_pkg::CSR_SMPL_CTRL)) ||
                     is_lane_addr || (csr_addr == 8'(scope_pkg::CSR_TRIG_COMBINE)) || is_seq_addr;
  wire cfg_locked = (state != 3'(scope_pkg::SCOPE_ST_IDLE));
  wire cfg_wr_ok = csr_write && is_cfg_addr && !cfg_locked;

  // WINDOWS range check (issue #7): a slice must hold >= 2 samples, i.e. WINDOWS <= DEPTH/2
  // (after the 0 -> 1 clamp). Out-of-range values are rejected and set cfg_err.
  wire [7:0] windows_wval = (csr_wdata[7:0] == 8'h0) ? 8'd1 : csr_wdata[7:0];
  wire windows_bad = (32'(windows_wval) > (32'h1 << (DEPTH_LOG2 - 1)));

  // CTRL strobes to the core (combinational pulses, consumed at the same edge as the write)
  assign arm    = wr_ctrl && csr_wdata[0];
  assign disarm = wr_ctrl && (csr_wdata[1] || csr_wdata[3]);  // soft_rst also disarms

  // ---- configuration registers ------------------------------------------------------------
  logic [3:0]  cmp_sel_q;  // [1:0] comparator, [3:2] field
  logic [PAD_W-1:0] cmp_q[4][NUM_CMP];  // [field][comparator], lane-padded
  logic [31:0] trig_combine_q;
  logic [31:0] seq_cnt_q[SEQ_STAGES];
  logic        rle_enable_q;
  logic [31:0] smpl_ctrl_q;   // decimation + storage qualification (#17/#20)
  logic [DEPTH_LOG2-1:0] pretrig_q;
  logic [7:0]  windows_q;

  // 32-bit write mask for lane j (zeroes bits beyond PROBE_W in the top lane)
  // (classic function form — no `return`, integer local — for yosys-formal parseability)
  function automatic logic [31:0] lane_wmask(input logic [3:0] j);
    integer rem;
    begin
      rem = PROBE_W - 32 * j;
      if (rem >= 32) lane_wmask = 32'hFFFF_FFFF;
      else if (rem <= 0) lane_wmask = 32'h0;
      else lane_wmask = (32'h1 << rem) - 32'h1;
    end
  endfunction

  wire [3:0] lane_idx = csr_addr[3:0];  // valid when is_lane_addr
  wire [1:0] seq_idx = 2'(csr_addr - 8'(scope_pkg::CSR_SEQ_CNT_BASE));  // valid when is_seq_addr

  always_ff @(posedge clk) begin
    if (rst) begin
      pretrig_q      <= '0;
      windows_q      <= 8'd1;
      rle_enable_q   <= 1'b0;
      smpl_ctrl_q    <= 32'h0;
      cmp_sel_q      <= 4'h0;
      for (int unsigned f = 0; f < 4; f++)
        for (int unsigned k = 0; k < NUM_CMP; k++) cmp_q[f][k] <= '0;
      trig_combine_q <= 32'h0;
      for (int unsigned n = 0; n < SEQ_STAGES; n++) seq_cnt_q[n] <= 32'd1;
    end else if (cfg_wr_ok) begin
      if (csr_addr == 8'(scope_pkg::CSR_PRETRIG)) pretrig_q <= csr_wdata[DEPTH_LOG2-1:0];
      if (csr_addr == 8'(scope_pkg::CSR_WINDOWS) && !windows_bad) windows_q <= windows_wval;
      if (csr_addr == 8'(scope_pkg::CSR_RLE_CTRL)) rle_enable_q <= csr_wdata[0];
      if (csr_addr == 8'(scope_pkg::CSR_SMPL_CTRL)) smpl_ctrl_q <= csr_wdata;
      if (csr_addr == 8'(scope_pkg::CSR_CMP_SEL)) cmp_sel_q <= csr_wdata[3:0];
      if (is_lane_addr && (32 * 32'(lane_idx) < PROBE_W))
        cmp_q[cmp_sel_q[3:2]][cmp_sel_q[1:0]][32*lane_idx+:32] <= csr_wdata & lane_wmask(
            lane_idx);
      if (csr_addr == 8'(scope_pkg::CSR_TRIG_COMBINE)) trig_combine_q <= csr_wdata;
      if (is_seq_addr) seq_cnt_q[seq_idx] <= csr_wdata;
    end
  end

  assign pretrig      = pretrig_q;
  assign windows      = windows_q;
  assign rle_enable   = rle_enable_q;
  assign decim        = smpl_ctrl_q[23:0];
  assign qual_en      = smpl_ctrl_q[24];
  assign qual_sel     = smpl_ctrl_q[26:25];
  assign trig_combine = trig_combine_q;

  for (genvar k = 0; k < 32'(NUM_CMP); k++) begin : g_cmp_out
    assign cmp_mask[k*PROBE_W+:PROBE_W]      = cmp_q[scope_pkg::CMP_FIELD_MASK][k][PROBE_W-1:0];
    assign cmp_value[k*PROBE_W+:PROBE_W]     = cmp_q[scope_pkg::CMP_FIELD_VALUE][k][PROBE_W-1:0];
    assign cmp_edge_mask[k*PROBE_W+:PROBE_W] = cmp_q[scope_pkg::CMP_FIELD_EDGE_MASK][k][PROBE_W-1:0];
    assign cmp_edge_pol[k*PROBE_W+:PROBE_W]  = cmp_q[scope_pkg::CMP_FIELD_EDGE_POL][k][PROBE_W-1:0];
  end
  for (genvar n = 0; n < 32'(SEQ_STAGES); n++) begin : g_seq_out
    assign seq_cnt[n*32+:32] = seq_cnt_q[n];
  end

  // ---- sticky cfg_err ----------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) cfg_err <= 1'b0;
    else if (soft_rst) cfg_err <= 1'b0;
    else if (csr_write && is_cfg_addr && cfg_locked) cfg_err <= 1'b1;
    else if (csr_write && csr_addr == 8'(scope_pkg::CSR_WINDOWS) && windows_bad) cfg_err <= 1'b1;
  end

  // ---- force_trig pending --------------------------------------------------------------------
  logic force_pend;
  always_ff @(posedge clk) begin
    if (rst) force_pend <= 1'b0;
    else if (wr_ctrl && (csr_wdata[1] || csr_wdata[3])) force_pend <= 1'b0;  // disarm/soft_rst
    else if (wr_ctrl && csr_wdata[2] &&
             (state == 3'(scope_pkg::SCOPE_ST_FILLING) || state == 3'(scope_pkg::SCOPE_ST_ARMED)))
      force_pend <= 1'b1;
    else if (state != 3'(scope_pkg::SCOPE_ST_FILLING) && state != 3'(scope_pkg::SCOPE_ST_ARMED))
      force_pend <= 1'b0;  // accepted (TRIGGERED) or run ended
  end
  assign force_trig = force_pend;

  // ---- buffer drain pointer -------------------------------------------------------------------
  localparam int unsigned LANE_CNT_W = (BUF_LANES > 1) ? $clog2(BUF_LANES) : 1;
  logic [DEPTH_LOG2-1:0] drain_addr;
  logic [LANE_CNT_W-1:0] drain_lane;
  wire pop = csr_read && (csr_addr == 8'(scope_pkg::CSR_BUF_DATA));

  always_ff @(posedge clk) begin
    if (rst || soft_rst || (csr_write && csr_addr == 8'(scope_pkg::CSR_BUF_CTRL) && csr_wdata[0])) begin
      drain_addr <= '0;
      drain_lane <= '0;
    end else if (pop) begin
      if (drain_lane == LANE_CNT_W'(BUF_LANES - 1)) begin
        drain_lane <= '0;
        drain_addr <= drain_addr + 1'b1;
      end else begin
        drain_lane <= drain_lane + 1'b1;
      end
    end
  end
  assign buf_rd_addr = drain_addr;

  // lane-padded view of the RAM output register (bits beyond STORE_W read 0)
  wire [BUF_PAD_W-1:0] buf_ext = BUF_PAD_W'(buf_rd_data);

  // ---- WIN_SEL selector (plain register, writable in any state — it only selects which
  //      window the RO WIN_META view shows; the metadata RAM read has 1-cycle latency, so
  //      read WIN_META no earlier than the cycle after writing WIN_SEL) -----------------------
  logic [7:0] win_sel_q;
  always_ff @(posedge clk) begin
    if (rst || soft_rst) win_sel_q <= 8'h00;
    else if (csr_write && csr_addr == 8'(scope_pkg::CSR_WIN_SEL)) win_sel_q <= csr_wdata[7:0];
  end
  assign win_rd_addr = win_sel_q;

  // ---- TS shadow --------------------------------------------------------------------------------
  logic [TS_W-33:0] ts_hi_shadow;
  always_ff @(posedge clk) begin
    if (rst || soft_rst) ts_hi_shadow <= '0;
    else if (csr_read && csr_addr == 8'(scope_pkg::CSR_TS_LO)) ts_hi_shadow <= ts[TS_W-1:32];
  end

  // ---- combinational read mux ---------------------------------------------------------------------
  always_comb begin
    csr_rdata = 32'h0;
    if (csr_addr == 8'(scope_pkg::CSR_ID)) csr_rdata = scope_pkg::SCOPE_ID_REG;
    else if (csr_addr == 8'(scope_pkg::CSR_HWCFG))
      csr_rdata = {13'h0, RLE_EN, 4'(NUM_CMP), 4'(DEPTH_LOG2), 10'(PROBE_W)};
    else if (csr_addr == 8'(scope_pkg::CSR_STATUS))
      csr_rdata = {16'h0, windows_done, 2'b00, cfg_err, wrapped, triggered, state};
    else if (csr_addr == 8'(scope_pkg::CSR_PRETRIG)) csr_rdata = 32'(pretrig_q);
    else if (csr_addr == 8'(scope_pkg::CSR_WINDOWS)) csr_rdata = 32'(windows_q);
    else if (csr_addr == 8'(scope_pkg::CSR_RLE_CTRL)) csr_rdata = {31'h0, rle_enable_q};
    else if (csr_addr == 8'(scope_pkg::CSR_SMPL_CTRL)) csr_rdata = smpl_ctrl_q;
    else if (csr_addr == 8'(scope_pkg::CSR_TS_LO)) csr_rdata = ts[31:0];
    else if (csr_addr == 8'(scope_pkg::CSR_TS_HI)) csr_rdata = 32'(ts_hi_shadow);
    else if (csr_addr == 8'(scope_pkg::CSR_TRIG_INDEX)) csr_rdata = 32'(trig_index);
    else if (csr_addr == 8'(scope_pkg::CSR_TSTRIG_LO)) csr_rdata = ts_at_trig[31:0];
    else if (csr_addr == 8'(scope_pkg::CSR_TSTRIG_HI)) csr_rdata = 32'(ts_at_trig[TS_W-1:32]);
    else if (csr_addr == 8'(scope_pkg::CSR_WIN_SEL)) csr_rdata = 32'(win_sel_q);
    else if (csr_addr == 8'(scope_pkg::CSR_WIN_META)) csr_rdata = 32'(win_rd_data);
    else if (csr_addr == 8'(scope_pkg::CSR_CMP_SEL)) csr_rdata = 32'(cmp_sel_q);
    else if (is_lane_addr) begin
      if (32 * 32'(lane_idx) < PROBE_W)
        csr_rdata = cmp_q[cmp_sel_q[3:2]][cmp_sel_q[1:0]][32*lane_idx+:32];
    end else if (csr_addr == 8'(scope_pkg::CSR_TRIG_COMBINE)) csr_rdata = trig_combine_q;
    else if (is_seq_addr) csr_rdata = seq_cnt_q[seq_idx];
    else if (csr_addr == 8'(scope_pkg::CSR_BUF_DATA)) csr_rdata = buf_ext[32*drain_lane+:32];
    // CTRL, BUF_CTRL, reserved: read 0
  end

endmodule
