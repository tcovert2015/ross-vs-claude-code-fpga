"""sigrok `.sr` session writer for a decoded, time-ordered capture (issue #10).

A `.sr` file is a ZIP container (libsigrok "session file" format v2) holding:

  * ``version``    — a single line, the container format version (``2``).
  * ``metadata``   — an INI file describing the device: sample rate, channel names, the
                     per-sample unit size, and the capture-file base name.
  * ``logic-1-1``  — raw logic sample data: one little-endian ``unitsize``-byte word per
                     sample, bit *k* carrying logic channel *k+1* (chunk index ``-1``).

Reference: libsigrok ``src/output/srzip.c`` / ``src/input/binary.c`` (the reader). sigrok
logic channels are single-bit, so a PROBE_W-bit capture exports PROBE_W channels; a
probes.json group like ``"state": [4, 2]`` names the individual bits ``state0..state2``.
Structurally validated in host/tests/test_sigrok.py; opens in PulseView (see host/README.md).
"""
from __future__ import annotations

import zipfile
from typing import Iterable

from .probes import Signal, load_probes


def _fmt_samplerate(hz: int) -> str:
    """Human sample-rate string libsigrok's sr_parse_sizestring() accepts ("1 MHz")."""
    for unit, div in (("GHz", 1_000_000_000), ("MHz", 1_000_000), ("kHz", 1_000)):
        if hz >= div and hz % div == 0:
            return f"{hz // div} {unit}"
    return f"{hz} Hz"


def _bit_names(probes, probe_w: int) -> list[str]:
    """One channel name per probe bit 0..PROBE_W-1, taken from the probes.json groups
    (multi-bit groups suffix the intra-group index, e.g. state[4:2] -> state0/state1/state2).
    load_probes() covers every bit — unmapped ones keep the VCD writer's `probe[k]` name."""
    sigs = probes if probes and isinstance(probes[0], Signal) else load_probes(probes, probe_w)
    names = [f"probe[{k}]" for k in range(probe_w)]
    for s in sigs:
        for k in range(s.lsb, s.msb + 1):
            names[k] = s.name if s.width == 1 else f"{s.name}{k - s.lsb}"
    return names


def write_sr(path, samples: Iterable[int], probe_w: int, *, probes=None,
             samplerate: int = 1_000_000, compress: bool = True):
    """Write a sigrok `.sr` session file.

    samples:    time-ordered ints, each a PROBE_W-bit probe value (host reorder output).
    probe_w:    probe width in bits -> that many single-bit sigrok logic channels.
    probes:     probes.json path / mapping dict / list[Signal] for channel naming (optional).
    samplerate: probe-clock rate in Hz, written to the metadata (default 1 MHz placeholder).
    """
    samples = list(samples)
    unitsize = (probe_w + 7) // 8
    names = _bit_names(probes, probe_w)
    vmask = (1 << probe_w) - 1

    raw = b"".join((s & vmask).to_bytes(unitsize, "little") for s in samples)

    meta = ["[global]", "sigrok version=0.6.0", "", "[device 1]",
            "capturefile=logic-1", f"total probes={probe_w}",
            f"samplerate={_fmt_samplerate(samplerate)}", "total analog=0"]
    meta += [f"probe{k + 1}={names[k]}" for k in range(probe_w)]
    meta += [f"unitsize={unitsize}", ""]
    metadata = "\n".join(meta)

    mode = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
    with zipfile.ZipFile(path, "w", mode) as z:
        z.writestr("version", "2\n")
        z.writestr("metadata", metadata)
        z.writestr("logic-1-1", raw)
