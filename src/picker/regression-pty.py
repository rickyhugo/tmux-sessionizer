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
child = subprocess.Popen(sys.argv[3:], stderr=int(sys.argv[2]))
os.write(fd, f"{child.pid}\\n".encode())
while True:
    _, value = os.waitpid(child.pid, os.WUNTRACED | os.WCONTINUED)
    if os.WIFSTOPPED(value):
        os.write(fd, b"STOP\\n")
    elif os.WIFCONTINUED(value):
        os.write(fd, b"CONT\\n")
    else:
        os.write(fd, f"{os.waitstatus_to_exitcode(value)}\\n".encode())
        break
os.read(0, 1)
"""


def attributes(fd):
    value = termios.tcgetattr(fd)
    value[3] &= ~getattr(termios, "PENDIN", 0)
    return value


class Picker:
    def __init__(self, binary, saturated_entry=False, long_query=False):
        self.master, self.slave = pty.openpty()
        self.original = attributes(self.slave)
        self.resize(80)
        if saturated_entry:
            self.fill_output()
        self.status, status_writer = os.pipe()
        self.errors = tempfile.TemporaryFile()

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(
            [
                sys.executable,
                "-c",
                SUPERVISOR,
                str(status_writer),
                str(self.errors.fileno()),
                binary,
                *(["long-query"] if long_query else []),
            ],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            preexec_fn=controlling_terminal,
            pass_fds=(status_writer, self.errors.fileno()),
            env={**os.environ, "TERM": "xterm-256color", "LC_ALL": "C"},
        )
        os.close(status_writer)
        self.pid = None
        try:
            self.pid = int(self.status_line())
            if long_query:
                output = b""
                while b"RENDERING\n" not in output:
                    assert select.select([self.master], [], [], 2)[0], (
                        "render did not start"
                    )
                    output += os.read(self.master, 65536)
            elif not saturated_entry:
                self.frame()
            self.wait_raw()
        except BaseException:
            self.close()
            raise

    def resize(self, width):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, width, 0, 0))

    def fill_output(self):
        flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        fcntl.fcntl(self.slave, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        try:
            for block in (b"x" * 4096, b"x"):
                while True:
                    try:
                        os.write(self.slave, block)
                    except BlockingIOError:
                        break
        finally:
            fcntl.fcntl(self.slave, fcntl.F_SETFL, flags)

    def wait_raw(self):
        deadline = time.monotonic() + 2
        while attributes(self.slave) == self.original:
            assert time.monotonic() < deadline, "picker did not enter raw mode"
            select.select([], [], [], 0.001)

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
            if not select.select(
                [self.master], [], [], max(0, deadline - time.monotonic())
            )[0]:
                self.errors.seek(0)
                raise AssertionError(
                    f"frame deadline: {self.errors.read().decode(errors='replace')}"
                )
            output += os.read(self.master, 65536)
            assert len(output) < 1_000_000, "unbounded frame output"
        return output

    def send(self, value):
        os.write(self.master, value)

    def finish(self, expected=0, drain=True):
        try:
            line = self.status_line()
            while line == "CONT":
                line = self.status_line()
            status = int(line)
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
        self.errors.close()


def cancellation(p, value):
    p.send(value)
    p.finish()


def invalid_utf8(p):
    p.send(b"\xf0")
    assert not select.select([p.master], [], [], 0.1)[0], "incomplete UTF-8 redrew"
    cancellation(p, b"\x03")


def ignored_key_events(p):
    p.send(b"\x1b[120;5:2u\x1b[120;5:3u\x1b[9;2:3u\x1b[57414;1:2uz")
    assert b"> z" in ANSI.sub(b"", p.frame()), "non-press events changed the query"
    cancellation(p, b"\x03")


def fragmented_console_key(p):
    p.send(b"\x1b[[")
    assert not select.select([p.master], [], [], 0.1)[0], "console prefix redrew"
    cancellation(p, b"A")


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


def suspend_entry(p):
    for _ in range(3):
        os.kill(p.pid, signal.SIGTSTP)
        status = p.status_line()
        while status == "CONT":
            status = p.status_line()
        assert status == "STOP", f"entry interruption did not suspend, status={status}"
        assert attributes(p.slave) == p.original, "suspend did not restore termios"
        os.kill(p.pid, signal.SIGCONT)
        p.wait_raw()
    p.frame()
    p.send(b"z")
    assert b"> z" in ANSI.sub(b"", p.frame()), "resumed picker did not stay open"
    cancellation(p, b"\x03")


def long_query_signal(p):
    select.select([], [], [], 0.2)
    os.kill(p.pid, signal.SIGTERM)
    p.finish(-signal.SIGTERM)


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
    parser.add_argument("--case", help="Run one named scenario")
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
                    "config",
                    "--dep",
                    "matcher",
                    "--dep",
                    "tmux",
                    "-Mroot=src/picker-regression.zig",
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
            ("csi-u-press-binding", lambda p: cancellation(p, b"\x1b[120;5:1u")),
            ("csi-u-shift-tab-binding", lambda p: cancellation(p, b"\x1b[9;2u")),
            ("csi-u-keypad-enter-binding", lambda p: cancellation(p, b"\x1b[57414u")),
            ("linux-console-f1-binding", lambda p: cancellation(p, b"\x1b[[A")),
            ("fragmented-linux-console-f1", fragmented_console_key),
            ("legacy-f1-binding", lambda p: cancellation(p, b"\x1bOP")),
            ("ignored-key-events", ignored_key_events),
            ("saturated-output-signal", saturated),
            ("partial-output", partial_output),
            ("arabic-layout", lambda p: layout(p, "لاx")),
            ("lisu-layout", lambda p: layout(p, "\ua4f8\ua4fcx")),
            ("hebrew-layout", lambda p: layout(p, "\u05d0\u200d\u05dcx")),
            ("saturated-entry-suspend", suspend_entry),
            ("long-query-signal", long_query_signal),
        ]
        if args.case is not None and args.case not in dict(tests):
            parser.error(f"unknown scenario: {args.case}")
        failures = []
        for name, test in tests:
            if args.case is not None and args.case != name:
                continue
            p = Picker(
                binary,
                saturated_entry=name == "saturated-entry-suspend",
                long_query=name == "long-query-signal",
            )
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
