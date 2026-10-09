"""JtagTransport (#15) — the REPL byte-pump protocol, and a frame round-trip through it with a fake
REPL (no hardware). Proves the ordinary Scope + frame codec work unchanged over the JTAG seam."""
from fpgapa_scope import frame, csr as C
from fpgapa_scope.jtag import JtagTransport, docker_launch_cmd
from fpgapa_scope.scope import Scope


class _Stdin:
    def __init__(self, repl):
        self.repl, self.buf = repl, ""

    def write(self, s):
        self.buf += s

    def flush(self):
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            self.repl.handle(line.strip())

    def close(self):
        pass


class _Stdout:
    def __init__(self, repl):
        self.repl = repl

    def readline(self):
        return self.repl.replies.pop(0) if self.repl.replies else ""


class FakeRepl:
    """Stands in for scope_jtag_repl.tcl: W collects written bytes, R returns queued response bytes."""
    def __init__(self, response=b""):
        self.written = bytearray()
        self.resp = bytearray(response)
        self.replies = []
        self.stdin = _Stdin(self)
        self.stdout = _Stdout(self)

    def handle(self, line):
        if line.startswith("W "):
            for h in line[2:].split():
                self.written.append(int(h, 16))
            self.replies.append("OK\n")
        elif line.startswith("R "):
            n = int(line.split()[1])
            take = bytes(self.resp[:n])
            del self.resp[:n]
            self.replies.append("D " + take.hex() + "\n")
        elif line == "Q":
            self.replies.append("\n")

    def wait(self, timeout=None):
        pass

    def kill(self):
        pass


def test_write_encodes_hex_bytes():
    r = FakeRepl()
    t = JtagTransport(proc=r)
    t.write(bytes([0xA5, 0x5C, 0x01, 0xFF]))
    assert bytes(r.written) == bytes([0xA5, 0x5C, 0x01, 0xFF])


def test_read_batches_and_buffers():
    r = FakeRepl(response=bytes(range(10)))
    t = JtagTransport(proc=r, read_batch=256)
    first = t.read(4)                      # one batch pulls all 10, returns 4
    assert first == bytes([0, 1, 2, 3])
    assert t.read(6) == bytes([4, 5, 6, 7, 8, 9])   # rest served from the buffer, no new command
    assert t.read(4) == b""                # nothing left


def test_ping_roundtrip_over_jtag():
    # preload the fake REPL with a valid PING response frame; Scope.ping() must parse it
    resp = frame.build_frame(frame.OP_PING, C.ID_REG.to_bytes(4, "big") + (0xABCD1234).to_bytes(4, "big"))
    r = FakeRepl(response=resp)
    sc = Scope(JtagTransport(proc=r), probe_w=32)
    fr = sc.ping()
    assert fr.cmd == frame.OP_PING
    assert int.from_bytes(fr.payload[4:8], "big") == 0xABCD1234
    # and the request the host sent was a well-formed PING frame
    assert frame.parse_all(bytes(r.written))[0].cmd == frame.OP_PING


def test_docker_launch_cmd_shape():
    cmd = docker_launch_cmd(base=0x400)
    assert cmd[0] == "docker" and "--privileged" in cmd
    assert any("scope_jtag_repl.tcl 0x400" in part for part in cmd)
