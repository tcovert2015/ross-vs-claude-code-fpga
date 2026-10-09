#!/usr/bin/env python3
"""Decode the raw drained bytes from scope_jtag_capture.tcl (JTAG byte bridge, #15) into a VCD.

The bytes are the *framed* protocol (the same the UART path emits), so this is just the ordinary
host codec — frame.parse_all + decode_drain — proving the JTAG transport is byte-identical:

    jtag_decode.py scope_jtag_bytes.txt --vcd out.vcd [--sr out.sr] [--probes probes.json]
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))

from fpgapa_scope import frame
from fpgapa_scope.scope import decode_drain
from fpgapa_scope.vcd import write_vcd
from fpgapa_scope.sigrok import write_sr
from fpgapa_scope.probes import load_probes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("bytesfile")
    ap.add_argument("--vcd")
    ap.add_argument("--sr")
    ap.add_argument("--probe-w", type=int, default=32)
    ap.add_argument("--probes", default=str(Path(__file__).with_name("probes.json")))
    ap.add_argument("--samplerate", type=int, default=175_000_000)
    args = ap.parse_args(argv)

    raw = bytes.fromhex(Path(args.bytesfile).read_text().strip())
    frames = frame.parse_all(raw)
    print(f"parsed {len(frames)} frames ({len(raw)} bytes): "
          f"{[f.name for f in frames][:6]}{'…' if len(frames) > 6 else ''}")
    cap = decode_drain(frames, args.probe_w, pretrig_eff=0)
    print(f"decoded {len(cap.samples)} samples (rle={cap.rle}, wrapped={cap.wrapped}, "
          f"trig_index={cap.trig_index}, trig_pos={cap.trig_pos})")

    probes = load_probes(args.probes, args.probe_w)
    if args.vcd:
        write_vcd(args.vcd, cap.samples, args.probe_w, probes=probes, trig_pos=cap.trig_pos)
        print(f"wrote {args.vcd}")
    if args.sr:
        write_sr(args.sr, cap.samples, args.probe_w, probes=probes, samplerate=args.samplerate)
        print(f"wrote {args.sr}")


if __name__ == "__main__":
    main()
