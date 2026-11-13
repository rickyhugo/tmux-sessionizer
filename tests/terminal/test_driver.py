import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "terminal_checks", Path(__file__).parents[2] / "scripts" / "terminal_checks.py"
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
sys.modules["terminal_checks"] = driver
spec = importlib.util.spec_from_file_location(
    "benchmark", Path(__file__).parents[2] / "scripts" / "benchmark.py"
)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class ScreenTests(unittest.TestCase):
    def test_split_utf8_and_cursor_cells(self):
        screen = driver.Screen(3, 10)
        raw = "é界e\u0301".encode()
        for byte in raw:
            screen.feed(bytes([byte]))
        self.assertEqual(screen.x, 4)
        self.assertTrue(screen.text.startswith("é界e\u0301"))

    def test_split_csi_and_erase(self):
        screen = driver.Screen(3, 10)
        screen.feed(b"old\x1b[2;")
        screen.feed(b"3Hnew\x1b[1;1H\x1b[2K")
        self.assertEqual(screen.text, "\n  new\n")
        screen.feed(b"\x1b[2;3H\x1b[3X")
        self.assertEqual(screen.text, "\n\n")

    def test_color_values_are_not_bold_attributes(self):
        screen = driver.Screen(3, 10)
        screen.feed(b"\x1b[1m\x1b[38;5;0mA\x1b[22m\x1b[38;2;1;0;22mB")
        self.assertEqual(
            screen.styles[0][:2],
            [driver.CellStyle(True, 0), driver.CellStyle(False, (1, 0, 22))],
        )

    def test_ansi_colors_and_resets(self):
        screen = driver.Screen(3, 10)
        screen.feed(
            b"\x1b[31;104mA\x1b[38;5;123;48;2;4;5;6mB"
            b"\x1b[39mC\x1b[49mD\x1b[1;92;43mE\x1b[22mF\x1b[0mG"
        )
        self.assertEqual(
            screen.styles[0][:7],
            [
                driver.CellStyle(False, 1, 12),
                driver.CellStyle(False, 123, (4, 5, 6)),
                driver.CellStyle(False, None, (4, 5, 6)),
                driver.CellStyle(),
                driver.CellStyle(True, 10, 3),
                driver.CellStyle(False, 10, 3),
                driver.CellStyle(),
            ],
        )
        screen.resize(4, 12)
        self.assertEqual(screen.styles[0][1].background, (4, 5, 6))
        screen.feed(b"\x1b[1;1H\x1b[2K")
        self.assertEqual(screen.styles[0], [driver.CellStyle()] * 12)

    def test_ready_requires_exact_counts(self):
        for counter in ("15/5", "5/50", "15/50"):
            with self.subTest(counter=counter):
                self.assertFalse(driver.ready(SimpleNamespace(text=counter + "\n> ")))
        self.assertTrue(driver.ready(SimpleNamespace(text="5/5───\n> ")))

    def test_restoration_modes_and_queries(self):
        screen = driver.Screen(3, 10)
        screen.feed(b"\x1b[?1049h\x1b[?25l")
        self.assertTrue(screen.alternate)
        self.assertFalse(screen.cursor_visible)
        self.assertEqual(screen.feed(b"\x1b[2;3H\x1b[6n"), [b"\x1b[2;3R"])
        self.assertEqual(screen.feed(b"\x1b[>c"), [b"\x1b[>0;136;0c"])
        screen.feed(b"\x1b[?1049l\x1b[?25h")
        self.assertFalse(screen.alternate)
        self.assertTrue(screen.cursor_visible)

    def test_out_of_bounds_cursor_is_observable(self):
        screen = driver.Screen(1, 1)
        screen.feed(b"\x1b[1;3H")
        self.assertEqual(screen.invalid_positions, [[1, 3]])
        self.assertEqual(screen.x, 0)


