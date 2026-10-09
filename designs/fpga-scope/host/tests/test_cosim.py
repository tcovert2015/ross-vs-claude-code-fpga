"""Verilator co-simulation: the Python host drives the REAL scope_top over a byte pipe,
end-to-end, and the decoded capture is checked byte-for-byte against scope_ref.py for the
same seed. This is the issue-#10 milestone gate ("pytest green against Verilator co-sim").

Auto-skips when verilator is not installed, so the pure-Python unit tests still run anywhere.
"""
import pytest

import scope_ref
from fpgapa_scope import csr as C, frame
from fpgapa_scope.scope import Scope
from fpgapa_scope.reorder import reorder_window
from fpgapa_scope.vcd import write_vcd
from fpgapa_scope.sigrok import write_sr

import cosim_util

PROBE_W = 32
DEPTH_LOG2 = 8
DEPTH = 1 << DEPTH_LOG2

pytestmark = pytest.mark.skipif(not cosim_util.have_verilator(),
                                reason="verilator not installed")


@pytest.fixture(scope="session")
def cosim_binary(tmp_path_factory):
    mdir = tmp_path_factory.mktemp("cosim_build")
    return cosim_util.build_cosim(mdir, rle_en=False)


@pytest.fixture(scope="session")
def cosim_binary_rle(tmp_path_factory):
    mdir = tmp_path_factory.mktemp("cosim_build_rle")
    return cosim_util.build_cosim(mdir, rle_en=True)


def _expected(seed, pretrig, trig_sample):
    """Golden capture buffer + trigger metadata from scope_ref, using the SAME idle-prefix-2
    stimulus discipline tb_cosim drives (proven byte-exact by tb_drain_cdc)."""
    count = trig_sample + DEPTH + 8
    gen = scope_ref.gen_stimulus(seed, count, PROBE_W)
    stim = [0, 0] + gen[:count - 2]
    buf, trig_index, wrapped, _ = scope_ref.capture_model(stim, DEPTH_LOG2, pretrig, trig_sample)
    return buf, trig_index, wrapped


# pretrig=0 wraps deep (trig_index=44); pretrig=64 exercises the pre-trigger reorder path.
@pytest.mark.parametrize("seed,pretrig,trig_sample", [
    (0xC0FFEE01, 0, 300),
    (0x1234ABCD, 64, 300),
    (0xBADC0DE9, 0, 260),
])
def test_cosim_end_to_end(cosim_binary, tmp_path, seed, pretrig, trig_sample):
    buf_ref, trig_index_ref, wrapped_ref = _expected(seed, pretrig, trig_sample)

    stderr_log = tmp_path / "tb_cosim.stderr"
    with cosim_util.CosimTransport(cosim_binary, seed, trig_sample, stderr_log) as t:
        sc = Scope(t, probe_w=PROBE_W)

        # -- identify: PING carries ID_REG + the DUT's ID_VALUE parameter --------------------
        fr = sc.ping()
        assert fr.cmd == frame.OP_PING
        assert int.from_bytes(fr.payload[0:4], "big") == C.ID_REG
        assert int.from_bytes(fr.payload[4:8], "big") == 0xF00D1234

        # -- configure over the wire ---------------------------------------------------------
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, pretrig)
        assert not sc.status()["cfg_err"]
        hwcfg = sc.read_csr(C.HWCFG)
        assert (hwcfg & 0x3FF) == PROBE_W          # HWCFG.probe_w low 10 bits

        # -- arm the real core; tb_cosim auto-stimulates from the armed rise -----------------
        sc.arm()
        assert sc.wait_done(timeout=15.0), "capture never reached DONE"
        st = sc.status()
        assert st["triggered"] and st["state"] == C.STATE_DONE

        # -- drain + host decode -------------------------------------------------------------
        cap = sc.drain(pretrig_eff=pretrig)

    # === the acceptance: real RTL buffer == golden model, through the real frame codec =====
    assert cap.raw_buffer == buf_ref, "drained buffer != scope_ref.capture_model"
    assert cap.trig_index == trig_index_ref
    assert cap.wrapped == wrapped_ref

    # reorder consistency: time-ordered window is DEPTH long with the trigger at trig_pos
    ordered_ref, trig_pos_ref = reorder_window(buf_ref, trig_index_ref, wrapped_ref, pretrig)
    assert cap.samples == ordered_ref
    assert len(cap.samples) == DEPTH
    assert cap.trig_pos == trig_pos_ref
    assert cap.samples[cap.trig_pos] == buf_ref[trig_index_ref]

    # -- export the decoded capture and confirm the artifacts are well-formed ---------------
    vcd = tmp_path / "cap.vcd"
    write_vcd(vcd, cap.samples, PROBE_W, trig_pos=cap.trig_pos)
    text = vcd.read_text()
    assert "trigger" in text and "$comment trigger $end" in text

    sr = tmp_path / "cap.sr"
    write_sr(sr, cap.samples, PROBE_W)
    import zipfile
    with zipfile.ZipFile(sr) as z:
        assert len(z.read("logic-1-1")) == DEPTH * (PROBE_W // 8)


# ---- decimation (#20) + storage qualification (#17) ---------------------------------------
# Driven with a free-running counter probe (tb_cosim +probe_mode=1): the stored samples then have
# an exact, phase-independent spacing, so the SMPL_CTRL gating is checked directly on the values.

@pytest.mark.parametrize("decim", [1, 3, 7])
def test_cosim_decimation(cosim_binary, tmp_path, decim):
    with cosim_util.CosimTransport(cosim_binary, 0xC0FFEE01, 400,
                                   tmp_path / "dec.stderr", dwell=1, probe_mode=1) as t:
        sc = Scope(t, probe_w=PROBE_W)
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, 0)
        sc.write_csr(C.SMPL_CTRL, C.smpl_ctrl(decim=decim))   # store 1 sample every (decim+1)
        assert not sc.status()["cfg_err"]
        sc.arm()
        assert sc.wait_done(timeout=20.0), "decimated capture never reached DONE"
        cap = sc.drain(pretrig_eff=0)

    s = cap.samples
    assert len(s) == DEPTH
    steps = {(s[i + 1] - s[i]) & 0xFFFFFFFF for i in range(len(s) - 1)}
    assert steps == {decim + 1}, f"decimation spacing {steps} != {{{decim + 1}}}"


