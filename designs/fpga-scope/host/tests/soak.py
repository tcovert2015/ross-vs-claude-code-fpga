#!/usr/bin/env python3
"""Random-config soak for the fpga-scope capture path (issue #13, acceptance gate 1).

Runs N seeded random configs through the Verilator co-simulation of the REAL scope_top and checks
each capture end-to-end (drain -> host reorder + RLE decode -> compare against scope_ref for the
same seed). Not a pytest (it's minutes-long) — invoked by sim/soak.sh, on demand + nightly CI.

Randomized per config: seed, PRETRIG, trigger sample, RLE on/off, decimation. (PROBE_W/DEPTH_LOG2
are fixed by the co-sim binary at 32/12; the random-width sweep is the standalone util build.)
Not seeded from wall-clock: the RNG seed is an argument so a failing config is reproducible.
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))
sys.path.insert(0, str(ROOT / "host" / "tests"))
sys.path.insert(0, str(ROOT / "sim" / "model"))

import random
import scope_ref
from fpgapa_scope import csr as C
from fpgapa_scope.scope import Scope
from fpgapa_scope.reorder import reorder_window
from fpgapa_scope.rle import rle_decode_words
import cosim_util

DEPTH_LOG2, DEPTH, PROBE_W = 8, 256, 32   # matches sim/tb_cosim.sv


def _expected_nonrle(seed, pretrig, trig_sample):
    count = trig_sample + DEPTH + 8
    gen = scope_ref.gen_stimulus(seed, count, PROBE_W)
    stim = [0, 0] + gen[:count - 2]
    buf, ti, wr, _ = scope_ref.capture_model(stim, DEPTH_LOG2, pretrig, trig_sample)
    return buf, ti, wr


def run_config(binary_norle, binary_rle, cfg, mdir):
    seed, pretrig, trig_sample, rle, decim = cfg
    binary = binary_rle if rle else binary_norle
    with cosim_util.CosimTransport(binary, seed, trig_sample,
                                   mdir / "soak.stderr", dwell=1,
                                   probe_mode=(1 if decim else 0)) as t:
        sc = Scope(t, probe_w=PROBE_W)
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, 0 if decim else pretrig)
        if rle:
            sc.write_csr(C.RLE_CTRL, 1)
        if decim:
            sc.write_csr(C.SMPL_CTRL, C.smpl_ctrl(decim=decim))
        assert not sc.status()["cfg_err"], "cfg_err"
        sc.arm()
        assert sc.wait_done(timeout=25.0), "no DONE"
        cap = sc.drain(pretrig_eff=(0 if decim else pretrig))

    if decim:                                   # counter probe: exact spacing check
        assert len(cap.samples) == DEPTH
        steps = {(cap.samples[i + 1] - cap.samples[i]) & 0xFFFFFFFF for i in range(len(cap.samples) - 1)}
        assert steps == {decim + 1}, f"decim spacing {steps}"
    elif rle:                                   # RLE (pretrig=0): decode == raw stimulus run
        assert cap.rle and cap.samples[0] is not None
        gen = scope_ref.gen_stimulus(seed, trig_sample + 4 * DEPTH + 8, PROBE_W)
        raw = lambda k: 0 if k < 2 else gen[k - 2]
        assert cap.trig_pos == 0
        for i, s in enumerate(cap.samples):
            assert s == raw(trig_sample + i), f"rle sample {i}"
    else:                                       # plain capture: buffer == golden model
        buf, ti, wr = _expected_nonrle(seed, pretrig, trig_sample)
        assert cap.raw_buffer == buf and cap.trig_index == ti and cap.wrapped == wr
        ordered, _ = reorder_window(buf, ti, wr, pretrig)
        assert cap.samples == ordered
    return len(cap.samples)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--configs", type=int, default=20)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x50A4, help="RNG seed (reproducible)")
    args = ap.parse_args(argv)

    if not cosim_util.have_verilator():
        print("SOAK SKIP: verilator not installed")
        return 0

    import tempfile
    mdir = Path(tempfile.mkdtemp(prefix="soak_"))
    print("building co-sim binaries…")
    b0 = cosim_util.build_cosim(mdir / "norle", rle_en=False)
    b1 = cosim_util.build_cosim(mdir / "rle", rle_en=True)

    rng = random.Random(args.seed)
    total = 0
    for n in range(args.configs):
        rle = rng.random() < 0.4
        decim = rng.choice([0, 0, 3, 7]) if not rle else 0    # decim uses the counter probe
        pretrig = 0 if (rle or decim) else rng.choice([0, 16, 64, 128, 250])
        trig_sample = rng.randint(260, 600)
        cfg = (rng.randint(1, 0xFFFFFFFF), pretrig, trig_sample, rle, decim)
        try:
            got = run_config(b0, b1, cfg, mdir)
        except AssertionError as e:
            print(f"SOAK FAIL config {n} {cfg}: {e}")
            return 1
        total += got
        print(f"[{n + 1}/{args.configs}] seed={cfg[0]:08x} pretrig={cfg[1]} "
              f"trig={cfg[2]} rle={rle} decim={decim} -> {got} samples OK")
    print(f"SOAK PASS: {args.configs} configs, {total} decoded samples, all match scope_ref")
    return 0


if __name__ == "__main__":
    sys.exit(main())