class TerminalTests(unittest.TestCase):
    def test_continuous_output_cannot_block_deadlines_or_cleanup(self):
        def watchdog(signum, frame):
            raise TimeoutError("continuous output blocked the driver")

        with tempfile.TemporaryDirectory() as directory:
            terminal = driver.Terminal(
                [
                    sys.executable,
                    "-c",
                    "import os\nwhile True: os.write(1, b'\\rX' * 32768)",
                ],
                os.environ.copy(),
                directory,
            )
            previous = signal.signal(signal.SIGALRM, watchdog)
            signal.setitimer(signal.ITIMER_REAL, 4)
            try:
                self.assertTrue(terminal.read(1), "writer produced no PTY output")
                started = time.monotonic()
                read = terminal.read

                def read_through_writer_scheduling_gaps(timeout=0):
                    return read(max(timeout, 0.02))

                with patch.object(
                    terminal,
                    "read",
                    side_effect=read_through_writer_scheduling_gaps,
                ):
                    with self.assertRaisesRegex(AssertionError, "timeout waiting"):
                        terminal.wait(
                            lambda s: False, "unreachable screen", timeout=0.15
                        )
                    with self.assertRaisesRegex(AssertionError, "process did not exit"):
                        terminal.exit(timeout=0.15)
                self.assertLess(time.monotonic() - started, 2)
                self.assertIsNone(terminal.process.poll())
            finally:
                try:
                    terminal.close()
                finally:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                    signal.signal(signal.SIGALRM, previous)
            self.assertIsNotNone(terminal.process.poll())
            with self.assertRaises(ProcessLookupError):
                os.kill(terminal.target_pid, 0)
            with self.assertRaises(OSError):
                os.fstat(terminal.master)

    def test_successful_exit_does_not_count_as_picker_work(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = driver.Terminal(
                [sys.executable, "-c", "pass"], os.environ.copy(), directory
            )
            try:
                with self.assertRaisesRegex(AssertionError, "before picker ready"):
                    terminal.wait(driver.ready, "picker ready")
                terminal.exit()
                terminal.restored()
            finally:
                terminal.close()

    def test_attached_tmux_client_can_be_killed_during_cleanup(self):
        fixture = driver.Fixture()
        try:
            fixture.tmux(
                "new-session",
                "-d",
                "-s",
                "cleanup",
                "-x",
                "100",
                "-y",
                "24",
                "printf 'CLEANUP_READY\\n'; exec /bin/sh",
            )
            terminal = driver.Terminal(
                [
                    fixture.real_tmux,
                    "-L",
                    fixture.socket,
                    "-f",
                    os.devnull,
                    "attach-session",
                    "-t",
                    "cleanup",
                ],
                fixture.env,
                fixture.home,
            )
            try:
                terminal.wait(lambda s: "CLEANUP_READY" in s.text, "attached client")
            finally:
                terminal.close()
        finally:
            fixture.close()


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.log = root / "argv.json"
        fake = root / "fake-tmux"
        fake.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(self.log)!r}, 'w') as log:\n"
            "    json.dump({'argv': sys.argv[1:], 'pid': os.getpid()}, log)\n"
            "print('REAL_TMUX_EXECUTED')\n"
            "sys.exit(23)\n"
        )
        fake.chmod(0o755)
        which = shutil.which
        with patch.object(
            driver.shutil,
            "which",
            side_effect=lambda name: str(fake) if name == "tmux" else which(name),
        ):
            self.fixture = driver.Fixture()
        self.addCleanup(self.fixture.close)

    def test_invalid_global_arguments_never_launch_tmux(self):
        socket = self.fixture.socket
        cases = [
            [],
            ["attach-session"],
            ["-L"],
            ["-L" + socket, "attach-session"],
            ["-L", "", "attach-session"],
            ["-L", "other-socket", "attach-session"],
            ["-L", socket, ""],
            ["-L", socket, "--", "attach-session"],
            ["-S", "/other/socket", "attach-session"],
            ["-f", "/other/config", "-L", socket, "attach-session"],
            ["-L", socket, "-L", "other-socket", "attach-session"],
            ["-L", socket, "-S/other/socket", "attach-session"],
            ["-L", socket, "-f", "/other/config", "attach-session"],
            ["-L", socket, "-v", "attach-session"],
        ]
        for args in cases:
            with self.subTest(args=args):
                result = subprocess.run(
                    ["tmux", *args],
                    env=self.fixture.env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists(), "invalid args launched tmux")

    def test_valid_client_commands_exec_real_tmux_with_private_options(self):
        for command in (
            [],
            ["attach-session", "-t", "chosen"],
            ["switch-client", "-t", "chosen"],
            ["list-sessions", "-F", "#{session_name}"],
        ):
            with self.subTest(command=command):
                process = subprocess.Popen(
                    ["tmux", "-L", self.fixture.socket, *command],
                    env=self.fixture.env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 23, stderr)
                self.assertEqual(stdout.strip(), "REAL_TMUX_EXECUTED")
                observed = json.loads(self.log.read_text())
                self.assertEqual(observed["pid"], process.pid)
                self.assertEqual(
                    observed["argv"],
                    ["-L", self.fixture.socket, "-f", os.devnull, *command],
                )

    def test_version_metadata_uses_the_isolated_environment(self):
        root = Path(self.temp.name)
        (root / "tmux").symlink_to(root / "fake-tmux")
        binary = root / "version-probe"
        binary.write_text(
            f"#!{sys.executable}\n"
            "import subprocess\n"
            "result = subprocess.run(['tmux', 'attach-session'], capture_output=True)\n"
            "print(f'tms tmux-exit {result.returncode}')\n"
        )
        binary.chmod(0o755)
        with (
            patch.dict(os.environ, {"PATH": str(root)}),
            patch.object(driver, "Fixture", return_value=self.fixture),
            patch.object(self.fixture, "close") as close,
        ):
            observed = driver.artifact(binary)
        self.assertEqual(observed["version"], "tms tmux-exit 2")
        self.assertFalse(self.log.exists(), "metadata launched unguarded tmux")
        close.assert_called_once_with()