def test_cosim_storage_qualification(cosim_binary, tmp_path):
    with cosim_util.CosimTransport(cosim_binary, 0x1234ABCD, 400,
                                   tmp_path / "qual.stderr", dwell=1, probe_mode=1) as t:
        sc = Scope(t, probe_w=PROBE_W)
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, 0)
        # comparator 0 = level match probe[0]==1 (odd counter): MASK=1, VALUE=1, no edge.
        sc.write_csr(C.CMP_SEL, (C.CMP_FIELD_MASK << 2) | 0);  sc.write_csr(C.CMP_LANE_BASE, 0x1)
        sc.write_csr(C.CMP_SEL, (C.CMP_FIELD_VALUE << 2) | 0); sc.write_csr(C.CMP_LANE_BASE, 0x1)
        sc.write_csr(C.TRIG_COMBINE, 0)     # comparator is the qualifier only; trigger is ext
        sc.write_csr(C.SMPL_CTRL, C.smpl_ctrl(qual_en=True, qual_sel=0))
        assert not sc.status()["cfg_err"]
        sc.arm()
        assert sc.wait_done(timeout=20.0), "qualified capture never reached DONE"
        cap = sc.drain(pretrig_eff=0)

    s = cap.samples
    assert len(s) == DEPTH
    assert all(v & 1 for v in s), "every stored sample must be odd (the qualifier condition)"
    steps = {(s[i + 1] - s[i]) & 0xFFFFFFFF for i in range(len(s) - 1)}
    assert steps == {2}, f"qualified spacing {steps} != {{2}} (consecutive odd counter values)"


def _raw_func(seed, dwell, count):
    """The raw sample stream scope_rle sees, indexed by capture-model sample index k: the
    2-cycle idle prefix (probe = 0 before arm) then gen_stimulus held `dwell` cycles each —
    exactly what tb_cosim drives as probe(sidx)=gen(seed, sidx//dwell), sample k <- probe(k-2)."""
    gen = scope_ref.gen_stimulus(seed, count, PROBE_W)
    return lambda k: 0 if k < 2 else gen[(k - 2) // dwell]


# RLE co-sim (scope_top RLE_EN=1): the store path is {is_count,value} words; the host reorders
# in the word domain then rle_decodes. dwell>1 makes runs so count words are exercised; the
# rle_enable=0 leg is the runtime bypass (wide words, is_count=0). pretrig=0 so the reordered
# window opens on the flushed trigger data word (no mid-run leading count).
@pytest.mark.parametrize("seed,trig_sample,dwell,rle_on", [
    (0xC0FFEE01, 300, 4, True),    # runs of 4 -> count words
    (0x1234ABCD, 300, 7, True),    # longer runs
    (0xBADC0DE9, 260, 1, True),    # dwell 1: all data words (worst case), trigger flush on change
    (0x51261234, 300, 5, False),   # runtime bypass (RLE_EN build, rle_enable=0)
])
def test_cosim_rle_end_to_end(cosim_binary_rle, tmp_path, seed, trig_sample, dwell, rle_on):
    raw = _raw_func(seed, dwell, trig_sample + 4 * DEPTH + 8)

    stderr_log = tmp_path / "tb_cosim_rle.stderr"
    with cosim_util.CosimTransport(cosim_binary_rle, seed, trig_sample, stderr_log, dwell) as t:
        sc = Scope(t, probe_w=PROBE_W)

        assert sc.ping().cmd == frame.OP_PING
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, 0)
        sc.write_csr(C.RLE_CTRL, 1 if rle_on else 0)   # runtime compression enable
        assert not sc.status()["cfg_err"]

        sc.arm()
        assert sc.wait_done(timeout=15.0), "RLE capture never reached DONE"
        cap = sc.drain(pretrig_eff=0)

    # the DRAIN header must advertise the word format (rle_flag=RLE_EN=1) so the host decoded
    assert cap.rle
    # decode == raw: the decoded window is a contiguous run of the known stimulus, trigger first
    assert None not in cap.samples, "leading/undefined RLE sample leaked through decode"
    assert len(cap.samples) >= DEPTH, "word buffer should decode to at least DEPTH raw samples"
    assert cap.trig_pos == 0                      # pretrig=0 -> trigger is the first sample
    assert cap.samples[0] == raw(trig_sample)     # reconstructed trigger == probe at trigger
    for i, s in enumerate(cap.samples):
        assert s == raw(trig_sample + i), f"raw sample {i} mismatch (dwell={dwell})"
