// scope_trigger — 4 comparator units + per-stage combine + 4-stage sequencer (capture domain).
//
// Normative behavior: docs/INTERFACES.md "Trigger semantics" (added at #6; register offsets
// frozen at #5). Config arrives flat-packed from scope_csr (comparator k at
// [k*PROBE_W +: PROBE_W], stage n of seq_cnt at [n*32 +: 32]).
//
// Comparator unit k (exact, per PLAN.md §5):
//   level_hit_k = ((probe & mask_k) == value_k)
//   edge_hit_k  = (edge_mask_k == 0) ? 1
//               : |(edge_mask_k & ((edge_pol_k & rise) | (~edge_pol_k & fall)))
//     where rise = ~probe_d1 & probe, fall = probe_d1 & ~probe — i.e. for each selected bit
//     a transition THIS cycle whose direction matches edge_pol (1=rising, 0=falling);
//     multiple selected bits OR together. cmp_hit_k = level_hit_k && edge_hit_k.
//
// Sequencer: stage n is enabled iff its TRIG_COMBINE select mask [8n+3:8n] != 0 (disabled
// stages are skipped — that is how 1/2/3-stage configs express themselves). stage_hit_n is
// the AND ([8n+4]=1) or OR ([8n+4]=0) reduction over the selected comparators' cmp_hit.
// A stage advances after SEQ_CNTn occurrences (cycles where stage_hit_n is true, not
// necessarily consecutive; 0 is treated as 1). Completion of the LAST enabled stage fires.
// A stage completing on sample i hands over on sample i+1 (registered advance). With all
// stages disabled the comparator path never fires (force_trig / trig_ext_i still work).
//
// LATENCY (load-bearing, asserted in tb_trigger_seq): everything is registered —
// probe_d1, comparator outputs, sequencer state, and the fire pulse — so the comparator
// trigger path asserts `trig` exactly LATENCY = 2 cycles after the probe sample that
// satisfied the final stage. `sample_o` is probe delayed by the same 2 cycles: feed
// scope_core's sample_data from sample_o and the sample stored in the `trig` cycle IS the
// satisfying sample (host-visible trigger-sample definition; scope_core semantics from #4
// are unchanged). ts_at_trig is therefore the satisfying sample's time + LATENCY.
//
// Policy decisions:
//   * `run` gates the sequencer (scope_top wires it to state==ARMED): while low the
//     sequencer parks at the first enabled stage with counters clear; one fire per run
//     assertion (re-arms when run deasserts).
//   * `trig` = registered sequencer fire OR force_trig (held pending from scope_csr) OR
//     trig_ext_i — an OR of registered sources; no combinational path from probe.
//   * `trig_ext_o` = own fire only: sequencer fire pulse OR the rising edge of force_trig
//     (1 cycle wide). trig_ext_i is deliberately EXCLUDED so two cross-connected instances
//     cannot form a combinational loop. trig_ext_i must be synchronous to clk.
module scope_trigger #(
    parameter int unsigned PROBE_W    = 32,
    parameter int unsigned NUM_CMP    = 4,   // fixed 4 in v1 (TRIG_COMBINE packing)
    parameter int unsigned SEQ_STAGES = 4    // fixed 4 in v1
) (
    input  logic                       clk,
    input  logic                       rst,          // synchronous, active high

    input  logic [PROBE_W-1:0]         probe,
    input  logic                       run,          // sequencer enable (state==ARMED)
    input  logic                       force_trig,   // held pending, from scope_csr
    input  logic                       trig_ext_i,   // synchronous external trigger

    // configuration (from scope_csr; static while armed thanks to the cfg_err lockout)
    input  logic [NUM_CMP*PROBE_W-1:0] cmp_mask,
    input  logic [NUM_CMP*PROBE_W-1:0] cmp_value,
    input  logic [NUM_CMP*PROBE_W-1:0] cmp_edge_mask,
    input  logic [NUM_CMP*PROBE_W-1:0] cmp_edge_pol,
    input  logic [31:0]                trig_combine,
    input  logic [SEQ_STAGES*32-1:0]   seq_cnt,

    output logic                       trig,         // to scope_core.trig
    output logic                       trig_ext_o,   // own fire, 1-cycle pulse
    output logic [PROBE_W-1:0]         sample_o,     // probe delayed by LATENCY cycles
    output logic [NUM_CMP-1:0]         cmp_hit       // registered per-unit hits (debug/TB)
);

  localparam int unsigned LATENCY = 2;  // probe -> trig, see header

  // ---- probe history / delayed sample path ----------------------------------------------
  // dly[0] doubles as probe_d1 for edge detection; sample_o is probe delayed by LATENCY so
  // the sample scope_core stores in the trig cycle is the satisfying sample (see header).
  logic [PROBE_W-1:0] dly[LATENCY];
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int unsigned i = 0; i < LATENCY; i++) dly[i] <= '0;
    end else begin
      dly[0] <= probe;
      for (int unsigned i = 1; i < LATENCY; i++) dly[i] <= dly[i-1];
    end
  end
  wire [PROBE_W-1:0] probe_d1 = dly[0];
  assign sample_o = dly[LATENCY-1];

  // ---- comparators (registered) -----------------------------------------------------------
  wire [PROBE_W-1:0] rise = ~probe_d1 & probe;
  wire [PROBE_W-1:0] fall = probe_d1 & ~probe;

  logic [NUM_CMP-1:0] cmp_hit_q;
  for (genvar k = 0; k < 32'(NUM_CMP); k++) begin : g_cmp
    wire [PROBE_W-1:0] mask_k = cmp_mask[k*PROBE_W+:PROBE_W];
    wire [PROBE_W-1:0] value_k = cmp_value[k*PROBE_W+:PROBE_W];
    wire [PROBE_W-1:0] emask_k = cmp_edge_mask[k*PROBE_W+:PROBE_W];
    wire [PROBE_W-1:0] epol_k = cmp_edge_pol[k*PROBE_W+:PROBE_W];

    wire level_k = ((probe & mask_k) == value_k);
    wire edge_k = (emask_k == '0) ? 1'b1
                                  : |(emask_k & ((epol_k & rise) | (~epol_k & fall)));

    always_ff @(posedge clk) begin
      if (rst) cmp_hit_q[k] <= 1'b0;
      else cmp_hit_q[k] <= level_k && edge_k;
    end
  end
  assign cmp_hit = cmp_hit_q;

  // ---- combine + sequencer -------------------------------------------------------------------
  logic [SEQ_STAGES-1:0] stage_en;
  logic [SEQ_STAGES-1:0] stage_hit;
  logic [31:0] tgt[SEQ_STAGES];
  for (genvar n = 0; n < 32'(SEQ_STAGES); n++) begin : g_stage
    wire [NUM_CMP-1:0] sel = trig_combine[8*n+:NUM_CMP];
    wire and_mode = trig_combine[8*n+4];
    assign stage_en[n] = |sel;
    assign stage_hit[n] = and_mode ? &(cmp_hit_q | ~sel) : |(cmp_hit_q & sel);
    assign tgt[n] = (seq_cnt[n*32+:32] == 32'h0) ? 32'd1 : seq_cnt[n*32+:32];
  end

  // lowest enabled stage index >= from, or SEQ_STAGES if none
  // (classic function form — integer locals/args — for yosys-formal parseability)
  function automatic logic [2:0] first_en_from(input integer from,
                                               input logic [SEQ_STAGES-1:0] en);
    integer i;
    begin
      first_en_from = 3'(SEQ_STAGES);
      for (i = 32'(SEQ_STAGES) - 1; i >= 0; i = i - 1)
        if (i >= from && en[i]) first_en_from = 3'(i);
    end
  endfunction

  // TRIG_COMBINE bits [8n+7:8n+5] are reserved-as-0 (INTERFACES.md) — read but ignored.
  wire unused_combine_reserved = &{1'b0, trig_combine[31:29], trig_combine[23:21],
                                   trig_combine[15:13], trig_combine[7:5]};

  logic [2:0] cur;  // current stage, SEQ_STAGES = none/parked
  logic [31:0] occ;  // completed occurrences in the current stage
  logic fired;  // one-shot per run assertion
  logic trig_seq_q;

  wire [2:0] first_en = first_en_from(0, stage_en);
  wire cur_valid = (cur < 3'(SEQ_STAGES));
  wire cur_hit = cur_valid && stage_hit[cur[1:0]];
  wire stage_done = cur_hit && (occ + 32'd1 >= tgt[cur[1:0]]);
  wire [2:0] nxt = first_en_from(32'(cur) + 1, stage_en);
  wire fire_now = run && !fired && stage_done && (nxt == 3'(SEQ_STAGES));

  always_ff @(posedge clk) begin
    if (rst) begin
      cur        <= 3'(SEQ_STAGES);
      occ        <= '0;
      fired      <= 1'b0;
      trig_seq_q <= 1'b0;
    end else if (!run) begin
      cur        <= first_en;  // park at the first enabled stage, counters clear
      occ        <= '0;
      fired      <= 1'b0;
      trig_seq_q <= 1'b0;
    end else begin
      trig_seq_q <= fire_now;
      if (fire_now) fired <= 1'b1;
      else if (!fired && stage_done) begin
        cur <= nxt;
        occ <= '0;
      end else if (!fired && cur_hit) begin
        occ <= occ + 32'd1;
      end
    end
  end

  // ---- outputs ------------------------------------------------------------------------------
  logic force_d1;
  always_ff @(posedge clk) begin
    if (rst) force_d1 <= 1'b0;
    else force_d1 <= force_trig;
  end

  assign trig = trig_seq_q || force_trig || trig_ext_i;
  assign trig_ext_o = trig_seq_q || (force_trig && !force_d1);  // no trig_ext_i path (no loops)

endmodule
