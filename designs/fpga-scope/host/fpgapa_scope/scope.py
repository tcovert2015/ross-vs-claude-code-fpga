"""Scope session + DRAIN decode.

The `Scope` class speaks the frame protocol over any byte transport (a `.read(n)`/`.write(b)`
duck-typed object: pyserial `Serial`, a co-sim pipe, or the `BytesTransport` loopback used in
tests). Transport logic never leaks into the codec (design doc §4).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

from . import frame, csr as C
from .reorder import reorder_window
from .rle import rle_decode_words


@dataclass
class Capture:
    samples: list          # time-ordered raw probe values (post reorder + RLE decode)
    probe_w: int
    trig_pos: int          # index of the trigger sample in `samples`
    trig_index: int        # raw buffer address latched by the core
    wrapped: bool
    windows_done: int
    ts_at_trig: int
    rle: bool
    raw_buffer: list = field(default_factory=list)   # pre-reorder, as drained


def _unpack_samples(payload: bytes, nb: int):
    """DRAIN_DATA payload (after the 2-byte chunk index) -> list of little-endian samples."""
    body = payload[2:]
    out = []
    for i in range(0, len(body) - nb + 1, nb):
        v = 0
        for j in range(nb):
            v |= body[i + j] << (8 * j)
        out.append(v)
    return out


def decode_drain(frames, probe_w: int, pretrig_eff: int = 0) -> Capture:
    """Turn a DRAIN header frame + its DRAIN_DATA frames into a reordered, RLE-decoded Capture.
    `probe_w` is the user probe width; when rle_flag is set the stored word width is probe_w+1."""
    hdr = next((f for f in frames if f.cmd == frame.OP_DRAIN), None)
    if hdr is None:
        raise ValueError("no DRAIN header frame")
    p = hdr.payload
    flags = p[0]
    rle = bool(flags & 0x1)
    wrapped = bool(flags & 0x2)
    windows_done = p[1]
    trig_index = (p[2] << 8) | p[3]
    ts_at_trig = int.from_bytes(p[4:10], "big")

    store_w = probe_w + 1 if rle else probe_w
    nb = (store_w + 7) // 8
    stored = []
    for f in frames:
        if f.cmd == frame.OP_DRAIN_DATA:
            stored.extend(_unpack_samples(f.payload, nb))

    if rle:
        # RLE words are stored in circular buffer order. Reorder to chronological WORD order
        # (the issue-#7 math in WORD units — PRETRIG is word-domain when RLE is on), then
        # rle_decode. scope_rle flushes on the trigger so the trigger word is a clean data word
        # at the reordered trigger position; the number of raw samples the words before it
        # decode to is the trigger's raw index (#9 integration).
        ordered_words, trig_word_pos = reorder_window(stored, trig_index, wrapped, pretrig_eff)
        ordered = rle_decode_words(ordered_words, probe_w)
        trig_pos = len(rle_decode_words(ordered_words[:trig_word_pos], probe_w))
    else:
        ordered, trig_pos = reorder_window(stored, trig_index, wrapped, pretrig_eff)

    return Capture(samples=ordered, probe_w=probe_w, trig_pos=trig_pos, trig_index=trig_index,
                   wrapped=wrapped, windows_done=windows_done, ts_at_trig=ts_at_trig, rle=rle,
                   raw_buffer=stored)


def save_capture(cap: Capture, path):
    """Persist a decoded Capture as JSON (samples are hex to stay compact for wide probes)."""
    import json
    with open(path, "w") as f:
        json.dump({"probe_w": cap.probe_w, "trig_pos": cap.trig_pos, "trig_index": cap.trig_index,
                   "wrapped": cap.wrapped, "windows_done": cap.windows_done,
                   "ts_at_trig": cap.ts_at_trig, "rle": cap.rle,
                   "samples": [f"{s:x}" for s in cap.samples]}, f)


def load_capture(path) -> Capture:
    """Inverse of save_capture."""
    import json
    with open(path) as f:
        d = json.load(f)
    return Capture(samples=[int(s, 16) for s in d["samples"]], probe_w=d["probe_w"],
                   trig_pos=d["trig_pos"], trig_index=d["trig_index"], wrapped=d["wrapped"],
                   windows_done=d["windows_done"], ts_at_trig=d["ts_at_trig"], rle=d["rle"])


class BytesTransport:
    """In-memory loopback transport for tests: `feed()` queues bytes the host will `read()`."""
    def __init__(self):
        self.rx = bytearray()
        self.tx = bytearray()

    def write(self, b: bytes):
        self.tx += bytes(b)

    def read(self, n: int) -> bytes:
        out = bytes(self.rx[:n])
        del self.rx[:n]
        return out

    def feed(self, b: bytes):
        self.rx += bytes(b)


class Scope:
    def __init__(self, transport, probe_w: int = 32):
        self.t = transport
        self.probe_w = probe_w

    # -- framed request/response ------------------------------------------------------------
    def _send(self, cmd: int, payload: bytes = b""):
        self.t.write(frame.build_frame(cmd, payload))

    def _recv(self, timeout: float = 1.0):
        buf = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            chunk = self.t.read(64)
            if chunk:
                buf += chunk
                try:
                    fr, _ = frame.parse_frame(bytes(buf), 0)
                    return fr
                except frame.FrameError:
                    continue
        raise TimeoutError("no frame within timeout")

    def ping(self):
        self._send(frame.OP_PING)
        return self._recv()

    def read_csr(self, word: int) -> int:
        self._send(frame.OP_READ_CSR, bytes([word & 0xFF]))
        fr = self._recv()
        return int.from_bytes(fr.payload[:4], "big")

    def write_csr(self, word: int, value: int):
        self._send(frame.OP_WRITE_CSR, bytes([word & 0xFF]) + int(value).to_bytes(4, "big"))
        return self._recv()

    def status(self) -> dict:
        return C.decode_status(self.read_csr(C.STATUS))

    def arm(self):
        self.write_csr(C.CTRL, C.CTRL_ARM)

    def force_trig(self):
        self.write_csr(C.CTRL, C.CTRL_FORCE_TRIG)

    def wait_done(self, timeout: float = 5.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.status()["state"] == C.STATE_DONE:
                return True
        return False

    def drain(self, pretrig_eff: int = 0, timeout: float = 5.0, quiet: float = 0.03) -> Capture:
        """Request a DRAIN and read frames until the stream goes idle for `quiet` seconds (the
        end of the burst) or `timeout` elapses — transport-agnostic (UART, co-sim pipe, …)."""
        self._send(frame.OP_DRAIN)
        buf = bytearray()
        deadline = time.monotonic() + timeout
        last_rx = time.monotonic()
        while time.monotonic() < deadline:
            chunk = self.t.read(4096)
            if chunk:
                buf += chunk
                last_rx = time.monotonic()
            elif buf and (time.monotonic() - last_rx) > quiet:
                break
        return decode_drain(frame.parse_all(bytes(buf)), self.probe_w, pretrig_eff)
