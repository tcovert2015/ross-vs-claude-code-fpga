"""JTAG byte transport (issue #15): move the framed protocol over the scope_jtag bridge.

`JtagTransport` is a duck-typed byte transport (`read`/`write`) like the serial and co-sim ones, so
the ordinary `Scope` + `frame` codec + `decode_drain` work **unchanged** over JTAG. It drives a
persistent `system-console` REPL (fpga/axc3000/sysconsole/scope_jtag_repl.tcl) that pumps bytes
through the bridge's TXDATA/RXDATA/STATUS registers on a JTAG-to-Avalon master.

    from fpgapa_scope.jtag import JtagTransport, docker_launch_cmd
    t = JtagTransport(launch_cmd=docker_launch_cmd(base=0x400))   # holds the board lock outside
    sc = Scope(t, probe_w=32); sc.ping(); ... ; cap = sc.drain()

`launch_cmd` is the (list) command that starts the REPL — board/environment specific — or inject a
`proc` (a Popen-like object with text `stdin`/`stdout`) for testing without hardware.
"""
from __future__ import annotations

import subprocess


def docker_launch_cmd(base=0x400, repo="/home/tcovert/projects",
                      image="alterafpga/quartus-pro:26.1-agilex3",
                      script="fpga-scope/fpga/axc3000/sysconsole/scope_jtag_repl.tcl"):
    """The privileged-docker system-console command that runs the REPL (mirrors #12's PGM pattern).
    Wrap the whole thing in `flock /tmp/axc3000-devkit.lock` at the caller. jtagconfig must have
    primed jtagd in the same container first (system-console alone finds no devices)."""
    return ["docker", "run", "--rm", "-i", "--privileged",
            "-v", "/dev/bus/usb:/dev/bus/usb", "-v", f"{repo}:/workspace",
            "-w", "/workspace/fpga-scope/fpga/axc3000", image,
            "bash", "-c",
            f"jtagconfig >/dev/null 2>&1; sleep 1; "
            f"system-console --script=/workspace/{script} {base:#x}"]


class JtagTransport:
    def __init__(self, launch_cmd=None, proc=None, read_batch=256):
        self.rxbuf = bytearray()
        self.read_batch = read_batch
        if proc is not None:
            self.proc = proc
        elif launch_cmd is not None:
            self.proc = subprocess.Popen(launch_cmd, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, text=True, bufsize=1)
        else:
            raise ValueError("JtagTransport needs launch_cmd (a system-console command) or proc")

    def _cmd(self, line: str) -> str:
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        return (self.proc.stdout.readline() or "").strip()

    def write(self, b: bytes):
        if not b:
            return
        reply = self._cmd("W " + " ".join(f"{x:02x}" for x in b))
        if reply != "OK":
            raise IOError(f"JTAG write reply {reply!r}")

    def read(self, n: int) -> bytes:
        if not self.rxbuf:
            reply = self._cmd(f"R {max(n, self.read_batch)}")   # "D <hex...>"
            if reply.startswith("D "):
                self.rxbuf += bytes.fromhex(reply[2:].strip())
            elif reply.startswith("D"):
                pass                                            # "D" with no bytes = nothing ready
        out = bytes(self.rxbuf[:n])
        del self.rxbuf[:n]
        return out

    def close(self):
        try:
            self._cmd("Q")
        except Exception:
            pass
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
