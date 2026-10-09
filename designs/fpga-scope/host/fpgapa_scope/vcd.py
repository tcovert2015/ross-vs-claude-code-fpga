"""VCD writer (IEEE 1364 §18) for a decoded, time-ordered capture.

Emits one `$var` per named signal (from probes.json) plus a 1-bit `trigger` marker, value-change
compressed (only changed signals per tick), with a `$comment` at the trigger instant. Timescale
comes from the caller's probe-clock period.
"""
from __future__ import annotations

from typing import Iterable
from .probes import Signal, load_probes


def _ident(n: int) -> str:
    """Compact VCD identifier code (printable ASCII 33..126)."""
    out = []
    n += 1
    while n > 0:
        n -= 1
        out.append(chr(33 + n % 94))
        n //= 94
    return "".join(out)


def write_vcd(path, samples: Iterable[int], probe_w: int, *, probes=None,
              timescale: str = "1ns", trig_pos: int | None = None, date: str = "fpga-scope"):
    """samples: time-ordered ints (each a PROBE_W-bit probe value)."""
    sigs = probes if probes and isinstance(probes[0], Signal) else load_probes(probes, probe_w)
    samples = list(samples)
    codes = {s.name: _ident(i) for i, s in enumerate(sigs)}
    trig_code = _ident(len(sigs))

    def fmt(sig: Signal, val: int) -> str:
        if sig.width == 1:
            return f"{val & 1}{codes[sig.name]}"
        return f"b{val:b} {codes[sig.name]}"

    with open(path, "w") as f:
        f.write(f"$date {date} $end\n$version fpgapa-scope $end\n")
        f.write(f"$timescale {timescale} $end\n$scope module scope $end\n")
        for s in sigs:
            f.write(f"$var wire {s.width} {codes[s.name]} {s.name} $end\n")
        f.write(f"$var wire 1 {trig_code} trigger $end\n")
        f.write("$upscope $end\n$enddefinitions $end\n")

        prev = {}
        for t, samp in enumerate(samples):
            changes = []
            for s in sigs:
                v = s.extract(samp)
                if prev.get(s.name) != v:
                    changes.append(fmt(s, v))
                    prev[s.name] = v
            trig_now = 1 if (trig_pos is not None and t == trig_pos) else 0
            if prev.get("__trig") != trig_now:
                changes.append(f"{trig_now}{trig_code}")
                prev["__trig"] = trig_now
            if t == 0 or changes:
                f.write(f"#{t}\n")
                if t == 0 and trig_pos is not None and trig_pos == 0:
                    f.write("$comment trigger $end\n")
                elif trig_pos is not None and t == trig_pos:
                    f.write("$comment trigger $end\n")
                for c in changes:
                    f.write(c + "\n")
