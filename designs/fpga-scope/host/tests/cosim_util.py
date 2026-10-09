"""Build + drive the tb_cosim Verilator binary for the host co-simulation test (issue #10).

Isolates the two concerns the test doesn't want inline: (1) verilating scope_top + tb_cosim
into a standalone binary, and (2) a byte transport that talks to that binary over two dedicated
pipe fds (kept off stdio so Verilator's own chatter can't corrupt the frame stream).
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "rtl"
SIM = ROOT / "sim"

# scope_top + its dependencies, in package/prim/core order (mirrors sim/run.sh COMMON_SRCS,
# minus the CSR-bus front-ends which tb_cosim doesn't instantiate).
_SOURCES = [
    RTL / "scope_pkg.sv",
    RTL / "prim" / "prim_ff_sync.sv",
    RTL / "prim" / "prim_ram_1r1w.sv",
    RTL / "prim" / "prim_fifo_sync.sv",
    RTL / "prim" / "prim_fifo_async.sv",
    RTL / "scope_core.sv",
    RTL / "scope_csr.sv",
    RTL / "scope_trigger.sv",
    RTL / "scope_rle.sv",
    RTL / "scope_drain.sv",
    RTL / "xport" / "scope_uart.sv",
    RTL / "scope_top.sv",
    SIM / "cosim_io.cpp",
    SIM / "tb_cosim.sv",
]


def have_verilator() -> bool:
    return shutil.which("verilator") is not None


def build_cosim(mdir: Path, rle_en: bool = False) -> Path:
    """Verilate tb_cosim into an executable; return its path. Raises on build failure.
    rle_en=True elaborates the scope_rle store path (scope_top RLE_EN=1)."""
    mdir.mkdir(parents=True, exist_ok=True)
    binary = mdir / "tb_cosim"
    cmd = [
        "verilator", "--binary", "--timing", "-Wall", "--timescale", "1ns/1ps",
        f"-I{RTL}", f"-I{RTL / 'prim'}", f"-I{RTL / 'xport'}", f"-I{RTL / 'if'}",
        "--top-module", "tb_cosim", "--Mdir", str(mdir), "-o", "tb_cosim",
        f"-GRLE_EN=1'b{1 if rle_en else 0}",
        *[str(s) for s in _SOURCES],
    ]
    log = mdir / "build.log"
    with open(log, "w") as f:
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not binary.exists():
        raise RuntimeError(f"verilator build failed (rc={r.returncode}); see {log}\n"
                           + log.read_text()[-4000:])
    return binary


class CosimTransport:
    """Duck-typed byte transport (write/read) over pipes to a running tb_cosim process.

    host -> DUT via COSIM_RX_FD, DUT -> host via COSIM_TX_FD; both are pass_fds'd into the
    child at their inherited numbers and named through the environment (see sim/cosim_io.cpp).
    """
    def __init__(self, binary: Path, seed: int, trig_sample: int, stderr_path: Path | None = None,
                 dwell: int = 1, probe_mode: int = 0):
        self.h2d_r, self.h2d_w = os.pipe()   # parent writes h2d_w; DUT reads h2d_r
        self.d2h_r, self.d2h_w = os.pipe()   # DUT writes d2h_w; parent reads d2h_r
        env = dict(os.environ, COSIM_RX_FD=str(self.h2d_r), COSIM_TX_FD=str(self.d2h_w))
        self._stderr = open(stderr_path, "w") if stderr_path else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            [str(binary), f"+seed={seed & 0xFFFFFFFF:08x}", f"+trig_sample={trig_sample}",
             f"+dwell={dwell}", f"+probe_mode={probe_mode}"],
            env=env, pass_fds=(self.h2d_r, self.d2h_w),
            stdout=subprocess.DEVNULL, stderr=self._stderr)
        os.close(self.h2d_r)   # child owns these ends now
        os.close(self.d2h_w)
        os.set_blocking(self.d2h_r, False)

    def write(self, b: bytes):
        os.write(self.h2d_w, bytes(b))

    def read(self, n: int) -> bytes:
        try:
            return os.read(self.d2h_r, n)
        except BlockingIOError:
            return b""

    def close(self):
        for fd in (self.h2d_w,):          # closing our write end -> DUT sees EOF -> $finish
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        try:
            os.close(self.d2h_r)
        except OSError:
            pass
        if self._stderr not in (subprocess.DEVNULL, None):
            self._stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
