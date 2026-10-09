"""fpgapa-scope — host tool for the fpga-scope vendor-neutral embedded logic analyzer."""
from .frame import build_frame, parse_frame, parse_all, crc16_ccitt, Frame, FrameError
from .scope import Scope, Capture, BytesTransport, decode_drain, save_capture, load_capture
from .reorder import reorder_window
from .rle import rle_decode_words
from .probes import load_probes, Signal
from .vcd import write_vcd
from .sigrok import write_sr
from .jtag import JtagTransport, docker_launch_cmd
from . import csr

__version__ = "1.0.0"
__all__ = [
    "build_frame", "parse_frame", "parse_all", "crc16_ccitt", "Frame", "FrameError",
    "Scope", "Capture", "BytesTransport", "decode_drain", "save_capture", "load_capture",
    "reorder_window", "rle_decode_words", "load_probes", "Signal", "write_vcd", "write_sr",
    "JtagTransport", "docker_launch_cmd", "csr",
]
