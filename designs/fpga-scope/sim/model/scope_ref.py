#!/usr/bin/env python3
"""scope_ref.py — golden reference model for the fpga-scope capture path (stdlib only).

Replays the same probe stimulus the SystemVerilog testbenches drive and computes the
expected capture-buffer contents, trigger index, and wrapped flag, cycle-exact against
rtl/scope_core.sv. Outputs are $readmemh-compatible .mem files consumed by the TBs.
Invoked from sim/run.sh before the TBs are verilated (no manual pre-steps).

Structure (grows with later issues): capture_model (this issue, #4), trigger_model (#6),
rle_encode (#9) — plus a small CLI.

Stimulus generator: the same address-seeded xorshift32 trick as the hyperram repo's
rtl/bench/hyperram_bw_test.sv gen_pattern() (x ^= x<<7; x ^= x>>9; x ^= x<<8), seeded per
sample index, folded/concatenated to PROBE_W. Pure function of (seed, sample index), so the
model and any future SV re-implementation agree without stored expectation memories.
"""

import argparse
import sys

MASK32 = 0xFFFFFFFF


def xorshift32(x: int) -> int:
    """One round of the hyperram_bw_test.sv gen_pattern() xorshift (32-bit)."""
    x &= MASK32
    x ^= (x << 7) & MASK32
    x ^= x >> 9
    x ^= (x << 8) & MASK32
    return x & MASK32


def gen_stimulus(seed: int, count: int, probe_w: int) -> list[int]:
    """Deterministic probe stream: sample k is xorshift32 chunks seeded by (seed + k)."""
    chunks = (probe_w + 31) // 32
    stim = []
    for k in range(count):
        word = 0
        x = (seed + k) & MASK32
        for c in range(chunks):
            x = xorshift32(x ^ (0x9E3779B9 * (c + 1) & MASK32))
            word |= x << (32 * c)
        stim.append(word & ((1 << probe_w) - 1))
    return stim


def capture_model(stim, depth_log2, pretrig, trig_sample):
    """Cycle-exact replay of scope_core's capture datapath from the first ARMED-phase-or-
    FILLING-phase sample (sample index 0 = first sample presented after arm, sample_valid
    high every cycle). `trig` is high during sample index `trig_sample`.

    Semantics mirrored from rtl/scope_core.sv:
      * FILLING stores exactly `pretrig` samples, then ARMED (transition uses the post-
        update fill count, so no extra FILLING sample is stored).
      * A trigger is accepted only in ARMED; the sample presented in the trig cycle IS the
        trigger sample, is stored, and its buffer address is trig_index.
      * The trigger sample counts as the first of the DEPTH-PRETRIG post samples; DONE is
        entered the cycle after the last post sample is stored.
      * wrapped = write pointer passed DEPTH once since arm (a write hit address DEPTH-1).

    Returns (buf, trig_index, wrapped, samples_consumed).
    """
    depth = 1 << depth_log2
    assert 0 <= pretrig < depth, "pretrig must be 0..DEPTH-1"
    assert trig_sample >= pretrig, "trigger must arrive at/after the ARMED transition"

    buf = [None] * depth
    st = "FILLING"
    wptr = 0
    fill = 0
    post = 0
    wrapped = False
    trig_index = None

    for k, sample in enumerate(stim):
        trig = k == trig_sample
        wr = st in ("FILLING", "ARMED") or (st == "TRIGGERED" and post != 0)
        acc = trig and st == "ARMED"
        fill_wr = wr and st == "FILLING"
        post_wr = wr and st == "TRIGGERED"

        if wr:
            buf[wptr] = sample
            if wptr == depth - 1:
                wrapped = True

        fill_next = fill + (1 if fill_wr else 0)
        post_next = post - (1 if post_wr else 0)

        if acc:
            trig_index = wptr
            post = depth - pretrig - 1
        else:
            post = post_next
        if wr:
            wptr = (wptr + 1) % depth
        fill = fill_next

        if st == "FILLING" and fill_next >= pretrig:
            st = "ARMED"
        elif st == "ARMED" and acc:
            st = "TRIGGERED"
        elif st == "TRIGGERED" and post_next == 0:
            st = "DONE"

        if st == "DONE":
            assert all(v is not None for v in buf), "completed capture must fill the buffer"
            return buf, trig_index, wrapped, k + 1

    raise SystemExit("scope_ref.py: stimulus exhausted before capture completed "
                     "(need >= trig_sample + DEPTH - pretrig samples)")