class BenchmarkTests(unittest.TestCase):
    def sample(self, startup_count, search_count):
        count = 1000
        query = "project-0999"
        terminal = SimpleNamespace(
            started=time.perf_counter(),
            screen=SimpleNamespace(text=f"> project-0000\n{startup_count}───\n> "),
            save=lambda *args: None,
            close=lambda: None,
            exit=lambda: None,
            restored=lambda: None,
        )

        def wait(predicate, label, **kwargs):
            if not predicate(terminal.screen):
                raise AssertionError("rejected " + label)

        def send(data, label):
            terminal.screen.text = f"> {query}\n{search_count}───\n> {query}"

        terminal.wait, terminal.send = wait, send
        fixture = SimpleNamespace(env={}, terminal=lambda *args, **kwargs: terminal)
        with patch.object(
            benchmark.subprocess, "run", return_value=SimpleNamespace(stdout="tms test")
        ):
            return benchmark.sample(
                Path("fake-binary"), fixture, count, Path("."), "test"
            )

    def test_wrong_search_count_with_correct_selected_row_is_rejected(self):
        for count in ("11/1000", "1/10000"):
            with self.subTest(count=count):
                with self.assertRaisesRegex(AssertionError, "unique search result"):
                    self.sample("1000/1000", count)

    def test_wrong_startup_count_is_rejected(self):
        for count in ("11000/1000", "1000/10000"):
            with self.subTest(count=count):
                with self.assertRaisesRegex(AssertionError, "all candidates rendered"):
                    self.sample(count, "1/1000")

    def test_observed_counts_are_recorded(self):
        sample = self.sample("1000/1000", "1/1000")
        self.assertEqual(
            sample["observed_counts"],
            {
                "startup": {"matched": 1000, "candidates": 1000},
                "search": {"matched": 1, "candidates": 1000},
            },
        )
        self.assertEqual(sample["matched"], 1)
        self.assertEqual(sample["candidates"], 1000)


if __name__ == "__main__":
    unittest.main()
