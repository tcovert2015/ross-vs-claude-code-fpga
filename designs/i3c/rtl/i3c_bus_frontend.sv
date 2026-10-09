// ============================================================================
// i3c_bus_frontend.sv  -  Bus front-end: sync, edge detect, START/STOP/Sr, timers
//
// The Target treats SDA/SCL as asynchronous inputs and runs all logic on a free
// running sys_clk (oversampled; see docs/design_decisions.md D-1: clk >= 100 MHz).
// This block:
//   * synchronizes SDA/SCL through SYNC_STAGES flops,
//   * produces 1-cycle edge strobes,
//   * detects START / repeated-START / STOP as SDA edges while SCL is High,
//     GATED by !sda_oe so the Target never mistakes its OWN drive for a bus
//     condition (critique fix F-3),
//   * tracks bus_busy (between START and STOP) and Bus Free/Available/Idle timers
//     (parameterized; formal uses small thresholds, real ns set per device).
//
// CDC note: the SDA/SCL synchronizers are the ONLY async crossing in the design;
// metastability is closed by SDC (set_false_path) + the >=3-sample rule, not by
// formal. Upper layers are proven against idealized edge strobes.
// ============================================================================
`ifndef I3C_BUS_FRONTEND_SV
`define I3C_BUS_FRONTEND_SV

