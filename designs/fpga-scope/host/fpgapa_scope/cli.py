"""`fpgapa-scope` command-line entry: ping / config / arm / download / export."""
from __future__ import annotations

import argparse
import sys

from . import csr as C
from .scope import Scope, save_capture, load_capture
from .vcd import write_vcd
from .sigrok import write_sr
from .probes import load_probes


def _open_transport(args):
    if getattr(args, "jtag", False):
        from .jtag import JtagTransport, docker_launch_cmd
        return JtagTransport(launch_cmd=docker_launch_cmd(base=args.jtag_base))
    try:
        import serial  # pyserial (optional extra)
    except ImportError:
        sys.exit("pyserial not installed: pip install 'fpgapa-scope[serial]'")
    return serial.Serial(args.port, args.baud, timeout=0.1)


def _cmd_ping(args):
    sc = Scope(_open_transport(args), probe_w=args.probe_w)
    fr = sc.ping()
    print(f"PING -> {fr.name}, payload={fr.payload.hex()}")


def _cmd_config(args):
    sc = Scope(_open_transport(args), probe_w=args.probe_w)
    if args.pretrig is not None:
        sc.write_csr(C.PRETRIG, args.pretrig)
    if args.windows is not None:
        sc.write_csr(C.WINDOWS, args.windows)
    st = sc.status()
    print(f"configured; state={st['state_name']} cfg_err={st['cfg_err']}")


def _cmd_arm(args):
    sc = Scope(_open_transport(args), probe_w=args.probe_w)
    sc.arm()
    if args.force:
        sc.force_trig()
    if args.wait:
        if not sc.wait_done(args.timeout):
            sys.exit("timeout waiting for DONE")
        cap = sc.drain(pretrig_eff=args.pretrig or 0)
        if args.save:
            save_capture(cap, args.save)
            print(f"saved capture -> {args.save}")
        _export(cap, args)


def _cmd_export(args):
    cap = load_capture(args.infile)
    _export(cap, args)


def _export(cap, args):
    probes = load_probes(args.probes, cap.probe_w)
    if getattr(args, "out", None):
        write_vcd(args.out, cap.samples, cap.probe_w, probes=probes,
                  timescale=args.timescale, trig_pos=cap.trig_pos)
        print(f"wrote {args.out}: {len(cap.samples)} samples, trigger at {cap.trig_pos}")
    if getattr(args, "sr", None):
        write_sr(args.sr, cap.samples, cap.probe_w, probes=probes,
                 samplerate=args.samplerate)
        print(f"wrote {args.sr}: {len(cap.samples)} samples ({cap.probe_w} channels)")


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    p = argparse.ArgumentParser(prog="fpgapa-scope", description=__doc__)
    p.add_argument("--port", help="serial port (e.g. /dev/ttyUSB0)")
    p.add_argument("--baud", type=int, default=3_000_000)
    p.add_argument("--probe-w", type=int, default=32)
    p.add_argument("--jtag", action="store_true",
                   help="drain over JTAG via the scope_jtag bridge (system-console), not UART")
    p.add_argument("--jtag-base", type=lambda s: int(s, 0), default=0x400,
                   help="byte base of the scope_jtag register window on the JTAG-Avalon master")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping").set_defaults(func=_cmd_ping)

    c = sub.add_parser("config")
    c.add_argument("--pretrig", type=int)
    c.add_argument("--windows", type=int)
    c.set_defaults(func=_cmd_config)

    a = sub.add_parser("arm")
    a.add_argument("--wait", action="store_true")
    a.add_argument("--force", action="store_true", help="force_trig after arming")
    a.add_argument("--timeout", type=float, default=5.0)
    a.add_argument("--pretrig", type=int)
    a.add_argument("--out", help="write VCD to this path")
    a.add_argument("--sr", help="write sigrok .sr to this path")
    a.add_argument("--save", help="persist the raw decoded capture (JSON) for later export")
    a.add_argument("--probes", help="probes.json bit-lane names")
    a.add_argument("--timescale", default="1ns")
    a.add_argument("--samplerate", type=int, default=1_000_000, help="probe clock rate (Hz) for .sr")
    a.set_defaults(func=_cmd_arm)

    e = sub.add_parser("export", help="re-export a saved capture (--save JSON) to VCD/sigrok")
    e.add_argument("infile")
    e.add_argument("--out", help="write VCD to this path")
    e.add_argument("--sr", help="write sigrok .sr to this path")
    e.add_argument("--probes", help="probes.json bit-lane names")
    e.add_argument("--timescale", default="1ns")
    e.add_argument("--samplerate", type=int, default=1_000_000)
    e.set_defaults(func=_cmd_export)

    args = p.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
