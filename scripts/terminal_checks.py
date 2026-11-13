#!/usr/bin/env python3
"""Drive a real controlling PTY and a private, attached tmux popup."""

import argparse
import codecs
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from typing import NamedTuple
import unicodedata
import uuid


class CellStyle(NamedTuple):
    bold: bool = False
    foreground: int | tuple[int, int, int] | None = None
    background: int | tuple[int, int, int] | None = None


class Screen:
    def __init__(self, rows=24, cols=100):
        self.rows, self.cols = rows, cols
        self.x = self.y = 0
        self.style = CellStyle()
        self.alternate = False
        self.cursor_visible = True
        self.invalid_positions = []
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.clear()

    def clear(self):
        self.cells = [[" " for _ in range(self.cols)] for _ in range(self.rows)]
        self.styles = [[CellStyle()] * self.cols for _ in range(self.rows)]

    def resize(self, rows, cols):
        old, styles = self.cells, self.styles
        self.rows, self.cols = rows, cols
        self.clear()
        for y in range(min(rows, len(old))):
            for x in range(min(cols, len(old[y]))):
                self.cells[y][x], self.styles[y][x] = old[y][x], styles[y][x]
        self.x, self.y = min(self.x, cols - 1), min(self.y, rows - 1)

    @property
    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.cells)

    def feed(self, raw):
        self.pending += self.decoder.decode(raw)
        replies = []
        while self.pending:
            s = self.pending
            if s.startswith("\x1b["):
                match = re.match(r"\x1b\[([0-?]*)([ -/]*)([@-~])", s)
                if not match:
                    break
                args, _, op = match.groups()
                self.pending = s[match.end() :]
                private = args.startswith("?")
                vals = [int(v) if v else 0 for v in args.lstrip("?=>").split(";")]
                n = vals[0] or 1
                if op in "Hf":
                    row = vals[0] or 1
                    col = (vals[1] or 1) if len(vals) > 1 else 1
                    if row > self.rows or col > self.cols:
                        self.invalid_positions.append([row, col])
                    self.y = min(self.rows - 1, (vals[0] or 1) - 1)
                    self.x = min(self.cols - 1, col - 1)
                elif op == "A":
                    self.y = max(0, self.y - n)
                elif op == "B":
                    self.y = min(self.rows - 1, self.y + n)
                elif op == "C":
                    self.x = min(self.cols - 1, self.x + n)
                elif op == "D":
                    self.x = max(0, self.x - n)
                elif op == "G":
                    self.x = min(self.cols - 1, n - 1)
                elif op == "d":
                    self.y = min(self.rows - 1, n - 1)
                elif op == "J":
                    if vals[0] in (2, 3):
                        self.clear()
                    elif vals[0] == 0:
                        for y in range(self.y, self.rows):
                            start = self.x if y == self.y else 0
                            self.cells[y][start:] = [" "] * (self.cols - start)
                            self.styles[y][start:] = [CellStyle()] * (self.cols - start)
                elif op == "K":
                    start = 0 if vals[0] in (1, 2) else self.x
                    end = self.x + 1 if vals[0] == 1 else self.cols
                    self.cells[self.y][start:end] = [" "] * (end - start)
                    self.styles[self.y][start:end] = [CellStyle()] * (end - start)
                elif op == "m":
                    i = 0
                    while i < len(vals):
                        if vals[i] in (38, 48) and i + 1 < len(vals):
                            color = None
                            if vals[i + 1] == 2 and i + 4 < len(vals):
                                color = tuple(vals[i + 2 : i + 5])
                            elif vals[i + 1] == 5 and i + 2 < len(vals):
                                color = vals[i + 2]
                            if color is not None:
                                field = "foreground" if vals[i] == 38 else "background"
                                self.style = self.style._replace(**{field: color})
                            i += 5 if vals[i + 1] == 2 else 3
                            continue
                        if vals[i] == 0:
                            self.style = CellStyle()
                        elif vals[i] == 22:
                            self.style = self.style._replace(bold=False)
                        elif vals[i] == 1:
                            self.style = self.style._replace(bold=True)
                        elif 30 <= vals[i] <= 37 or 90 <= vals[i] <= 97:
                            color = vals[i] - (30 if vals[i] < 90 else 82)
                            self.style = self.style._replace(foreground=color)
                        elif 40 <= vals[i] <= 47 or 100 <= vals[i] <= 107:
                            color = vals[i] - (40 if vals[i] < 100 else 92)
                            self.style = self.style._replace(background=color)
                        elif vals[i] == 39:
                            self.style = self.style._replace(foreground=None)
                        elif vals[i] == 49:
                            self.style = self.style._replace(background=None)
                        i += 1
                elif op == "X":
                    end = min(self.cols, self.x + n)
                    self.cells[self.y][self.x : end] = [" "] * (end - self.x)
                    self.styles[self.y][self.x : end] = [CellStyle()] * (end - self.x)
                elif op in "hl" and private:
                    if 1049 in vals or 47 in vals:
                        self.alternate = op == "h"
                        self.clear()
                    if 25 in vals:
                        self.cursor_visible = op == "h"
                elif op == "n" and vals[0] == 6:
                    replies.append(f"\x1b[{self.y + 1};{self.x + 1}R".encode())
                elif op == "c":
                    replies.append(
                        b"\x1b[>0;136;0c" if args.startswith(">") else b"\x1b[?1;2c"
                    )
                continue
            if s.startswith("\x1b]") or s.startswith("\x1bP"):
                match = re.search(r"\x07|\x1b\\", s[2:])
                if not match:
                    break
                self.pending = s[2 + match.end() :]
                continue
            if s[0] == "\x1b":
                if len(s) < 2:
                    break
                size = 3 if s[1] in "()#%" else 2
                if len(s) < size:
                    break
                self.pending = s[size:]
                continue
            c = s[0]
            self.pending = s[1:]
            if c == "\r":
                self.x = 0
            elif c == "\n":
                if self.y == self.rows - 1:
                    self.cells.pop(0)
                    self.styles.pop(0)
                    self.cells.append([" "] * self.cols)
                    self.styles.append([CellStyle()] * self.cols)
                else:
                    self.y += 1
            elif c == "\b":
                self.x = max(0, self.x - 1)
            elif c == "\t":
                self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
            elif ord(c) >= 32:
                width = (
                    0
                    if unicodedata.combining(c)
                    else (2 if unicodedata.east_asian_width(c) in ("W", "F") else 1)
                )
                if width == 0:
                    self.cells[self.y][max(0, self.x - 1)] += c
                else:
                    if self.x >= self.cols:
                        self.x = 0
                        self.y = min(self.rows - 1, self.y + 1)
                    self.cells[self.y][self.x] = c
                    self.styles[self.y][self.x] = self.style
                    if width == 2 and self.x + 1 < self.cols:
                        self.cells[self.y][self.x + 1] = ""
                        self.styles[self.y][self.x + 1] = self.style
                    self.x += width
        return replies


