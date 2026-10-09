"""VCD writer — round-trip a small capture through a minimal VCD parser and check values."""
from fpgapa_scope.vcd import write_vcd
from fpgapa_scope.probes import load_probes


def _parse_vcd(path):
    """Minimal VCD reader: returns (id->name/width, list of (time, {name: value}))."""
    idmap, width = {}, {}
    ticks = []
    cur_t, cur = None, {}
    names = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("$var"):
                parts = line.split()
                w, code, name = int(parts[2]), parts[3], parts[4]
                idmap[code] = name
                width[name] = w
            elif line.startswith("#"):
                if cur_t is not None:
                    ticks.append((cur_t, dict(cur)))
                cur_t = int(line[1:])
            elif line and line[0] in "01":
                code = line[1:]
                if code in idmap:
                    cur[idmap[code]] = int(line[0])
            elif line.startswith("b"):
                val, code = line[1:].split()
                if code in idmap:
                    cur[idmap[code]] = int(val, 2)
    if cur_t is not None:
        ticks.append((cur_t, dict(cur)))
    return idmap, width, ticks


def test_vcd_named_and_bus(tmp_path):
    probe_w = 8
    probes = {"cs_n": [0, 0], "state": [3, 1], "flag": [7, 7]}
    # samples: bit0 cs_n, bits[3:1] state, bit7 flag
    samples = [0b0000_0000, 0b0000_0010, 0b1000_0110, 0b1000_0111]
    out = tmp_path / "cap.vcd"
    write_vcd(out, samples, probe_w, probes=load_probes(probes, probe_w), trig_pos=2)
    idmap, width, ticks = _parse_vcd(out)

    assert width["cs_n"] == 1 and width["state"] == 3 and width["flag"] == 1
    assert "trigger" in width.values() or "trigger" in idmap.values()

    # accumulate value-change state to reconstruct per-tick full values
    st = {}
    recon = []
    for _, ch in ticks:
        st.update(ch)
        recon.append(dict(st))
    # tick 2: cs_n=(0b110&1)=0, state=(0b110>>1)&7=3, flag=(0b110>>7)&1=1
    assert recon[2]["cs_n"] == 0
    assert recon[2]["state"] == 3
    assert recon[2]["flag"] == 1
    # tick 3: state = (0b111>>1)&7 = 3, cs_n = 1
    assert recon[3]["cs_n"] == 1 and recon[3]["state"] == 3