module i3c_bus_frontend #(
  parameter int unsigned SYNC_STAGES = 2,
  parameter int unsigned CNT_W       = 24,
  // Release tail: after the Target stops driving SDA (sda_oe 1->0), its own line
  // rises (pull-up) a few synchronized cycles later. Keep bus-condition detection
  // gated for OE_TAIL extra cycles so that self-release is never mistaken for a
  // STOP/START (critique F-3 extended; FINDING-SIM-1). Must cover SYNC_STAGES + line.
  parameter int unsigned OE_TAIL     = 4,
  // Bus-condition timer thresholds (cycles). Real values per device/clock; these
  // formal-small defaults keep BMC depths tractable. Require FREE <= AVAIL <= IDLE.
  parameter int unsigned BUS_FREE_CYCLES  = 2,    // tBUF
  parameter int unsigned BUS_AVAIL_CYCLES = 4,    // tAVAL
  parameter int unsigned BUS_IDLE_CYCLES  = 8     // tIDLE
) (
  input  logic clk,
  input  logic rst_n,
  // raw async pad inputs
  input  logic sda_i,
  input  logic scl_i,
  // Target's own SDA drive-enable (from the SDA mux) - gates bus-condition detect
  input  logic sda_oe,
  // synchronized lines + edge strobes
  output logic sda_sync,
  output logic scl_sync,
  output logic scl_rising,
  output logic scl_falling,
  output logic sda_rising,
  output logic sda_falling,
  // bus conditions (1-cycle strobes)
  output logic start_stb,    // plain START (from idle)
  output logic rstart_stb,   // repeated START (in-frame)
  output logic stop_stb,     // STOP
  output logic bus_busy,     // between START and STOP
  output logic bus_free,     // tBUF elapsed since bus went quiescent
  output logic bus_available,// tAVAL elapsed
  output logic bus_idle      // tIDLE elapsed
);

  // ---- Synchronizers (init to idle-High so reset shows no false edge) --------
  logic [SYNC_STAGES-1:0] sda_sr;
  logic [SYNC_STAGES-1:0] scl_sr;
  logic sda_q, scl_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sda_sr <= {SYNC_STAGES{1'b1}};
      scl_sr <= {SYNC_STAGES{1'b1}};
      sda_q  <= 1'b1;
      scl_q  <= 1'b1;
    end else begin
      sda_sr <= {sda_sr[SYNC_STAGES-2:0], sda_i};
      scl_sr <= {scl_sr[SYNC_STAGES-2:0], scl_i};
      sda_q  <= sda_sync;
      scl_q  <= scl_sync;
    end
  end

  assign sda_sync = sda_sr[SYNC_STAGES-1];
  assign scl_sync = scl_sr[SYNC_STAGES-1];

  // ---- Edge strobes ---------------------------------------------------------
  assign scl_rising  =  scl_sync & ~scl_q;
  assign scl_falling = ~scl_sync &  scl_q;
  assign sda_rising  =  sda_sync & ~sda_q;
  assign sda_falling = ~sda_sync &  sda_q;

  // ---- Bus-condition detection (gated by !sda_oe + release tail) -------------
  // drive_recent = the Target is driving SDA, or stopped driving within the last
  // OE_TAIL cycles (so its own line-release transient is not seen as a condition).
  localparam int unsigned TAILW = (OE_TAIL < 2) ? 1 : $clog2(OE_TAIL + 1);
  logic [TAILW-1:0] oe_tail;
  always_ff @(posedge clk) begin
    if (!rst_n)        oe_tail <= '0;
    else if (sda_oe)   oe_tail <= OE_TAIL[TAILW-1:0];
    else if (|oe_tail) oe_tail <= oe_tail - 1'b1;
  end
  logic bus_ctrl;
  logic start_raw, stop_raw;
  logic drive_recent;
  assign drive_recent = sda_oe | (|oe_tail);
  assign bus_ctrl  = ~drive_recent;                       // F-3 (+ release tail)
  assign start_raw = bus_ctrl & scl_sync & sda_falling;    // SDA fall while SCL High
  assign stop_raw  = bus_ctrl & scl_sync & sda_rising;     // SDA rise while SCL High

  assign start_stb  = start_raw & ~bus_busy;               // first START
  assign rstart_stb = start_raw &  bus_busy;               // repeated START
  assign stop_stb   = stop_raw  &  bus_busy;               // STOP only when in a frame

  always_ff @(posedge clk) begin
    if (!rst_n)            bus_busy <= 1'b0;
    else if (start_raw)    bus_busy <= 1'b1;
    else if (stop_raw)     bus_busy <= 1'b0;
  end

  // ---- Bus quiescent timer (idle = both lines High and not in a frame) -------
  logic quiescent;
  logic [CNT_W-1:0] idle_cnt;
  assign quiescent = scl_sync & sda_sync & ~bus_busy;

  always_ff @(posedge clk) begin
    if (!rst_n)           idle_cnt <= '0;
    else if (!quiescent)  idle_cnt <= '0;
    else if (~&idle_cnt)  idle_cnt <= idle_cnt + 1'b1;     // saturate
  end

  assign bus_free      = quiescent & (idle_cnt >= BUS_FREE_CYCLES[CNT_W-1:0]);
  assign bus_available = quiescent & (idle_cnt >= BUS_AVAIL_CYCLES[CNT_W-1:0]);
  assign bus_idle      = quiescent & (idle_cnt >= BUS_IDLE_CYCLES[CNT_W-1:0]);

  // ==========================================================================
  // Formal properties (Slice 1)
  // ==========================================================================
`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  initial assume (!rst_n);

  // Parameter sanity (elaboration-time ordering of thresholds).
  initial begin
    a_thresh_order : assert (BUS_FREE_CYCLES <= BUS_AVAIL_CYCLES &&
                             BUS_AVAIL_CYCLES <= BUS_IDLE_CYCLES);
  end

  always_ff @(posedge clk) if (rst_n) begin
    // F-3: while the Target drives SDA, no bus condition may be reported.
    p_f3_gate    : assert (!sda_oe || !(start_stb || rstart_stb || stop_stb));
    // START kinds are mutually exclusive and correctly qualified by bus_busy.
    p_excl       : assert (!(start_stb && rstart_stb));
    p_start_idle : assert (!start_stb  ||  !bus_busy);
    p_rstart_busy: assert (!rstart_stb ||  bus_busy);
    p_stop_busy  : assert (!stop_stb   ||  bus_busy);
    // A START and a STOP can never be reported in the same cycle (SDA can't both
    // rise and fall), so bus_busy updates are unambiguous.
    p_no_startstop: assert (!((start_stb||rstart_stb) && stop_stb));
    // Edge strobes are one-hot per line per direction.
    p_scl_edge   : assert (!(scl_rising && scl_falling));
    p_sda_edge   : assert (!(sda_rising && sda_falling));
    // Timer flag nesting (monotone): idle => available => free.
    p_idle_avail : assert (!bus_idle      || bus_available);
    p_avail_free : assert (!bus_available || bus_free);
    // Timers are meaningless while a frame is active.
    p_free_quiet : assert (!bus_free || (~bus_busy));
  end

  // bus_busy follows START/STOP one cycle later.
  always_ff @(posedge clk) if (f_past_valid && rst_n && $past(rst_n)) begin
    p_busy_set : assert (!($past(start_stb) || $past(rstart_stb)) ||  bus_busy);
    p_busy_clr : assert (!$past(stop_stb)                          || !bus_busy);
  end

  // ---- Reachability covers --------------------------------------------------
  always_ff @(posedge clk) if (rst_n) begin
    c_start  : cover (start_stb);
    c_rstart : cover (rstart_stb);
    c_stop   : cover (stop_stb);
    c_busy   : cover (bus_busy);
    c_free   : cover (bus_free);
    c_avail  : cover (bus_available);
    c_idle   : cover (bus_idle);
    // a full minimal frame: START ... STOP
    c_frame  : cover (stop_stb && f_past_valid);
  end
`endif

endmodule
`endif
