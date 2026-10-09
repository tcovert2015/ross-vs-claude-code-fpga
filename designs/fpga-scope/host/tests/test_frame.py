"""Frame codec — round-trip, CRC cross-check vs the SV-matched scope_ref, error paths, and
decode of DRAIN_DATA frames the SV side (scope_ref.cmd_drain_data) produces."""
import pytest
import scope_ref  # sim/model, on sys.path via conftest
from fpgapa_scope import frame


def test_crc_matches_scope_ref():
    for data in (b"", b"\x01\x00\x00", b"123456789", bytes(range(40))):
        assert frame.crc16_ccitt(data) == scope_ref.crc16_ccitt(list(data))


def test_build_parse_roundtrip():
    for cmd, pl in [(frame.OP_PING, b""), (frame.OP_WRITE_CSR, b"\x04" + (0x1234).to_bytes(4, "big")),
                    (frame.OP_DRAIN_DATA, bytes(range(20)))]:
        raw = frame.build_frame(cmd, pl)
        assert raw[0] == frame.SYNC0 and raw[1] == frame.SYNC1
        fr, off = frame.parse_frame(raw)
        assert fr.cmd == cmd and fr.payload == pl and off == len(raw)


def test_corrupted_crc_raises():
    raw = bytearray(frame.build_frame(frame.OP_PING, b"\xaa\xbb"))
    raw[-1] ^= 0xFF  # corrupt CRC
    with pytest.raises(frame.FrameError) as e:
        frame.parse_frame(bytes(raw))
    assert str(e.value) == "crc"


def test_resync_after_garbage():
    good = frame.build_frame(frame.OP_PING, b"\x01\x02")
    stream = b"\x00\xff\xa5garbage" + good
    frames = frame.parse_all(stream)
    assert len(frames) == 1 and frames[0].cmd == frame.OP_PING and frames[0].payload == b"\x01\x02"


def test_nak_frame():
    raw = frame.build_frame(frame.OP_NAK, bytes([frame.NAK_BAD_CRC]))
    fr, _ = frame.parse_frame(raw)
    assert fr.cmd == frame.OP_NAK and fr.name == "NAK" and fr.payload == b"\x01"


def test_decode_drain_data_from_scope_ref(tmp_path):
    # SV-side DRAIN_DATA frame bytes for a known 8-bit buffer, then decode with the host codec.
    probe_w = 8
    buf = [(i * 7 + 3) & 0xFF for i in range(256)]
    bufmem = tmp_path / "b_buf.mem"
    bufmem.write_text("\n".join(f"{v:02x}" for v in buf) + "\n")

    class A:  # argparse-like
        pass
    a = A(); a.probe_w = probe_w; a.buf_in = str(bufmem); a.out_prefix = str(tmp_path / "b")
    scope_ref.cmd_drain_data(a)
    frame_bytes = bytes(int(x, 16) for x in (tmp_path / "b_dframes.mem").read_text().split())

    frames = frame.parse_all(frame_bytes)
    assert all(f.cmd == frame.OP_DRAIN_DATA for f in frames)
    # reassemble samples (2-byte chunk index + 1 byte/sample) and compare to the buffer
    got = []
    for f in frames:
        got.extend(f.payload[2:])
    assert got == buf
