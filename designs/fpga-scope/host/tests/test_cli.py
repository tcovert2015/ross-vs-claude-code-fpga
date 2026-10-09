"""CLI export path: save a decoded capture, reload it, and re-export to VCD + sigrok."""
import zipfile

from fpgapa_scope.scope import Capture, save_capture, load_capture
from fpgapa_scope import cli


def _cap():
    return Capture(samples=[0x00, 0xDEADBEEF, 0x12345678, 0xFFFFFFFF], probe_w=32,
                   trig_pos=2, trig_index=2, wrapped=True, windows_done=1,
                   ts_at_trig=0x1234, rle=False)


def test_save_load_roundtrip(tmp_path):
    cap = _cap()
    p = tmp_path / "cap.json"
    save_capture(cap, p)
    back = load_capture(p)
    assert back.samples == cap.samples
    assert (back.probe_w, back.trig_pos, back.wrapped, back.ts_at_trig) == \
           (cap.probe_w, cap.trig_pos, cap.wrapped, cap.ts_at_trig)


def test_export_subcommand(tmp_path):
    p = tmp_path / "cap.json"
    save_capture(_cap(), p)
    vcd = tmp_path / "out.vcd"
    sr = tmp_path / "out.sr"
    cli.main(["export", str(p), "--out", str(vcd), "--sr", str(sr)])

    assert vcd.exists() and vcd.read_text().startswith("$date")
    with zipfile.ZipFile(sr) as z:
        assert {"version", "metadata", "logic-1-1"} <= set(z.namelist())
        logic = z.read("logic-1-1")
    # 4 samples x 4 bytes/sample little-endian
    assert len(logic) == 4 * 4
    assert int.from_bytes(logic[4:8], "little") == 0xDEADBEEF