def write_mem(path, values, hex_digits):
    with open(path, "w") as f:
        for v in values:
            f.write(f"{v:0{hex_digits}x}\n")


# ---------------------------------------------------------------------------------------
# Multi-window capture model (issue #7) — cycle-exact vs rtl/scope_core.sv.
# ---------------------------------------------------------------------------------------

def weff_log2_of(windows, depth_log2):
    w = max(1, windows)
    r = 0
    while (1 << r) < w:
        r += 1
    return min(r, depth_log2 - 1)


def windows_model(stim, depth_log2, pretrig, windows, trig_rel):
    """Cycle-exact multi-window replay of scope_core. stim[k] is presented on cycle k with
    sample_valid=1 (cycle 0 = the first cycle in FILLING after arm). Trigger scheduling:
    trig_rel[w] = number of ARMED cycles window w waits before its trigger pulse (so the
    trigger sample is the (trig_rel[w]+1)-th ARMED sample of that window); the chosen
    ABSOLUTE trigger cycles are returned for the TB to drive.

    Slicing semantics (INTERFACES.md "Capture semantics", DESIGN.md):
      W_eff = 2^ceil(log2(windows)) clamped to DEPTH/2; SLICE = DEPTH / W_eff;
      pretrig_eff = pretrig >> log2(W_eff); post budget = SLICE - pretrig_eff (trigger
      sample = post #1); window w captures into slice w; one DONE cycle between windows.

    Returns (buf, per_window list of dicts {trig_cycle, trig_index, wrapped}, cycles_used).
    Unwritten buffer entries are None.
    """
    depth = 1 << depth_log2
    weff = weff_log2_of(windows, depth_log2)
    slice_mask = (depth - 1) >> weff
    p_eff = pretrig >> weff

    buf = [None] * depth
    st = "FILLING"
    base = 0
    off = 0
    fill = 0
    post = 0
    wrapped = False
    win = 0
    armed_seen = 0
    trig_index = None
    acc_cycle = None
    meta = []

    for k, s in enumerate(stim):
        trig = (st == "ARMED") and (armed_seen == trig_rel[win])
        wr = st in ("FILLING", "ARMED") or (st == "TRIGGERED" and post != 0)
        acc = trig  # trig only generated in ARMED here
        fill_wr = wr and st == "FILLING"
        post_wr = wr and st == "TRIGGERED"

        if st == "ARMED":
            armed_seen += 1
        if wr:
            buf[base | off] = s
            if off == slice_mask:
                wrapped = True

        fill_next = fill + (1 if fill_wr else 0)
        post_next = post - (1 if post_wr else 0)

        if acc:
            trig_index = base | off
            acc_cycle = k
            post = slice_mask - p_eff
        else:
            post = post_next
        if wr:
            off = (off + 1) & slice_mask
        fill = fill_next

        if st == "FILLING" and fill_next >= p_eff:
            st = "ARMED"
        elif st == "ARMED" and acc:
            st = "TRIGGERED"
        elif st == "TRIGGERED" and post_next == 0 and not acc:
            # window complete (state-update edge; the DONE state occupies cycle k+1)
            meta.append(dict(trig_cycle=acc_cycle, trig_index=trig_index, wrapped=wrapped))
            st = "DONE"
        elif st == "DONE":
            win += 1
            if win < windows:
                base = (base + slice_mask + 1) & (depth - 1)
                off = 0
                fill = 0
                wrapped = False
                armed_seen = 0
                st = "FILLING"
            else:
                return buf, meta, k + 1

    raise SystemExit("scope_ref.py: stimulus exhausted before all windows completed")

