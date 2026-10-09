#!/usr/bin/env python3
"""Turn a scope_capture.tcl dump (CSR-over-JTAG drain of the AXC3000 fpga-scope) into a VCD +
sigrok .sr, using the fpgapa_scope host package's reconstruction (issue #12).

  reconstruct.py scope_dump.txt --vcd out.vcd --sr out.sr --probes probes.json

The dump is header lines (`key value`) + one STORE_W word per line in raw buffer order. This applies
exactly the host DRAIN reconstruction: word-domain reorder (issue-#7 math) then rle_decode.
"""
import argparse
import sys
from pathlib import Path

# make the fpgapa_scope host package importable (repo_root/host)
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))

from fpgapa_scope.reorder import reorder_window
from fpgapa_scope.rle import rle_decode_words
from fpgapa_scope.vcd import write_vcd
from fpgapa_scope.sigrok import write_sr
from fpgapa_scope.probes import load_probes


def read_dump(path):
    meta, words = {}, []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2 and not parts[0].lstrip("-").isdigit():
            meta[parts[0]] = int(parts[1], 0)
        else:
            words.append(int(parts[0], 0))
    return meta, words


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dump")
    ap.add_argument("--vcd")
    ap.add_argument("--sr")
    ap.add_argument("--probes", default=str(Path(__file__).with_name("probes.json")))
    ap.add_argument("--samplerate", type=int, default=175_000_000, help="probe clock (Hz), CK_MHZ")
    ap.add_argument("--around", type=int, default=0,
                    help="if >0, keep only this many raw samples on each side of the trigger "
                         "(a focused view; RLE-decoded idle runs otherwise make a very long timeline)")
    args = ap.parse_args(argv)

    meta, words = read_dump(args.dump)
    probe_w = meta.get("probe_w", 32)
    rle = bool(meta.get("rle", 0))
    wrapped = bool(meta.get("wrapped", 0))
    trig_index = meta.get("trig_index", 0)
    pretrig = meta.get("pretrig", 0)

    if rle:
        ordered_words, trig_word_pos = reorder_window(words, trig_index, wrapped, pretrig)
        samples = rle_decode_words(ordered_words, probe_w)
        trig_pos = len(rle_decode_words(ordered_words[:trig_word_pos], probe_w))
    else:
        samples, trig_pos = reorder_window(words, trig_index, wrapped, pretrig)

    print(f"reconstructed {len(samples)} raw samples (rle={rle}, wrapped={wrapped}, "
          f"trig_index={trig_index}, trig_pos={trig_pos})")

    if args.around > 0:
        lo = max(0, trig_pos - args.around)
        hi = min(len(samples), trig_pos + args.around)
        samples = samples[lo:hi]
        trig_pos -= lo
        print(f"focused to {len(samples)} samples around the trigger (trig_pos={trig_pos})")

    probes = load_probes(args.probes, probe_w)

    if args.vcd:
        # each VCD time tick = one probe clock (~5.71 ns @ 175 MHz); sigrok carries the true rate.
        write_vcd(args.vcd, samples, probe_w, probes=probes, trig_pos=trig_pos, timescale="1ns")
        print(f"wrote {args.vcd}")
    if args.sr:
        write_sr(args.sr, samples, probe_w, probes=probes, samplerate=args.samplerate)
        print(f"wrote {args.sr}")
    if not args.vcd and not args.sr:
        print("(no --vcd/--sr given; nothing written)")


if __name__ == "__main__":
    main()