class Terminal:
    def __init__(self, command, env, cwd, rows=24, cols=100):
        self.master, self.slave = os.openpty()
        self.screen = Screen(rows, cols)
        self.raw = bytearray()
        self.events = []
        self.started = time.perf_counter()
        self.resize(rows, cols)
        self.before = self.attributes(termios.tcgetattr(self.slave))
        self.events.append(
            {"command": command, "terminal_before": self.before, "size": [rows, cols]}
        )
        self.status_read, status_write = os.pipe()

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        # Darwin revokes the controlling tty when its session leader exits.
        # Observe termios after the target exits, before the supervisor exits.
        supervisor = """
import json, os, subprocess, sys, termios, time
fd = int(sys.argv[1])
started = time.perf_counter()
child = subprocess.Popen(sys.argv[2:])
os.write(fd, (json.dumps({"pid": child.pid, "started": started}) + "\\n").encode())
code = child.wait()
attrs = termios.tcgetattr(0)
attrs[6] = [v[0] if isinstance(v, bytes) else v for v in attrs[6]]
os.write(fd, (json.dumps({"code": code, "attrs": attrs}) + "\\n").encode())
sys.exit(code if code >= 0 else 128 - code)
"""
        self.process = subprocess.Popen(
            [sys.executable, "-c", supervisor, str(status_write), *command],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=env,
            cwd=cwd,
            preexec_fn=controlling_terminal,
            pass_fds=(status_write,),
        )
        os.close(status_write)
        self.status_file = os.fdopen(self.status_read)
        initial = json.loads(self.status_file.readline())
        self.target_pid = initial["pid"]
        self.started = initial["started"]

    @staticmethod
    def attributes(attrs):
        attrs[6] = [v[0] if isinstance(v, bytes) else v for v in attrs[6]]
        return attrs

    def resize(self, rows, cols):
        fcntl.ioctl(
            self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0)
        )
        self.screen.resize(rows, cols)
        if hasattr(self, "process") and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGWINCH)

    def read(self, timeout=0):
        if not select.select([self.master], [], [], timeout)[0]:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                return False
            raise
        self.raw.extend(data)
        for reply in self.screen.feed(data):
            os.write(self.master, reply)
        return bool(data)

    def snapshot(self, label):
        deadline = time.monotonic() + 0.05
        for _ in range(4):
            if time.monotonic() >= deadline or not self.read():
                break
        event = {
            "at_ms": round((time.perf_counter() - self.started) * 1000, 3),
            "label": label,
            "screen": self.screen.text,
            "cursor": [self.screen.y, self.screen.x],
            "alternate": self.screen.alternate,
            "cursor_visible": self.screen.cursor_visible,
        }
        self.events.append(event)
        return event

    def send(self, data, label):
        self.snapshot("before " + label)
        self.events.append({"action": label, "bytes": data.hex()})
        os.write(self.master, data)

    def wait(self, predicate, label, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            self.snapshot("read " + label)
            if predicate(self.screen):
                return self.snapshot(label)
            if self.process.poll() is not None:
                self.snapshot("exited " + label)
                raise AssertionError(
                    f"process exited {self.process.returncode} before {label}"
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timeout waiting for {label}\n{self.screen.text}")
            self.read(min(remaining, 0.05))

    def exit(self, expected=0, timeout=5):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None:
            if time.monotonic() >= deadline:
                raise AssertionError("process did not exit")
            self.read(0.05)
        self.snapshot("after exit")
        if expected is not None:
            assert self.process.returncode == expected, self.process.returncode
        return self.process.returncode

    def restored(self):
        state = json.loads(self.status_file.readline())
        self.events.append({"terminal_after_target_exit": state})
        actual, expected = state["attrs"].copy(), self.before.copy()
        # PENDIN is a kernel retype-pending flag, not a persistent terminal mode.
        actual[3] &= ~getattr(termios, "PENDIN", 0)
        expected[3] &= ~getattr(termios, "PENDIN", 0)
        assert actual == expected, "termios not restored"
        assert not self.screen.alternate, "alternate screen remains enabled"
        assert self.screen.cursor_visible, "cursor remains hidden"

    def save(self, output, name):
        output.mkdir(parents=True, exist_ok=True)
        (output / f"{name}.vt").write_bytes(self.raw)
        (output / f"{name}.json").write_text(json.dumps(self.events, indent=2) + "\n")

    def close(self):
        if self.process.poll() is None:
            try:
                os.kill(self.target_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 2
            while self.process.poll() is None and time.monotonic() < deadline:
                self.read(0.05)
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.kill()
        self.status_file.close()
        os.close(self.master)
        os.close(self.slave)
        self.process.wait(timeout=10)


class Fixture:
    def __init__(self, count=0):
        preferred_temp = Path(tempfile.gettempdir()) / "opencode"
        self.temp = tempfile.TemporaryDirectory(
            prefix="tms-terminal-",
            dir=preferred_temp if preferred_temp.is_dir() else None,
        )
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repos = self.root / "repos"
        self.repos.mkdir()
        self.config = self.root / "config.toml"
        self.socket = "tms-check-" + uuid.uuid4().hex
        tools = self.root / "bin"
        tools.mkdir()
        self.real_tmux = shutil.which("tmux")
        if self.real_tmux is None:
            raise RuntimeError("required tool not found: tmux")
        launcher = tools / "tmux"
        launcher_source = Path(__file__).parents[1] / "tests" / "terminal"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            f"sys.path.insert(0, {str(launcher_source)!r})\n"
            "from tmux_launcher import main\n"
            f"raise SystemExit(main({self.real_tmux!r}, {self.socket!r}))\n"
        )
        launcher.chmod(0o755)
        for name in ("git", "ls", "sh"):
            executable = shutil.which(name)
            if executable is None:
                raise RuntimeError(f"required tool not found: {name}")
            (tools / name).symlink_to(executable)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key
            not in (
                "TMUX",
                "TMUX_PANE",
                "COMPLETE",
                "TERM_PROGRAM",
                "ZDOTDIR",
                "BASH_ENV",
                "ENV",
                "GIT_DIR",
                "GIT_WORK_TREE",
            )
            and not key.startswith("TMS_")
        }
        self.env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            TMS_CONFIG_FILE=str(self.config),
            TMS_TMUX_SOCKET=self.socket,
            TERM="xterm-256color",
            LC_ALL="en_US.UTF-8",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            SHELL="/bin/sh",
            PATH=str(tools),
        )
        self.names = (
            [f"project-{i:04d}" for i in range(count)]
            if count
            else [
                "alpha",
                "beta",
                "café",
                "wide-界",
                "active.repo",
            ]
        )
        for name in self.names:
            path = self.repos / name
            path.mkdir()
            subprocess.run(
                ["git", "init", "-q", str(path)],
                env=self.env,
                check=True,
                capture_output=True,
            )
        self.configure()

    def configure(self, position="Bottom", extra=""):
        self.config.write_text(
            f'input_position = "{position}"\n'
            f"search_dirs = [{{path = {json.dumps(str(self.repos))}, depth = 1}}]\n"
            + extra
        )

    def tmux(self, *args, check=True):
        return subprocess.run(
            [self.real_tmux, "-L", self.socket, "-f", os.devnull, *args],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            check=check,
            timeout=8,
        )

    def terminal(self, binary, args=(), **kwargs):
        return Terminal([str(binary), *args], self.env, self.home, **kwargs)

    def close(self):
        self.tmux("kill-server", check=False)
        self.temp.cleanup()