def trigger_model(stim, probe_w, cmp_cfg, combine, seq_cnt, prev0=0):
    """Replays rtl/scope_trigger.sv in SAMPLE terms (the RTL's registered pipeline shifts
    everything by a constant LATENCY=2 cycles; alignment is restored by its delayed
    sample_o path, so sample indices are the shared currency).

    cmp_cfg: list of 4 (mask, value, edge_mask, edge_pol) tuples.
    combine: TRIG_COMBINE word — stage n at bits [8n+7:8n]: [3:0] select, [4] AND mode.
    seq_cnt: list of 4 occurrence targets (0 treated as 1).
    prev0:   probe value in the cycle before stim[0] (TBs idle the probe at 0).

    Returns (per-sample cmp_hit nibbles, fire sample index or None). The fire index is the
    sample that satisfied the final enabled stage — the host-visible trigger sample.
    """
    wmask = (1 << probe_w) - 1
    sel = [(combine >> (8 * n)) & 0xF for n in range(4)]
    andm = [(combine >> (8 * n + 4)) & 0x1 for n in range(4)]
    en = [s != 0 for s in sel]
    tgt = [max(1, c) for c in seq_cnt]

    def next_en(frm):
        for i in range(frm, 4):
            if en[i]:
                return i
        return None

    cur = next_en(0)
    occ = 0
    fired = None
    prev = prev0 & wmask
    hits_list = []

    for i, s in enumerate(stim):
        s &= wmask
        hits = 0
        rise = ~prev & s & wmask
        fall = prev & ~s & wmask
        for k, (m, v, em, ep) in enumerate(cmp_cfg):
            level = (s & m) == v
            edge = True if em == 0 else (em & ((ep & rise) | (~ep & wmask & fall))) != 0
            if level and edge:
                hits |= 1 << k
        hits_list.append(hits)

        if cur is not None and fired is None:
            sh = (hits & sel[cur]) == sel[cur] if andm[cur] else (hits & sel[cur]) != 0
            if sh:
                if occ + 1 >= tgt[cur]:
                    nxt = next_en(cur + 1)
                    if nxt is None:
                        fired = i
                    else:
                        cur, occ = nxt, 0
                else:
                    occ += 1
        prev = s
    return hits_list, fired


