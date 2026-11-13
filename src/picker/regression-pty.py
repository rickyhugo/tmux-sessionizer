import argparse
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
SUPERVISOR = """
import os, subprocess, sys
fd = int(sys.argv[1])
child = subprocess.Popen(sys.argv[2:])
os.write(fd, f"{child.pid}\\n".encode())
os.write(fd, f"{child.wait()}\\n".encode())
os.read(0, 1)
"""


def attributes(fd):
    value = termios.tcgetattr(fd)
    value[3] &= ~getattr(termios, "PENDIN", 0)
    return value


class Picker:
    def __init__(self, binary):
        self.master, self.slave = pty.openpty()
        self.original = attributes(self.slave)
        self.resize(80)
        self.status, status_writer = os.pipe()

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(
            [sys.executable, "-c", SUPERVISOR, str(status_writer), binary],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            preexec_fn=controlling_terminal,
            pass_fds=(status_writer,),
            env={**os.environ, "TERM": "xterm-256color", "LC_ALL": "C"},
        )
        os.close(status_writer)
        self.pid = None
        try:
            self.pid = int(self.status_line())
            self.frame()
            assert attributes(self.slave) != self.original, (
                "picker did not enter raw mode"
            )
        except BaseException:
            self.close()
            raise

    def resize(self, width):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, width, 0, 0))

    def status_line(self, timeout=2):
        result = b""
        deadline = time.monotonic() + timeout
        while not result.endswith(b"\n"):
            assert select.select(
                [self.status], [], [], max(0, deadline - time.monotonic())
            )[0], "child exit deadline"
            byte = os.read(self.status, 1)
            assert byte, "supervisor closed its status pipe"
            result += byte
        return result.decode().strip()

    def frame(self):
        output = b""
        deadline = time.monotonic() + 3
        while not output.endswith(b"\x1b[?25h"):
            assert select.select(
                [self.master], [], [], max(0, deadline - time.monotonic())
            )[0], "frame deadline"
            output += os.read(self.master, 65536)
            assert len(output) < 1_000_000, "unbounded frame output"
        return output

    def send(self, value):
        os.write(self.master, value)

    def finish(self, expected=0, drain=True):
        try:
            status = int(self.status_line())
        except AssertionError as error:
            raise AssertionError(
                f"{error}, termios_restored={attributes(self.slave) == self.original}"
            ) from error
        assert status == expected, "unexpected child exit"
        assert attributes(self.slave) == self.original, (
            "termios not restored before draining"
        )
        if drain:
            output = b""
            while select.select([self.master], [], [], 0.05)[0]:
                output += os.read(self.master, 65536)
                assert len(output) < 1_000_000, "unbounded cleanup output"
            assert b"\x1b[?25h\x1b[?1049l" in output, "screen not restored"

    def close(self):
        for pid in (self.pid, self.proc.pid):
            if pid is None:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(self.master)
        os.close(self.slave)
        self.proc.wait(timeout=3)
        os.close(self.status)


def cancellation(p, value):
    p.send(value)
    p.finish()


def invalid_utf8(p):
    p.send(b"\xf0")
    assert not select.select([p.master], [], [], 0.1)[0], "incomplete UTF-8 redrew"
    cancellation(p, b"\x03")


def saturated(p):
    p.resize(65535)
    assert select.select([p.master], [], [], 2)[0], "wide frame did not start"
    select.select([], [], [], 0.2)
    os.kill(p.pid, signal.SIGTERM)
    p.finish(-signal.SIGTERM, drain=False)


def partial_output(p):
    p.resize(65535)
    assert select.select([p.master], [], [], 2)[0], "wide frame did not start"
    select.select([], [], [], 0.2)
    frame = p.frame()
    assert frame.count("─".encode()) == 65535, "partial writes lost border bytes"
    cancellation(p, b"\x03")


def layout(p, text):
    for width in (6, 4, 3):
        p.resize(width)
        p.frame()
        for key, expected, column in (
            (text.encode() if width == 6 else b"x", text, min(width, 5)),
            (b"\x1b[D", text, min(width, 4)),
            (b"\x1b[C", text, min(width, 5)),
            (b"\x7f", text[:-1], min(width, 4)),
        ):
            p.send(key)
            frame = p.frame()
            visible = (
                expected[:-1] if width == 3 and expected.endswith("x") else expected
            )
            assert ANSI.sub(b"", frame).split(b"> ")[-1] == visible.encode(), (
                "clipped query",
                text,
                frame,
            )
            assert re.findall(rb"\x1b\[(\d+);(\d+)H", frame)[-1] == (
                b"4",
                str(column).encode(),
            ), frame
    cancellation(p, b"\x03")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", help="Use an existing real-matcher driver")
    args = parser.parse_args()
    temporary_root = Path(tempfile.gettempdir()) / "opencode"
    with tempfile.TemporaryDirectory(
        prefix="picker-regression-",
        dir=temporary_root if temporary_root.is_dir() else None,
    ) as temp:
        binary = args.binary or str(Path(temp) / "picker-driver")
        if args.binary is None:
            subprocess.run(
                [
                    "mise",
                    "exec",
                    "--",
                    "zig",
                    "build-exe",
                    "-lc",
                    "-O",
                    "ReleaseFast",
                    "--dep",
                    "picker",
                    "--dep",
                    "config",
                    "-Mroot=src/picker/regression-driver.zig",
                    "-O",
                    "ReleaseFast",
                    "--dep",
                    "config",
                    "--dep",
                    "matcher",
                    "--dep",
                    "tmux",
                    "-Mpicker=src/picker.zig",
                    "-O",
                    "ReleaseFast",
                    "-Mconfig=src/config.zig",
                    "-O",
                    "ReleaseFast",
                    "-Mmatcher=src/matcher.zig",
                    "-O",
                    "ReleaseFast",
                    "--dep",
                    "process",
                    "-Mtmux=src/tmux.zig",
                    "-O",
                    "ReleaseFast",
                    "-Mprocess=src/process.zig",
                    f"-femit-bin={binary}",
                ],
                cwd=ROOT,
                check=True,
            )
        tests = [
            ("fragmented-invalid-utf8", invalid_utf8),
            ("buffered-double-escape", lambda p: cancellation(p, b"\x1b\x1b")),
            ("saturated-output-signal", saturated),
            ("partial-output", partial_output),
            ("arabic-layout", lambda p: layout(p, "لاx")),
            ("lisu-layout", lambda p: layout(p, "\ua4f8\ua4fcx")),
            ("hebrew-layout", lambda p: layout(p, "\u05d0\u200d\u05dcx")),
        ]
        failures = []
        for name, test in tests:
            p = Picker(binary)
            try:
                test(p)
                print(f"PASS {name}", flush=True)
            except AssertionError as error:
                failures.append(name)
                print(f"FAIL {name}: {error}", flush=True)
            finally:
                p.close()
        assert not failures, failures


if __name__ == "__main__":
    main()
