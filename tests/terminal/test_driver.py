import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "terminal_checks", Path(__file__).parents[2] / "scripts" / "terminal_checks.py"
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


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
        self.assertEqual(screen.styles[0][:2], [True, False])

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
                    "tmux",
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


if __name__ == "__main__":
    unittest.main()