def _biased_stim(seed, count, probe_w, value, mask, edge_bits):
    """Probe stream with decent hit density: mix of pure xorshift randomness, forced
    level matches (value | rand-outside-mask), and edge-bit toggles both directions."""
    wmask = (1 << probe_w) - 1
    stim = []
    x = seed & MASK32
    cur = 0
    for i in range(count):
        x = xorshift32(x + i)
        r = 0
        for c in range((probe_w + 31) // 32):
            x = xorshift32(x ^ (c * 0x9E3779B9 & MASK32))
            r |= x << (32 * c)
        r &= wmask
        m = x % 10
        if m < 4:
            cur = r  # pure random
        elif m < 7:
            cur = (value | (r & ~mask)) & wmask  # forced level match
        else:
            cur = cur ^ (edge_bits & r if (x >> 8) & 1 else edge_bits)  # edge toggles
        stim.append(cur)
    return stim


def _trigger_cases(suite, probe_w):
    """Handcrafted + biased-random case list. Each case: dict with cmp_cfg (4 tuples),
    combine, seq_cnt, stim."""
    w = probe_w
    wmask = (1 << w) - 1
    b = lambda i: 1 << (i % w)
    cases = []
    if suite == "cmp":
        spc = 400
        # combine=0: no stage enabled — cmp TB checks per-cycle hits only, trig must not fire
        base = dict(combine=0x00000000, seq_cnt=[1, 1, 1, 1])
        # 1: level-only on all 4 units (distinct masks/values)
        cases.append(dict(base, cmp_cfg=[
            (0xFF & wmask, 0xA5 & wmask, 0, 0),
            (0xF0 & wmask, 0x50 & wmask, 0, 0),
            ((0xFF00 if w >= 16 else 0xF) & wmask, (0x1200 if w >= 16 else 0x5) & wmask, 0, 0),
            (wmask, 0x1234 & wmask, 0, 0)],
            stim=_biased_stim(0x11, spc, w, 0xA5 & wmask, 0xFF & wmask, b(0))))
        # 2: edge-only rising / falling / both / multi-bit
        cases.append(dict(base, cmp_cfg=[
            (0, 0, b(0), b(0)),          # rising bit 0
            (0, 0, b(0), 0),             # falling bit 0
            (0, 0, b(3) | b(7), b(3)),   # rise b3 OR fall b7
            (0, 0, (b(1) | b(2) | b(5)), (b(1) | b(2) | b(5)))],
            stim=_biased_stim(0x22, spc, w, 0, 0, b(0) | b(3) | b(7) | b(1) | b(2) | b(5))))
        # 3: level+edge combined
        cases.append(dict(base, cmp_cfg=[
            (0xF0 & wmask, 0xA0 & wmask, b(0), b(0)),
            (0x0F & wmask, 0x05 & wmask, b(4), 0),
            (0xFF & wmask, 0x5A & wmask, b(7) | b(6), b(7)),
            (0x03 & wmask, 0x02 & wmask, b(1), b(1))],
            stim=_biased_stim(0x33, spc, w, 0xA0 & wmask, 0xF0 & wmask, b(0) | b(4) | b(7) | b(6) | b(1))))
        # 4: all-zero mask (always-hit level), always-hit unit, alternating X-adjacent stim
        cases.append(dict(base, cmp_cfg=[
            (0, 0, 0, 0),                 # always hits every cycle
            (0, 0, wmask, wmask),         # any rising edge anywhere
            (0, 0, wmask, 0),             # any falling edge anywhere
            (wmask, 0x5555 & wmask, 0, 0)],
            stim=[(0x5555 & wmask) if i % 2 == 0 else (0xAAAA & wmask) for i in range(spc)]))
        # 5-6: biased-random configs
        for s in (0x55, 0x66):
            x = xorshift32(s)
            cfg = []
            for k in range(4):
                x = xorshift32(x + k)
                m = x & wmask
                x = xorshift32(x)
                v = x & m
                x = xorshift32(x)
                em = x & wmask if (x & 3) == 0 else (x & 0xF & wmask)
                x = xorshift32(x)
                ep = x & em
                cfg.append((m, v, em, ep))
            cases.append(dict(base, cmp_cfg=cfg,
                              stim=_biased_stim(s, spc, w, cfg[0][1], cfg[0][0], cfg[1][2] | 1)))
    else:  # seq
        spc = 3000
        # common comparators: 0 = easy level hit, 1 = edge, 2 = harder level, 3 = impossible
        cmp_cfg = [
            (0x3 & wmask, 0x1 & wmask, 0, 0),   # ~1/4 of samples
            (0, 0, b(0), b(0)),                 # rising bit0
            (0x7 & wmask, 0x5 & wmask, 0, 0),   # ~1/8
            (0, 1 & wmask, 0, 0),               # (probe & 0)==1: never
        ]
        stim0 = _biased_stim(0x77, spc, w, 0x1, 0x3, b(0))
        mk = lambda combine, seq_cnt, stim=None: dict(
            cmp_cfg=cmp_cfg, combine=combine, seq_cnt=seq_cnt, stim=stim or stim0)
        cases.append(mk(0x00000001, [1, 1, 1, 1]))              # 1-stage OR cmp0, first hit
        cases.append(mk(0x00000001, [5, 1, 1, 1]))              # 1-stage, 5 occurrences
        cases.append(mk(0x00000301, [2, 1, 1, 1]))              # 2-stage: cmp0 x2 then cmp0|cmp1
        cases.append(mk(0x00130201, [1, 2, 5, 1]))              # 3-stage: cmp0, cmp1 x2, AND(cmp0&cmp1) x5
        cases.append(mk(0x04020104 | (1 << 28), [2, 1, 255, 1],
                        _biased_stim(0x88, spc, w, 0x1, 0x3, b(0))))  # 4-stage with 255 occurrences
        cases.append(mk(0x00010004, [1, 1, 1, 1]))              # disabled stages skipped (0 and 2 en... see note)
        cases.append(mk(0x00000008, [1, 1, 1, 1]))              # never fires: cmp3 impossible
    return cases


# ---------------------------------------------------------------------------------------
# Run-length encoder / decoder (issue #9). Words are (is_count, value):
#   * data word  (is_count=0): value = a probe sample that differs from its predecessor.
#   * count word (is_count=1): value = N, "the current data value repeated N more times",
#     N in 1..(2^CNT_W - 1); a run longer than that emits successive count words (the data
#     value is unchanged, so no new data word is needed after a saturated count).
# Alternating input => all data words, no counts => words == samples (no expansion). Any
# run of length R>=2 => 1 + ceil((R-1)/max_run) words <= R. So words <= samples always; the
# RTL adds at most one in-flight (skid) word at flush, i.e. words <= samples + 1 (formal c).
# ---------------------------------------------------------------------------------------

def rle_encode(samples, cnt_w):
    """Return the canonical (is_count, value) word list for a raw sample list."""
    max_run = (1 << cnt_w) - 1
    words = []
    i, n = 0, len(samples)
    while i < n:
        v = samples[i]
        words.append((0, v))       # data word (value changed, or first sample)
        i += 1
        while i < n and samples[i] == v:
            r = 0
            while i < n and samples[i] == v and r < max_run:
                r += 1
                i += 1
            words.append((1, r))   # count word: v repeated r more times
    return words


def rle_decode(words):
    """Inverse of rle_encode: (is_count, value) words -> raw sample list."""
    out, v = [], None
    for is_count, val in words:
        if is_count == 0:
            v = val
            out.append(v)
        else:
            out += [v] * val
    return out


def rle_selftest():
    """decode(encode(x)) == x across directed + pseudo-random inputs and count widths."""
    directed = [
        [], [5], [7, 7, 7, 7], [1, 2, 3, 4, 5], [9, 9, 8, 8, 8, 9],
        [0] * 300, [i % 2 for i in range(200)], [3] * 1 + [4] * 40 + [3] * 40,
    ]
    for cnt_w in (2, 3, 8, 12):
        for x in directed:
            assert rle_decode(rle_encode(x, cnt_w)) == x, (cnt_w, x[:8])
        x = 0xDEADBEEF
        for probe_w in (4, 8):
            seq = []
            for _ in range(2000):
                x = xorshift32(x)
                # bias toward runs: sometimes repeat the previous value
                seq.append(seq[-1] if seq and (x & 3) else (x & ((1 << probe_w) - 1)))
            assert rle_decode(rle_encode(seq, cnt_w)) == seq, (cnt_w, probe_w)
    return True


def cmd_rle(args):
    """Emit RLE vectors for tb_rle: raw samples, encoded words {is_count<<PROBE_W | value},
    and meta (sample count, word count). Word .mem digits cover PROBE_W+1 bits."""
    rle_selftest()
    if args.stim_in:
        with open(args.stim_in) as f:
            samples = [int(line, 16) for line in f if line.strip()]
    else:
        samples = gen_stimulus(args.seed, args.count, args.probe_w)
        if args.runs:  # bias toward runs: hold each value for a pseudo-random dwell
            held, x = [], args.seed & MASK32
            for s in samples:
                x = xorshift32(x)
                held += [s] * (1 + (x % args.runs))
            samples = held[:args.count] if args.count <= len(held) else held
    words = rle_encode(samples, args.cnt_w)
    packed = [((ic & 1) << args.probe_w) | (val & ((1 << args.probe_w) - 1))
              for ic, val in words]
    sdig = (args.probe_w + 3) // 4
    wdig = (args.probe_w + 1 + 3) // 4
    write_mem(f"{args.out_prefix}_samples.mem", samples, sdig)
    write_mem(f"{args.out_prefix}_words.mem", packed, wdig)
    write_mem(f"{args.out_prefix}_meta.mem", [len(samples), len(words)], 16)
    assert rle_decode(words) == samples, "rle_encode/decode mismatch in cmd_rle"
    assert len(words) <= len(samples) + 1, "expansion bound violated"
    print(f"scope_ref: {args.out_prefix}: {len(samples)} samples -> {len(words)} words "
          f"(cnt_w={args.cnt_w})")


def cmd_trigger_suite(args):
    cases = _trigger_cases(args.suite, args.probe_w)
    digits = (args.probe_w + 3) // 4
    stim_all, hits_all, cfg_all, meta = [], [], [], []
    spc = max(len(c["stim"]) for c in cases)
    for c in cases:
        stim = c["stim"] + [0] * (spc - len(c["stim"]))
        hits, fire = trigger_model(stim, args.probe_w, c["cmp_cfg"], c["combine"],
                                   c["seq_cnt"], prev0=0)
        if args.suite == "seq" and fire is None and c["combine"] != 0x00000008:
            raise SystemExit(f"scope_ref: seq case did not fire (combine={c['combine']:#x})")
        stim_all += stim
        hits_all += hits
        for k in range(4):
            cfg_all += list(c["cmp_cfg"][k])
        cfg_all += [c["combine"]] + list(c["seq_cnt"])
        meta.append(0xFFFF_FFFF_FFFF_FFFF if fire is None else fire)
    write_mem(f"{args.out_prefix}_stim.mem", stim_all, digits)
    write_mem(f"{args.out_prefix}_hits.mem", hits_all, 1)
    write_mem(f"{args.out_prefix}_cfg.mem", cfg_all, 16)  # 21 x 64-bit lines per case
    # meta: line 0 = case count, line 1 = samples per case, then one fire index per case
    write_mem(f"{args.out_prefix}_meta.mem", [len(cases), spc] + meta, 16)
    print(f"scope_ref: {args.out_prefix}: {len(cases)} {args.suite} cases x {spc} samples")


def crc16_ccitt(data, crc=0xFFFF):
    """CRC16-CCITT poly 0x1021 init 0xFFFF, MSB-first — the wire CRC (independent of the
    SV implementation in scope_pkg)."""
    for b in data:
        crc ^= (b & 0xFF) << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def cmd_drain_data(args):
    """Expected DRAIN_DATA frame byte stream (issue #8) for a buffer .mem produced by the
    capture/windows models: chunked frames of SPF=min(DEPTH,256) samples, each sample
    packed little-endian into ceil(PROBE_W/8) bytes, envelope + CRC per INTERFACES.md."""
    with open(args.buf_in) as f:
        buf = [int(line, 16) for line in f if line.strip()]
    depth = len(buf)
    nb = (args.probe_w + 7) // 8
    spf = min(depth, 256)
    chunks = depth // spf
    out = []
    for c in range(chunks):
        payload = [(c >> 8) & 0xFF, c & 0xFF]
        for s_i in range(c * spf, (c + 1) * spf):
            payload += [(buf[s_i] >> (8 * i)) & 0xFF for i in range(nb)]
        body = [0x05] + [(len(payload) >> 8) & 0xFF, len(payload) & 0xFF] + payload
        crc = crc16_ccitt(body)
        out += [0xA5, 0x5C] + body + [(crc >> 8) & 0xFF, crc & 0xFF]
    write_mem(f"{args.out_prefix}_dframes.mem", out, 2)
    print(f"scope_ref: {args.out_prefix}: {chunks} DRAIN_DATA frames, {len(out)} bytes")


def cmd_capture(args):
    if args.stim_in:
        with open(args.stim_in) as f:
            stim = [int(line, 16) for line in f if line.strip()]
    else:
        stim = gen_stimulus(args.seed, args.count, args.probe_w)
        if args.idle_prefix:
            stim = [0] * args.idle_prefix + stim[:len(stim) - args.idle_prefix]

    buf, trig_index, wrapped, consumed = capture_model(
        stim, args.depth_log2, args.pretrig, args.trig_sample)

    digits = (args.probe_w + 3) // 4
    write_mem(f"{args.out_prefix}_stim.mem", stim, digits)
    write_mem(f"{args.out_prefix}_buf.mem", buf, digits)
    # meta: word 0 = trig_index, word 1 = wrapped, word 2 = samples consumed
    write_mem(f"{args.out_prefix}_meta.mem", [trig_index, int(wrapped), consumed], 16)
    print(f"scope_ref: {args.out_prefix}: {len(stim)} stimulus samples, "
          f"trig_index={trig_index}, wrapped={int(wrapped)}, consumed={consumed}")


def cmd_windows(args):
    trig_rel = [int(x, 0) for x in args.trig_rel.split(",")]
    assert len(trig_rel) == args.windows, "--trig-rel needs one entry per window"
    stim = gen_stimulus(args.seed, args.count, args.probe_w)
    buf, meta, cycles = windows_model(stim, args.depth_log2, args.pretrig, args.windows,
                                      trig_rel)
    digits = (args.probe_w + 3) // 4
    write_mem(f"{args.out_prefix}_stim.mem", stim, digits)
    write_mem(f"{args.out_prefix}_buf.mem", [0 if v is None else v for v in buf], digits)
    m = [args.windows, cycles]
    for w in meta:
        m += [w["trig_cycle"], w["trig_index"], int(w["wrapped"])]
    write_mem(f"{args.out_prefix}_meta.mem", m, 16)
    print(f"scope_ref: {args.out_prefix}: {args.windows} windows in {cycles} cycles, "
          f"trig_cycles={[w['trig_cycle'] for w in meta]}")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("capture", help="expected capture-buffer contents for tb_capture_*")
    c.add_argument("--probe-w", type=int, required=True)
    c.add_argument("--depth-log2", type=int, required=True)
    c.add_argument("--pretrig", type=int, default=0)
    c.add_argument("--trig-sample", type=int, required=True,
                   help="sample index (from arm) that carries the trigger")
    c.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE01)
    c.add_argument("--count", type=int, required=True, help="stimulus samples to generate")
    c.add_argument("--stim-in", default=None,
                   help="read stimulus from file (one hex vector per line) instead of generating")
    c.add_argument("--idle-prefix", type=int, default=0,
                   help="replace the first N stimulus entries with 0 (pre-arm idle probe)")
    c.add_argument("--out-prefix", required=True)
    c.set_defaults(func=cmd_capture)

    d = sub.add_parser("drain-data", help="expected DRAIN_DATA frame bytes for tb_drain_cdc")
    d.add_argument("--probe-w", type=int, required=True)
    d.add_argument("--buf-in", required=True, help="buffer .mem from a capture/windows run")
    d.add_argument("--out-prefix", required=True)
    d.set_defaults(func=cmd_drain_data)

    w = sub.add_parser("windows", help="multi-window capture expectation for tb_windows")
    w.add_argument("--probe-w", type=int, required=True)
    w.add_argument("--depth-log2", type=int, required=True)
    w.add_argument("--pretrig", type=int, default=0)
    w.add_argument("--windows", type=int, required=True)
    w.add_argument("--trig-rel", required=True,
                   help="comma list: ARMED cycles each window waits before its trigger")
    w.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE07)
    w.add_argument("--count", type=int, required=True)
    w.add_argument("--out-prefix", required=True)
    w.set_defaults(func=cmd_windows)

    t = sub.add_parser("trigger-suite",
                       help="comparator/sequencer case suites for tb_trigger_cmp/seq")
    t.add_argument("--suite", choices=["cmp", "seq"], required=True)
    t.add_argument("--probe-w", type=int, required=True)
    t.add_argument("--out-prefix", required=True)
    t.set_defaults(func=cmd_trigger_suite)

    r = sub.add_parser("rle", help="RLE encode vectors for tb_rle (+ built-in decode-identity)")
    r.add_argument("--probe-w", type=int, required=True)
    r.add_argument("--cnt-w", type=int, required=True, help="count-word field width (= DEPTH_LOG2)")
    r.add_argument("--count", type=int, required=True, help="number of raw samples")
    r.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE09)
    r.add_argument("--runs", type=int, default=0,
                   help="if >0, bias toward runs (max dwell length); 0 = raw xorshift stream")
    r.add_argument("--stim-in", default=None)
    r.add_argument("--out-prefix", required=True)
    r.set_defaults(func=cmd_rle)

    args = p.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
