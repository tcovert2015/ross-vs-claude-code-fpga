"""reorder (issue #7 worked examples + cross-check), RLE decode (vs scope_ref), and an
end-to-end DRAIN decode through the host codec."""
import scope_ref
from fpgapa_scope import reorder, rle, frame
from fpgapa_scope.scope import decode_drain


def test_reorder_worked_example1():
    # DESIGN.md example 1: DEPTH=8, PRETRIG=3, trig_index=1, wrapped -> s6..s13, trig at ordered[3]
    buf = ["s8", "s9", "s10", "s11", "s12", "s13", "s6", "s7"]
    ordered, trig_pos = reorder.reorder_window(buf, trig_index_rel=1, wrapped=True, pretrig_eff=3)
    assert ordered == ["s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13"]
    assert trig_pos == 3 and ordered[trig_pos] == "s9"


def test_reorder_pretrig0_not_wrapped():
    buf = list(range(8))
    ordered, trig_pos = reorder.reorder_window(buf, trig_index_rel=0, wrapped=False, pretrig_eff=0)
    assert ordered == list(range(8)) and trig_pos == 0


def test_rle_decode_matches_scope_ref():
    for cnt_w in (2, 3, 8):
        for probe_w in (4, 8):
            samples = scope_ref.gen_stimulus(0xABCD, 300, probe_w)
            # bias to runs so counts appear
            held = []
            x = 1
            for s in samples:
                x = scope_ref.xorshift32(x)
                held += [s] * (1 + (x % 5))
            words = scope_ref.rle_encode(held, cnt_w)
            packed = [((ic & 1) << probe_w) | (v & ((1 << probe_w) - 1)) for ic, v in words]
            assert rle.rle_decode_words(packed, probe_w) == held
            assert scope_ref.rle_decode(words) == held


def test_decode_drain_end_to_end():
    # Build a DRAIN header + DRAIN_DATA frames for a wrapped capture, decode via the host,
    # and confirm reorder places the trigger sample correctly.
    probe_w = 8
    # buffer laid out as DESIGN.md example (address order): s8 s9* s10 s11 s12 s13 s6 s7
    order_vals = [86, 96, 100, 101, 102, 103, 60, 70]  # arbitrary distinct byte values
    trig_index, wrapped, pretrig = 1, True, 3
    hdr_payload = bytes([0x00 | (0x2 if wrapped else 0), 1,
                         (trig_index >> 8) & 0xFF, trig_index & 0xFF]) + (0).to_bytes(6, "big")
    frames_bytes = frame.build_frame(frame.OP_DRAIN, hdr_payload)
    # one DRAIN_DATA chunk: chunk_index(2,BE) + 1 byte/sample
    dpl = bytes([0, 0]) + bytes(order_vals)
    frames_bytes += frame.build_frame(frame.OP_DRAIN_DATA, dpl)

    cap = decode_drain(frame.parse_all(frames_bytes), probe_w, pretrig_eff=pretrig)
    assert cap.wrapped and cap.trig_index == 1
    # oldest = (1+5)%8 = 6 -> s6,s7,s8,s9,... ; trigger sample (96) at ordered[3]
    assert cap.samples == [60, 70, 86, 96, 100, 101, 102, 103]
    assert cap.trig_pos == 3 and cap.samples[cap.trig_pos] == 96
