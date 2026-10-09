"""Frame codec for the fpga-scope drain protocol (issue #8 / #10).

Wire format (one codec, every transport):  0xA5 0x5C | cmd(1) | len16(BE) | payload | crc16(BE)
CRC16-CCITT (poly 0x1021, init 0xFFFF, MSB-first) computed over cmd..payload, transmitted
big-endian. len16 is the payload byte count, big-endian. This module speaks *bytes only* — the
byte source (pyserial, a co-sim pipe, a CSR window) is the caller's concern (design doc §4).

Constants mirror rtl/scope_pkg.sv; the CRC is an independent implementation cross-checked against
sim/model/scope_ref.py (which the RTL is proven against in tb_uart / tb_drain_cdc), so a match
here is a match to the silicon.
"""
from __future__ import annotations

from dataclasses import dataclass

SYNC0 = 0xA5
SYNC1 = 0x5C

OP_PING = 0x01
OP_READ_CSR = 0x02
OP_WRITE_CSR = 0x03
OP_DRAIN = 0x04
OP_DRAIN_DATA = 0x05
OP_NAK = 0x15

NAK_BAD_CRC = 0x01
NAK_BAD_CMD = 0x02
NAK_BAD_LEN = 0x03

OP_NAMES = {
    OP_PING: "PING", OP_READ_CSR: "READ_CSR", OP_WRITE_CSR: "WRITE_CSR",
    OP_DRAIN: "DRAIN", OP_DRAIN_DATA: "DRAIN_DATA", OP_NAK: "NAK",
}


def crc16_ccitt(data: bytes, crc: int = 0xFFFF) -> int:
    """CRC16-CCITT poly 0x1021, init 0xFFFF, MSB-first — the wire CRC."""
    for b in data:
        crc ^= (b & 0xFF) << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc & 0xFFFF


def build_frame(cmd: int, payload: bytes = b"") -> bytes:
    """Encode one request/response frame."""
    if len(payload) > 0xFFFF:
        raise ValueError("payload exceeds len16")
    body = bytes([cmd & 0xFF, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF]) + payload
    crc = crc16_ccitt(body)
    return bytes([SYNC0, SYNC1]) + body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


@dataclass
class Frame:
    cmd: int
    payload: bytes

    @property
    def name(self) -> str:
        return OP_NAMES.get(self.cmd, f"0x{self.cmd:02X}")


class FrameError(ValueError):
    pass


def parse_frame(buf: bytes, offset: int = 0):
    """Parse one frame starting at/after `offset`, resynchronizing on the 0xA5 0x5C sync (the
    same hunt the RTL parser does). Returns (Frame, next_offset). Raises FrameError if no
    complete valid frame is found. Bad CRC raises FrameError('crc')."""
    n = len(buf)
    i = offset
    while i + 1 < n:
        if buf[i] == SYNC0 and buf[i + 1] == SYNC1:
            if i + 5 > n:
                raise FrameError("truncated header")
            cmd = buf[i + 2]
            plen = (buf[i + 3] << 8) | buf[i + 4]
            end = i + 5 + plen + 2
            if end > n:
                raise FrameError("truncated payload/crc")
            payload = buf[i + 5:i + 5 + plen]
            body = buf[i + 2:i + 5 + plen]
            crc_rx = (buf[i + 5 + plen] << 8) | buf[i + 6 + plen]
            if crc16_ccitt(body) != crc_rx:
                raise FrameError("crc")
            return Frame(cmd, bytes(payload)), end
        i += 1
    raise FrameError("no sync found")


def parse_all(buf: bytes):
    """Iterate every valid frame in a byte buffer (skips non-sync bytes)."""
    off = 0
    out = []
    while off + 1 < len(buf):
        try:
            fr, off = parse_frame(buf, off)
            out.append(fr)
        except FrameError as e:
            if str(e) == "crc":
                off += 2  # skip this bad frame's sync, keep hunting
                continue
            break
    return out