def artifact(binary):
    binary = Path(binary).resolve()
    fixture = Fixture()
    try:
        return {
            "path": str(binary),
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "version": subprocess.run(
                [str(binary), "--version"],
                env=fixture.env,
                cwd=fixture.home,
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            ).stdout.strip(),
        }
    finally:
        fixture.close()


def ready(screen, total=5):
    return (
        re.search(rf"(?<!\d){total}/{total}(?!\d)", screen.text) is not None
        and "> " in screen.text
    )


class BaselineDefect(AssertionError):
    pass


def run_pty_checks(binary, output, strict):
    results = []
    fixture = Fixture()

    def case(name, check, args=(), **size):
        terminal = None
        try:
            terminal = fixture.terminal(binary, args, **size)
            check(terminal)
            results.append({"name": name, "status": "PASS"})
        except (AssertionError, OSError) as error:
            results.append(
                {
                    "name": name,
                    "status": "BASELINE_DEFECT"
                    if isinstance(error, BaselineDefect) and not strict
                    else "FAIL",
                    "detail": str(error),
                }
            )
        finally:
            if terminal:
                terminal.save(output, name)
                terminal.close()

    for position in ("Top", "Bottom"):
        fixture.configure(position)

        def cancel(t, position=position):
            t.wait(ready, "picker ready")
            row = 0 if position == "Top" else t.screen.rows - 1
            assert "".join(t.screen.cells[row]).startswith("> "), (
                "wrong prompt position"
            )
            assert t.attributes(termios.tcgetattr(t.slave)) != t.before, (
                "picker never entered raw mode"
            )
            t.send(b"\x1b", "Escape")
            t.exit()
            t.restored()

        case("cancel-" + position.lower(), cancel)

    fixture.configure()

    def confirm(t):
        t.wait(ready, "picker ready")
        t.send("café".encode(), "filter Unicode repository")
        t.wait(lambda s: "1/5" in s.text and "> café" in s.text, "unique Unicode match")
        t.send(b"\r", "confirm outside tmux")
        t.wait(
            lambda s: (
                fixture.tmux(
                    "list-clients", "-F", "#{session_name}", check=False
                ).stdout.strip()
                == "café"
            ),
            "attached chosen Unicode session",
        )
        path = fixture.tmux(
            "display-message", "-p", "-t", "café:", "#{pane_current_path}"
        ).stdout.strip()
        assert Path(path).resolve() == (fixture.repos / "café").resolve(), path
        t.events.append(
            {
                "chosen_session": fixture.tmux(
                    "list-clients", "-F", "#{session_name}"
                ).stdout.strip(),
                "path": path,
            }
        )
        fixture.tmux("detach-client")
        t.exit()
        t.restored()

    case("confirm-direct-pty", confirm)

    def ctrl_c(t):
        t.wait(ready, "picker ready")
        t.send(b"\x03", "Ctrl-C")
        t.exit()
        t.restored()

    case("cancel-ctrl-c", ctrl_c)

    def unicode_edit(t):
        t.wait(ready, "picker ready")
        t.send("caféX".encode(), "insert Unicode query")
        t.wait(lambda s: "> caféX" in s.text, "Unicode query")
        t.send(b"\x1b[D", "Left")
        t.wait(lambda s: s.x == 6, "scalar cursor after Left")
        t.send(b"\x7f", "Backspace")
        t.wait(lambda s: "> cafX" in s.text, "delete Unicode scalar")
        t.send("é".encode(), "insert Unicode scalar")
        t.wait(lambda s: "> caféX" in s.text, "insert in middle")
        t.send(b"\x1b[3~", "Delete")
        t.wait(lambda s: "> café" in s.text, "delete at cursor")
        t.send(b"\x03", "Ctrl-C")
        t.exit()
        t.restored()

    case("unicode-edit", unicode_edit)

    def wide_cursor(t):
        t.wait(ready, "picker ready")
        t.send("界".encode(), "insert wide scalar")
        t.wait(lambda s: "> 界" in s.text, "wide scalar visible")
        if t.screen.x != 4:
            raise BaselineDefect(f"wide scalar cursor column {t.screen.x}, expected 4")

    case("wide-cursor", wide_cursor)

    def resize(t):
        t.wait(ready, "picker ready")
        t.snapshot("before resize")
        t.resize(12, 42)
        t.wait(
            lambda s: ready(s) and "".join(s.cells[-1]).startswith("> "),
            "resized picker",
        )
        t.send(b"\x03", "Ctrl-C")
        t.exit()
        t.restored()

    case("resize", resize)

    def tiny(t):
        t.wait(ready, "picker ready")
        t.snapshot("before tiny resize")
        offset = len(t.raw)
        t.resize(1, 1)
        t.screen.invalid_positions.clear()
        t.send(b"\x1b[D", "redraw tiny picker")
        t.wait(lambda s: len(t.raw) > offset, "tiny picker redraw")
        if t.screen.invalid_positions:
            raise BaselineDefect(
                f"cursor outside tiny terminal {t.screen.invalid_positions}"
            )
        t.send(b"\x03", "cancel tiny picker")
        try:
            code = t.exit(expected=None)
        except AssertionError as error:
            raise BaselineDefect(
                f"{error}; out-of-bounds cursor positions {t.screen.invalid_positions}"
            ) from error
        if code != 0 or t.screen.invalid_positions:
            raise BaselineDefect(
                f"tiny picker exit {code}; cursor positions {t.screen.invalid_positions}"
            )
        t.restored()

    case("tiny-terminal", tiny)

    def terminate(t, signum):
        t.wait(ready, "picker ready")
        t.snapshot("before " + signum.name)
        os.kill(t.target_pid, signum)
        t.exit(expected=None)
        try:
            t.restored()
        except AssertionError as error:
            raise BaselineDefect(str(error)) from error

    for signum in (signal.SIGTERM, signal.SIGHUP):
        case(
            signum.name.lower() + "-restoration",
            lambda t, signum=signum: terminate(t, signum),
        )

    fixture.configure(
        extra=(
            "[picker_colors]\n"
            'highlight_color = "#123456"\n'
            'highlight_text_color = "#abcdef"\n'
            'border_color = "#234567"\n'
            'info_color = "#345678"\n'
            'prompt_color = "#456789"\n'
        )
    )

    def configured_colors(t):
        t.wait(ready, "configured picker ready")
        rows = ["".join(cells) for cells in t.screen.cells]
        selected = next(
            (i for i, row in enumerate(rows[:-1]) if row.startswith("> ")), None
        )
        counter = next(
            (i for i, row in enumerate(rows) if row.startswith("5/5─")), None
        )
        assert selected is not None, "selected row is missing"
        assert counter is not None, "counter and border are missing"
        observed = {
            "prompt": t.screen.styles[-1][0].foreground,
            "selected_text": t.screen.styles[selected][2].foreground,
            "selected_background": t.screen.styles[selected][2].background,
            "info": t.screen.styles[counter][0].foreground,
            "border": t.screen.styles[counter][3].foreground,
        }
        t.events.append({"configured_colors": observed})
        assert rows[-1].startswith("> "), "rendered prompt is missing"
        assert observed == {
            "prompt": (0x45, 0x67, 0x89),
            "selected_text": (0xAB, 0xCD, 0xEF),
            "selected_background": (0x12, 0x34, 0x56),
            "info": (0x34, 0x56, 0x78),
            "border": (0x23, 0x45, 0x67),
        }, observed
        t.send(b"\x03", "cancel configured picker")
        t.exit()
        t.restored()

    case("configured-colors", configured_colors)

    directories = [fixture.home / name for name in ("path with café", "path with 界")]
    filenames = ["FIRST café file.txt", "SECOND 界 file.txt"]
    for directory, filename in zip(directories, filenames):
        directory.mkdir()
        (directory / filename).touch()
    fixture.config.write_text(
        'input_position = "Bottom"\nsearch_dirs = [\n'
        + "".join(
            f"{{path = {json.dumps(str(directory))}, depth = 1}},\n"
            for directory in directories
        )
        + "]\n"
    )

    def directory_preview(t):
        for index, filename in enumerate(filenames):
            if index:
                t.send(b"\x1b[A", "select second directory")
            t.wait(
                lambda s: (
                    ready(s, 2)
                    and any(
                        "".join(row[: s.cols // 2]).rstrip()
                        == "> " + str(directories[index])
                        for row in s.cells
                    )
                    and filename
                    in "\n".join("".join(row[s.cols // 2 :]) for row in s.cells)
                    and filenames[1 - index] not in s.text
                ),
                f"directory {index + 1} preview with spaces and Unicode",
            )
        t.send(b"\x1b", "cancel directory picker")
        t.exit()
        t.restored()
        assert all(
            not (directory / "must-not-create").exists() for directory in directories
        ), "cancel created a repository"

    case(
        "directory-preview",
        directory_preview,
        args=("init-repo", "must-not-create"),
        cols=320,
    )

    fixture.configure(extra='[shortcuts]\n"ctrl-q" = "cancel"\n')

    def custom_cancel(t):
        t.wait(ready, "picker ready")
        t.send(b"\x11", "custom Ctrl-Q cancel")
        t.exit()
        t.restored()

    case("custom-cancel", custom_cancel)
    fixture.config.write_text("input_position = [\n")

    def error(t):
        code = t.exit(expected=None)
        assert code != 0, "invalid configuration succeeded"
        assert "config" in t.raw.decode(errors="replace").lower(), (
            "missing config error"
        )
        t.restored()

    case("error-restoration", error)
    fixture.close()
    return results


def run_popup_checks(binary, output):
    fixture = Fixture()
    results = []
    client = None
    try:
        fixture.tmux(
            "new-session",
            "-d",
            "-s",
            "origin",
            "-x",
            "100",
            "-y",
            "30",
            "printf 'ORIGIN_READY\\n'; exec /bin/sh",
        )
        fixture.tmux("set-option", "-g", "status", "off")
        fixture.tmux(
            "new-session",
            "-d",
            "-s",
            "preview",
            "-x",
            "100",
            "-y",
            "30",
            "printf 'SESSION_PREVIEW_TOKEN\\n'; exec /bin/sh",
        )
        fixture.tmux(
            "new-session",
            "-d",
            "-s",
            "active_repo",
            "-x",
            "100",
            "-y",
            "30",
            "printf 'ACTIVE_READY\\n'; exec /bin/sh",
        )
        fixture.tmux(
            "new-window",
            "-d",
            "-t",
            "origin",
            "-n",
            "target-window",
            "printf 'WINDOW_PREVIEW_TOKEN\\n'; exec /bin/sh",
        )
        client = Terminal(
            [
                fixture.real_tmux,
                "-L",
                fixture.socket,
                "-f",
                os.devnull,
                "attach-session",
                "-t",
                "origin",
            ],
            fixture.env,
            fixture.home,
            rows=30,
            cols=100,
        )
        client.wait(lambda s: "ORIGIN_READY" in s.text, "attached private tmux client")
        clients = fixture.tmux(
            "list-clients", "-F", "#{client_name}"
        ).stdout.splitlines()
        assert len(clients) == 1, clients
        target = clients[0]
        fixture.tmux("switch-client", "-c", target, "-t", "active_repo")
        client.wait(
            lambda s: "ACTIVE_READY" in s.text, "attach normalized active session"
        )
        fixture.tmux("switch-client", "-c", target, "-t", "origin")
        client.wait(lambda s: "ORIGIN_READY" in s.text, "return to origin")

        def selected_session():
            return fixture.tmux(
                "display-message", "-p", "-c", target, "#{session_name}"
            ).stdout.strip()

        def popup(name, args, action, position="Bottom", extra=""):
            fixture.configure(position, extra)
            client.snapshot("before popup " + name)
            offset = len(client.raw)
            command = " ".join(
                f"{key}={shlex.quote(fixture.env[key])}"
                for key in (
                    "HOME",
                    "XDG_CONFIG_HOME",
                    "TMS_CONFIG_FILE",
                    "TMS_TMUX_SOCKET",
                    "PATH",
                )
            )
            command += " TERM_PROGRAM=tmux " + shlex.join([str(binary), *args])
            job = subprocess.Popen(
                [
                    fixture.real_tmux,
                    "-L",
                    fixture.socket,
                    "-f",
                    os.devnull,
                    "display-popup",
                    "-c",
                    target,
                    "-E",
                    "-w",
                    "90%",
                    "-h",
                    "80%",
                    command,
                ],
                env=fixture.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                client.wait(
                    lambda s: re.search(r"\d+/\d+", s.text) is not None,
                    "popup picker " + name,
                )
                action(client)
                deadline = time.monotonic() + 5
                while job.poll() is None:
                    if time.monotonic() > deadline:
                        raise AssertionError("popup did not close")
                    client.read(0.05)
                stdout, stderr = job.communicate()
                assert job.returncode == 0, (stdout, stderr)
                client.wait(lambda s: "┌" not in s.text, "popup dismissed " + name)
                client.snapshot("after popup " + name)
                results.append({"name": name, "status": "PASS"})
            except (AssertionError, subprocess.SubprocessError) as error:
                results.append({"name": name, "status": "FAIL", "detail": str(error)})
                fixture.tmux("display-popup", "-c", target, "-C", check=False)
                if job.poll() is None:
                    job.terminate()
                    job.communicate(timeout=3)
            finally:
                (output / f"popup-{name}.vt").write_bytes(client.raw[offset:])
                client.save(output, "popup-client")

        def cancel(t):
            before = selected_session()
            t.send(b"\x1b", "cancel popup")
            t.wait(lambda s: "ORIGIN_READY" in s.text, "underlying pane after cancel")
            assert selected_session() == before == "origin", "cancel switched session"

        popup("cancel", [], cancel)

        def confirm(t):
            t.send(b"beta", "search beta")
            t.wait(
                lambda s: "> beta" in s.text and "1/5" in s.text, "unique beta match"
            )
            t.send(b"\r", "confirm beta")
            t.wait(lambda s: selected_session() == "beta", "client switched to beta")
            path = fixture.tmux(
                "display-message", "-p", "-t", "beta:", "#{pane_current_path}"
            ).stdout.strip()
            assert Path(path).resolve() == (fixture.repos / "beta").resolve(), path
            t.events.append({"chosen_session": selected_session(), "path": path})

        popup("confirm", [], confirm)
        fixture.tmux("switch-client", "-c", target, "-t", "origin")
        client.wait(lambda s: "ORIGIN_READY" in s.text, "return to origin")

        def custom(t):
            if "> active.repo" in t.screen.text:
                t.send(b"\x1b[A", "move selection off active session")
                t.wait(lambda s: "> beta" in s.text, "other active session selected")
            row = next(
                i
                for i, cells in enumerate(t.screen.cells)
                if "active.repo" in "".join(cells)
            )
            col = "".join(t.screen.cells[row]).index("active.repo")
            assert "> active.repo" not in "".join(t.screen.cells[row]), (
                "active-style assertion must not inspect the selection highlight"
            )
            assert all(
                style.bold
                for style in t.screen.styles[row][col : col + len("active.repo")]
            ), "active normalized session is not bold"
            row = next(
                i for i, cells in enumerate(t.screen.cells) if "alpha" in "".join(cells)
            )
            col = "".join(t.screen.cells[row]).index("alpha")
            assert not any(
                style.bold for style in t.screen.styles[row][col : col + len("alpha")]
            ), "inactive unselected session is bold"
            t.send(b"active.repo", "filter normalized active session")
            t.wait(
                lambda s: "1/5" in s.text and "> active.repo" in s.text,
                "unique active session match",
            )
            t.send(b"\x18", "custom Ctrl-X confirm")
            t.wait(
                lambda s: selected_session() == "active_repo",
                "custom confirmation target",
            )
            t.events.append({"chosen_session": selected_session()})

        popup(
            "custom-confirm-active-style",
            [],
            custom,
            extra=(
                'session_sort_order = "LastAttached"\n'
                '[shortcuts]\n"ctrl-x" = "confirm"\n'
            ),
        )
        fixture.tmux("switch-client", "-c", target, "-t", "origin")
        client.wait(lambda s: "ORIGIN_READY" in s.text, "return to origin")

        def session_preview(t):
            t.send(b"preview", "filter session preview")
            t.wait(
                lambda s: "SESSION_PREVIEW_TOKEN" in s.text and "> preview" in s.text,
                "real session pane preview",
            )
            t.send(b"\r", "confirm preview session")
            t.wait(
                lambda s: selected_session() == "preview", "selected preview session"
            )
            t.events.append({"chosen_session": selected_session()})

        popup("session-preview", ["switch"], session_preview, position="Top")
        fixture.tmux("switch-client", "-c", target, "-t", "origin")
        client.wait(lambda s: "ORIGIN_READY" in s.text, "return to origin")

        def window_preview(t):
            t.send(b"target-window", "filter window preview")
            t.wait(
                lambda s: (
                    "WINDOW_PREVIEW_TOKEN" in s.text and "target-window" in s.text
                ),
                "real window pane preview",
            )
            t.send(b"\r", "confirm target window")
            t.wait(
                lambda s: (
                    fixture.tmux(
                        "display-message", "-p", "-c", target, "#{window_name}"
                    ).stdout.strip()
                    == "target-window"
                ),
                "target window selected",
            )
            name = fixture.tmux(
                "display-message", "-p", "-c", target, "#{window_name}"
            ).stdout.strip()
            assert name == "target-window", name
            t.events.append(
                {"chosen_window": name, "chosen_session": selected_session()}
            )

        popup("window-preview", ["windows"], window_preview)

        fixture.tmux("select-window", "-t", "origin:0")
        client.wait(lambda s: "ORIGIN_READY" in s.text, "return to origin window")
        for suffix in ("A", "B"):
            fixture.tmux(
                "new-session",
                "-d",
                "-s",
                "vertical-" + suffix.lower(),
                f"printf 'VERTICAL_{suffix}_TOKEN\\n'; exec /bin/sh",
            )
        client.resize(40, 50)
        client.wait(
            lambda s: (
                fixture.tmux(
                    "display-message",
                    "-p",
                    "-c",
                    target,
                    "#{client_width}x#{client_height}",
                ).stdout.strip()
                == "50x40"
            ),
            "narrow attached client",
        )

        def vertical_preview(t):
            t.send(b"vertical-", "filter two preview sessions")
            for index, suffix in enumerate(("A", "B")):
                if index:
                    t.send(b"\x1b[A", "select second preview session")
                name = "vertical-" + suffix.lower()
                token = f"VERTICAL_{suffix}_TOKEN"
                t.wait(
                    lambda s: (
                        any(
                            line.strip(" │") == "> " + name
                            for line in s.text.splitlines()
                        )
                        and token in s.text
                        and f"VERTICAL_{'B' if suffix == 'A' else 'A'}_TOKEN"
                        not in s.text
                    ),
                    "selected session preview " + suffix,
                )
                rows = ["".join(row) for row in t.screen.cells]
                preview_row = next(i for i, row in enumerate(rows) if token in row)
                selected_row = next(
                    i for i, row in enumerate(rows) if row.strip(" │") == "> " + name
                )
                assert preview_row < selected_row, "preview is not above the list"
                assert any(
                    row.count("─") > 30 for row in rows[preview_row + 1 : selected_row]
                ), "missing horizontal divider below vertical preview"
            t.send(b"\r", "confirm second preview session")
            t.wait(
                lambda s: selected_session() == "vertical-b",
                "second preview session selected",
            )
            t.events.append({"chosen_session": selected_session()})

        popup("vertical-preview-selection", ["switch"], vertical_preview)
    except (AssertionError, subprocess.SubprocessError) as error:
        results.append({"name": "popup-setup", "status": "FAIL", "detail": str(error)})
    finally:
        try:
            if client:
                fixture.tmux("detach-client", check=False)
                try:
                    client.exit(expected=None)
                    client.restored()
                    results.append(
                        {"name": "popup-client-restoration", "status": "PASS"}
                    )
                except AssertionError as error:
                    results.append(
                        {
                            "name": "popup-client-restoration",
                            "status": "FAIL",
                            "detail": str(error),
                        }
                    )
                finally:
                    client.save(output, "popup-client")
                    client.close()
        finally:
            fixture.close()
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=os.environ.get("TMS_BIN"))
    parser.add_argument("--output", type=Path, default=Path("terminal-results"))
    parser.add_argument(
        "--require-improvements",
        action="store_true",
        help="Make known Rust cursor, tiny-size, SIGTERM, and SIGHUP defects fail",
    )
    parser.add_argument("--pty-only", action="store_true")
    args = parser.parse_args()
    if not args.binary:
        parser.error("--binary or TMS_BIN is required")
    binary = Path(args.binary).resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    results = run_pty_checks(binary, args.output, args.require_improvements)
    if not args.pty_only:
        results += run_popup_checks(binary, args.output)
    report = {"artifact": artifact(binary), "results": results}
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(any(result["status"] == "FAIL" for result in results))


if __name__ == "__main__":
    raise SystemExit(main())
