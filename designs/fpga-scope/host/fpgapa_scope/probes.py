"""probes.json loader: map probe bit lanes to named signals for VCD/sigrok export.

Format:  {"cs_n": [0, 0], "rwds": [1, 1], "state": [4, 2]}   # name: [msb, lsb] inclusive
Unmapped bits export as probe[k]. A single-bit signal uses [k, k].
"""
from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass
class Signal:
    name: str
    msb: int
    lsb: int

    @property
    def width(self) -> int:
        return self.msb - self.lsb + 1

    def extract(self, sample: int) -> int:
        return (sample >> self.lsb) & ((1 << self.width) - 1)


def load_probes(path_or_obj, probe_w: int):
    """Return a list of Signal covering all PROBE_W bits: the named groups from probes.json plus
    probe[k] for every unmapped bit, ordered lsb-ascending."""
    if path_or_obj is None:
        mapping = {}
    elif isinstance(path_or_obj, dict):
        mapping = path_or_obj
    else:
        with open(path_or_obj) as f:
            mapping = json.load(f)

    sigs = []
    covered = set()
    for name, (msb, lsb) in mapping.items():
        if lsb > msb:
            msb, lsb = lsb, msb
        sigs.append(Signal(name, msb, lsb))
        covered.update(range(lsb, msb + 1))
    for k in range(probe_w):
        if k not in covered:
            sigs.append(Signal(f"probe[{k}]", k, k))
    sigs.sort(key=lambda s: s.lsb)
    return sigs
