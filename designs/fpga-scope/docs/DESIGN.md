# fpga-scope — Architecture & Design Notes

Stub at M0 — grows with each milestone. Source of truth for interfaces is
[INTERFACES.md](INTERFACES.md) (normative after the M2 freeze); the full design document is
[PLAN.md](PLAN.md). This file records the architecture, the policy decisions, and any
deviations from the plan made during implementation.

## Block architecture (PLAN.md §5)

```
probe ─►[scope_trigger]──trig──►┐
probe ─►(opt scope_rle)─►[scope_core: DEPTH×(PROBE_W+TS?) simple-dual-port BRAM,
                                  write ptr free-runs while armed, stop_cnt after trig]
                                  │ read port (drain, same clk)
                    [scope_csr]◄──┤            capture domain
   ══════ prim_fifo_async ═══════╪═══════════  transport domain
                    [scope_drain: frames buffer + CSR reads into byte stream]──►[scope_uart | if/*]
```

- **Capture FSM (`scope_core`, exact — implemented in issue #4):**

  ```
            arm                 fill_cnt == PRETRIG          trig accepted
   IDLE ─────────► FILLING ──────────────────────► ARMED ─────────────────► TRIGGERED
    ▲                 ▲                                                          │
    │                 │ windows_done < WINDOWS (auto re-arm)                     │ post count
    │ disarm          │                                                          ▼ exhausted
    └───────────── DONE ◄────────────────────────────────────────────────────────┘
                    (parks in DONE after the last window until arm/disarm)
  ```

  - **Trigger-sample alignment (load-bearing):** the sample present on `sample_data` in the
    cycle `trig` is asserted (with `sample_valid` high) IS the trigger sample. It is always
    stored; its buffer address is latched into `trig_index` and the free-running probe-domain
    timestamp into `ts_at_trig` in that same cycle. The trigger sample counts as the FIRST of
    the `DEPTH − PRETRIG` post-trigger samples, so a completed capture holds exactly
    `PRETRIG` pre-trigger samples + the trigger sample + `DEPTH − PRETRIG − 1` later samples.
  - **Trigger in FILLING is ignored** (policy): triggers (including force_trig) are accepted
    only in `ARMED` with `sample_valid` high — the pretrig backlog does not exist before
    `ARMED`, so comparators cannot be meaningfully armed earlier. `force_trig` in `ARMED`
    always works (PLAN.md §6.5).
  - `FILLING` stores exactly `PRETRIG` samples (the `ARMED` transition uses the post-update
    fill count). With `PRETRIG=0` the FSM spends one sample-free cycle in `FILLING` so the
    state sequence is always observable.
  - `wrapped` = the write pointer passed `DEPTH` once since (re)arm. Note a *completed*
    capture always sets `wrapped` (it stores ≥ DEPTH samples); the flag is informative for
    aborted/partial captures and for host sanity checks.
  - In `DONE` the write pointer never advances (formal property (b), issue #6).
- **Trigger:** all comparator/sequencer outputs are registered; the 1-cycle trigger latency is
  specified behavior, not an implementation accident.
- **Clock domains:** exactly one CDC in the whole design — drain/CSR traffic through two
  `prim_fifo_async` (cmd in, data out). The capture path never stalls on the transport.

## Policy decisions

| # | Decision | Where asserted |
|---|---|---|
| 1 | `prim_ram_1r1w` read-during-write returns **old data**; the whole design assumes it | `sim/tb_prim_ram.sv` (issue #3) |
| 2 | Trigger latency is 1 registered cycle | `docs/INTERFACES.md`, trigger TBs (issue #6) |
| 3 | Under RLE, `trig_index`/`PRETRIG` are **word-domain**; the encoder flushes on the trigger so the host reorders words then `rle_decode`s (no raw-index sideband) | `host/tests/test_cosim.py` (issue #9) |
| 4 | Timestamps are captured in the probe domain and drained through the same FIFO as data | drain TBs (issue #8) |
| 5 | UART is LSB-first; CRC16-CCITT is big-endian on the wire | first two assertions of `sim/tb_uart.sv` (issue #8) |

## Host-side reconstruction (issue #7 — normative for the Python host, proven by tb_pretrig)

A completed capture window is a circular buffer slice plus three facts: `trig_index` (the
absolute buffer address of the trigger sample), `wrapped` (the write pointer passed the
slice size at least once since this window armed), and the configured `PRETRIG`. The core
does no reordering; the host reorders with exactly this math (per window; for a
single-window capture SLICE = DEPTH and slice-relative == absolute):

```
post   = SLICE - PRETRIG_EFF          # post-trigger budget, trigger sample included
oldest = wrapped ? (trig_index + post) mod SLICE   # slice-relative
                 : 0
ordered[i] = buffer[slice_base + ((oldest + i) mod SLICE)]      i = 0 .. SLICE-1
```

- The trigger sample sits at `ordered[pretrig_actual]` where `pretrig_actual =
  wrapped ? PRETRIG_EFF : trig_index_rel` — for a COMPLETED window `wrapped` is always 1
  (a window stores >= SLICE samples by construction: PRETRIG_EFF fill + SLICE−PRETRIG_EFF
  post), so `pretrig_actual == PRETRIG_EFF`. The `!wrapped` branch matters only when a
  host inspects an aborted (disarmed) capture: then only `buffer[0..wptr-1]` are valid and
  the trigger (if any) sits at `ordered[trig_index_rel]` with fewer than PRETRIG_EFF
  samples of history.
- `ts_at_trig` = probe-domain time of the trigger CONSUMPTION edge = satisfying-sample
  time + trigger LATENCY (2; see INTERFACES.md "Trigger semantics").

**Worked example 1 (wrapped, the normal case).** DEPTH=8, one window (SLICE=8), PRETRIG=3,
post = 8−3 = 5. Arm at sample 0; the trigger fires on sample index K=9 (the buffer already
wrapped once). Sample k lands at address k mod 8, so trig_index = 9 mod 8 = **1**, and the
capture stores through sample K+post−1 = 13. Final buffer by address:

```
addr:    0    1    2    3    4    5    6    7
sample:  s8  s9*  s10  s11  s12  s13  s6   s7        (* = trigger sample)
```

oldest = (1 + 5) mod 8 = 6 → ordered = buffer[6],b[7],b[0],b[1],... =
`s6 s7 s8 s9 s10 s11 s12 s13` — time order restored, and the trigger sample s9 sits at
`ordered[3]` = ordered[PRETRIG]. ✓

**Worked example 2 (not wrapped — aborted capture).** DEPTH=8, PRETRIG=3; the host disarms
after only 5 samples were stored (s0..s4 at addresses 0..4, trigger accepted on s4 →
trig_index=4, wrapped=0). oldest = 0 → ordered = `s0 s1 s2 s3 s4 x x x`; only the first
wptr=5 entries are valid; the trigger sits at ordered[trig_index]=ordered[4], with
pretrig_actual = 4 ≥ ... capped history as stored. (Completed captures never hit this
branch.)

**Multi-window:** window w occupies `slice_base = w * SLICE`; per-window `trig_index`
(absolute) and `wrapped` come from the sideband metadata table (win_rd port / #8 DRAIN
header); apply the same math per slice with `trig_index_rel = trig_index - slice_base`.

## Deviations from PLAN.md

| Issue | Deviation | Rationale |
|---|---|---|
| #3 | `prim_fifo_async` storage is a flop/LUTRAM array with combinational read, not `prim_ram_1r1w` | `prim_ram_1r1w` is single-clock; a dual-clock FIFO needs its write port in `wclk` and read in `rclk`. The array is safe (slot content is stable ≥ SYNC_STAGES rclk before the read pointer can reach it) and is the classic Cummings shape. Intended for shallow CDC crossings only. |
| #3 | `prim_fifo_async` usable capacity is 2^`DEPTH_LOG2` + 1 (RAM ring + FWFT output stage); `prim_fifo_sync` capacity is exactly 2^`DEPTH_LOG2` | FWFT over a 1-cycle-latency RAM needs a prefetched output register. The sync FIFO counts that register inside its capacity budget (exact full flag, one RAM slot idles while the output stage holds data); the async FIFO cannot without adding a cross-domain count, so its extra stage adds one slot. Both are documented in INTERFACES.md and asserted in the TBs. |
| #4 | After the last window `scope_core` parks in `DONE` until `arm`/`disarm`, instead of PLAN.md §5's "windows left? re-arm : IDLE" automatic return to IDLE | An automatic `DONE→IDLE` would make a completed capture indistinguishable from never-armed in `STATUS.state` while the host drains the buffer. `disarm` provides the `→IDLE` edge explicitly; intermediate windows still re-arm automatically. |
| #4 | Per-window buffer partitioning is deferred to issue #7; in #4 each auto re-armed window reuses the full-depth budget (later windows overwrite earlier ones) | Issue #4's scope is full-depth capture with `windows=1`; #7 owns the windows semantics and TB. `windows_done` counting and the re-arm loop are wired now so the FSM shape is final. |
| #5 | CSR map v1 adds `TRIG_INDEX` (9), `TSTRIG_LO` (10), `TSTRIG_HI` (11) — not in the PLAN.md draft map | A CSR-transport-only host (Avalon/AXI-Lite, issue #11) drains via `BUF_DATA` and never sees the DRAIN frame header, so without these registers it cannot reorder the circular buffer or timestamp the trigger. Freezing a map that makes the CSR transport unusable would be a spec bug. |
| #5 | Wide comparator config uses a `CMP_SEL` + 16-word lane window (words 15..31) instead of the draft `16+4k` linear layout | The draft layout leaves 4 words per comparator — fits PROBE_W ≤ 32 only. A linear map for 4 comparators × 4 fields × 16 lanes needs 256 words and overflows the 8-bit word-address space next to the other registers. The issue text endorses the selector-window resolution; config writes are rare so the extra CMP_SEL write costs nothing. |
| #5 | `BUF_DATA` returns 32-bit lanes (lane-then-address order), not "one buffer word" per pop | Buffer words are up to 512 bits; the CSR bus is 32. `DEPTH×L` pops drain the buffer; the host reassembles words from L consecutive lanes. |
| #6 | Probe→trig latency is **2 cycles** (not the design doc's "1-cycle") | The issue mandates registered probe history, comparator outputs, AND sequencer: that is two register stages before the fire pulse. The constant is measured and asserted in `tb_trigger_seq` and — critically — `scope_trigger.sample_o` delays the capture-data path by the same 2 cycles, so the host-visible trigger sample is exactly the satisfying sample. `ts_at_trig` = satisfying-sample time + 2 (documented in INTERFACES.md). |
| #6 | `trig_ext_o` excludes `trig_ext_i` and pulses only on the instance's own fire (sequencer fire or force_trig rising edge) | Including ext_i would create a combinational loop when two instances are cross-connected (`A.ext_o→B.ext_i, B.ext_o→A.ext_i`). Asserted in `tb_trigger_seq`. |
| #6 | Formal checker is instantiated inside `scope_core` under `` `ifdef FORMAL `` instead of SVA `bind` | yosys 0.33 (the local baseline) has no usable `bind`/`import` support. The properties still live in their own module/file (`formal/scope_core_fchk.sv`); synthesis and Verilator never see them. `scope_core` uses fully qualified `scope_pkg::` references (no header import) for the same yosys-compatibility reason. |
| #7 | After the last window the FSM parks in `DONE` (not the issue text's "after the last window: IDLE") | Same rationale as the #4 deviation, reaffirmed at #7: an auto-IDLE makes a completed capture indistinguishable from never-armed while the host drains. `tb_windows` asserts the parked-DONE contract; `disarm` provides the →IDLE edge. |
| #7 | Per-window `{wrapped, trig_index}` sideband is a `prim_ram_1r1w` (256 × DEPTH_LOG2+1), not the issue text's "flop-based table" | 255 windows × up to 16 bits ≈ 4k flops as a register table; as an inferred RAM it is one LUTRAM/BRAM with a single write per window completion and a dedicated read port (`win_rd_addr/win_rd_data`) for the #8 drain. Same TB contract, cheaper mechanism (explicitly allowed by the issue). |
| #7 | Per-window pretrig scaling is proportional: `PRETRIG_EFF = PRETRIG >> log2(W_eff)` | Preserves the user's configured pretrig/post ratio in every slice; clamping (`min(PRETRIG, SLICE-1)`) would silently change the ratio. Defined in INTERFACES.md "Capture semantics"; `scope_ref.py` `windows_model` implements the same expression. |

## Milestone notes

### M2 (issue #5)

- INTERFACES.md is **v1 FROZEN**: CSR bus (combinational `csr_rdata`, zero wait states),
  full CSR map with exact HWCFG/STATUS packings, CMP_SEL lane-window comparator addressing,
  BUF_DATA lane-sequenced pop, TS_LO shadow latch, cfg_err/force_trig/soft_rst behavior,
  and the frame envelope (opcodes, all multi-byte fields big-endian).
- `scope_csr` holds all trigger-engine configuration (4 comparators × 4 fields ×
  ⌈PROBE_W/32⌉ lanes, TRIG_COMBINE, SEQ_CNT0..3) and exports it flat-packed for
  `scope_trigger` (issue #6): comparator k at `[k*PROBE_W +: PROBE_W]`, stage n at
  `[n*32 +: 32]`.
- force_trig is a *pending* latch in `scope_csr` held into the core's `trig` input until
  accepted — this is what makes CTRL.force_trig robust across `sample_valid` gaps and the
  FILLING→ARMED boundary.

### M3 (issue #6)

- `scope_trigger`: 4 comparators (level+edge per INTERFACES.md "Trigger semantics") +
  4-stage sequencer with occurrence counters and disabled-stage skipping. Fully registered;
  **probe→trig latency = 2 cycles**, compensated by the module's own 2-cycle `sample_o`
  delay path so `buffer[TRIG_INDEX]` is the satisfying sample (asserted end-to-end in
  `tb_trigger_seq` against `scope_ref.py`'s `trigger_model`).
- `run` input gates the sequencer (`scope_top` wires it to `state==ARMED`); one fire per
  run assertion; parked at the first enabled stage while low.
- Formal (SBY, smtbmc/z3): `formal/scope_core.sby` proves properties (a) trigger sample
  never lost (1-sample shadow + no-overwrite-in-window, with inductive distance invariants)
  and (b) write pointer frozen in DONE/IDLE — **both BMC (depth 60) and full k-induction
  (depth 25) pass** at PROBE_W=4/DEPTH_LOG2=3. CI runs them via the OSS CAD Suite.
- Tool notes: yosys 0.33 requires fully-qualified package refs (no `import`) — applied to
  `scope_core`. Verilator 5.020 does not propagate procedural part-select writes to
  >64-bit signals into continuous assigns (minimal repro during #6); TBs assign wide config
  vectors whole.

### M0 (issues #2, #3)

- Repo skeleton, sim harness, and CI follow the sibling `../hyperram` repo verbatim
  (`sim/run.sh` contract, `TB_RESULT: PASS/FAIL`, `verilator --binary --timing -Wall`).
- The external `fpgapa-prim` dependency named in PLAN.md does not exist; the primitives are
  vendored under `rtl/prim/` (issue #3), written to be extracted later unchanged.
- FWFT discipline (both FIFOs): the oldest word is prefetched into an output register
  whenever the ring is non-empty and the register is empty or being popped, so `rd_data`
  never changes under a stalled consumer and throughput is 1 word/cycle.
- `prim_fifo_async` reset contract: assert `wrst` and `rrst` together (overlapping), each
  ≥ `SYNC_STAGES`+2 cycles of its own clock; each side is inert (ready/valid low) while its
  reset is asserted, so nothing crosses during reset. Asserted in `tb_prim_fifo_async`.
- `tb_prim_fifo_async` soaks ≥110k scoreboarded transfers per leg at 3:1, 1:3, and ~1:1
  drifting-phase clock ratios, with directed fill-to-full/drain-to-empty and flag-exactness
  checks. A fault-injection run (broken full detection) was verified to trip the scoreboard.

## RLE encoder (issue #9)

`rtl/scope_rle.sv` is an optional run-length encoder on the capture sample stream, between the
trigger's aligned probe sample and `scope_core`. It transforms a raw sample stream (one sample
per `in_valid` cycle, never back-pressured) into a stream of `{is_count, value}` words of width
`PROBE_W+1`, emitting **at most one word per cycle**.

**Word format.** `word[PROBE_W]` = `is_count`; `word[PROBE_W-1:0]` = value.
- data word (`is_count=0`): a sample that differs from its predecessor (or the first sample).
- count word (`is_count=1`): "the current data value repeated N more times", N in
  `1..2^CNT_W-1` (`CNT_W = DEPTH_LOG2`); a run longer than that emits successive count words
  (the value is unchanged, so no repeated data word).

```
raw:   A A A A A B B                  (max_run=3)
words: (0,A) (1,3) (1,1) (0,B) (1,1)
       data  cnt=3 cnt=1 data  cnt=1
```

**One word per cycle — the 1-deep skid.** A value change with a pending run count must emit two
words in one cycle (flush the old run's count, then the new data word). That is the only 2-word
case; it requires `acc>0`, and it resets `acc=0`. A subsequent 2-word case needs intervening
repeat cycles, which produce zero words and drain the skid. So the skid never needs more than
one slot — proven by BMC (property (c)): output word count ≤ input sample count + 1 (the single
in-flight skid word), `formal/scope_rle.sby`. `tb_rle` is the complementary exhaustive evidence
(RTL word stream compared byte-for-byte against the `scope_ref.py` golden encoder over
compressible / near-worst-case / wide streams; bypass equivalence checked too).

**Trigger flush (`trig_in`/`trig_out`).** The trigger's raw sample arrives on `trig_in` (sampled
when `in_valid`). `scope_rle` FORCES a clean data word for that sample — flushing any pending
count first — even when the sample repeats its predecessor, so the trigger instant is always a
data-word boundary. A `trig_out` tag rides that data word through the skid, so `scope_core`'s
`trig && sample_valid` lands exactly on the stored trigger word; its decoded value is the raw
trigger sample. (The separate between-samples `flush` input remains for a future window-DONE
flush; scope_top ties it 0 — see the stop semantics below.) Forcing a data word never expands
past the +1 bound (still ≤ 1 word/cycle via the skid) and always decodes back to the raw stream.

**scope_top integration (word-domain, issue #9).** With `RLE_EN=1`, `scope_top` sets
`STORE_W = PROBE_W+1` and threads it through `scope_core`/`scope_csr`/`scope_drain` (the CSR
`BUF_DATA` lane window and the drain's per-sample byte packing widen to `STORE_W`; `PROBE_W`
still drives the comparators and `HWCFG`). `scope_core` stores **words**, its FSM counts
**words**, and `trig_index`/`wrapped`/`PRETRIG` are all **word-domain**. One insight removes the
raw-index sideband the earlier plan assumed: because the encoder **flushes on the trigger**, the
trigger word sits at the same reordered position a non-RLE trigger word would, so the host

1. reorders the *word* buffer chronologically with the existing §host-reconstruction math
   (word units), then
2. `rle_decode`s the reordered words to the raw stream.

`rle_decode` of the trigger-and-later words yields the raw trigger sample at the reconstructed
trigger position — no raw-sample counter needed for correctness. `rle_flag` in the DRAIN header
is the **elaboration-time `RLE_EN`** (the stored words are `STORE_W`-wide `{is_count,value}`),
which tells the host to unpack `STORE_W` and `rle_decode`; runtime `RLE_CTRL[0]` only gates
*compression* (a bypassed build still stores `is_count=0` words that decode to the raw stream).
**PRETRIG is word-domain when RLE is on**, and post-trigger capture stops on the slice filling
with words (a highly-compressible post-trigger signal simply fills more slowly — a documented,
sanctioned deviation from raw-post-budget counting). A reordered window that opens mid-run (its
leading count word's data value lies outside the window) drops those unreconstructable leading
repeats. End-to-end evidence: `host/tests/test_cosim.py` drives the real `scope_top` (RLE_EN=1)
over the co-sim pipe and asserts `decode == raw` with correct trigger reconstruction across
run-length / worst-case / runtime-bypass streams.
