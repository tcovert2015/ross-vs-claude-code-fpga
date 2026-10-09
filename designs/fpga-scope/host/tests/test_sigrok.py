"""sigrok `.sr` writer — validate the ZIP container structure, metadata, and raw payload
against the libsigrok session-file format (srzip.c), and round-trip the sample bytes back."""
import zipfile

from fpgapa_scope.sigrok import write_sr, _fmt_samplerate, _bit_names
from fpgapa_scope.probes import load_probes


def _read_sr(path):
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        version = z.read("version").decode()
        metadata = z.read("metadata").decode()
        logic = z.read("logic-1-1")
    meta = {}
    section = None
    for line in metadata.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif "=" in line:
            k, v = line.split("=", 1)
            meta[f"{section}/{k}"] = v
    return names, version, meta, logic


def test_sr_container_structure(tmp_path):
    probe_w = 8
    samples = [0x00, 0x01, 0x80, 0xA5, 0xFF]
    out = tmp_path / "cap.sr"
    write_sr(out, samples, probe_w, samplerate=1_000_000)

    names, version, meta, logic = _read_sr(out)
    assert {"version", "metadata", "logic-1-1"} <= names
    assert version.strip() == "2"
    assert meta["device 1/capturefile"] == "logic-1"
    assert meta["device 1/total probes"] == "8"
    assert meta["device 1/unitsize"] == "1"
    assert meta["device 1/samplerate"] == "1 MHz"
    # unitsize=1 byte/sample, little-endian: raw == the sample bytes verbatim
    assert list(logic) == samples


def test_sr_multibyte_unitsize_and_roundtrip(tmp_path):
    probe_w = 32
    samples = [0x00000000, 0xDEADBEEF, 0x12345678, 0xFFFFFFFF]
    out = tmp_path / "cap32.sr"
    write_sr(out, samples, probe_w, samplerate=48_000_000)

    names, version, meta, logic = _read_sr(out)
    assert meta["device 1/unitsize"] == "4"
    assert meta["device 1/total probes"] == "32"
    assert meta["device 1/samplerate"] == "48 MHz"
    unitsize = 4
    assert len(logic) == len(samples) * unitsize
    recon = [int.from_bytes(logic[i:i + unitsize], "little")
             for i in range(0, len(logic), unitsize)]
    assert recon == samples


def test_sr_channel_names_from_probes(tmp_path):
    probe_w = 8
    probes = {"cs_n": [0, 0], "state": [3, 1], "flag": [7, 7]}
    out = tmp_path / "named.sr"
    write_sr(out, [0, 1, 2], probe_w, probes=load_probes(probes, probe_w))
    _, _, meta, _ = _read_sr(out)
    # single-bit groups keep the name; multi-bit groups suffix the intra-group index
    assert meta["device 1/probe1"] == "cs_n"        # bit 0
    assert meta["device 1/probe2"] == "state0"      # bit 1 (lsb of state[3:1])
    assert meta["device 1/probe4"] == "state2"      # bit 3 (msb of state[3:1])
    assert meta["device 1/probe8"] == "flag"        # bit 7


def test_fmt_samplerate():
    assert _fmt_samplerate(1_000_000) == "1 MHz"
    assert _fmt_samplerate(500_000) == "500 kHz"
    assert _fmt_samplerate(1_500_000_000) == "1500 MHz"  # not a whole GHz
    assert _fmt_samplerate(2_000_000_000) == "2 GHz"
    assert _fmt_samplerate(12345) == "12345 Hz"


def test_bit_names_unmapped():
    # unmapped bits keep the same `probe[k]` name the VCD writer uses (consistent exports)
    names = _bit_names(None, 4)
    assert names == ["probe[0]", "probe[1]", "probe[2]", "probe[3]"]
