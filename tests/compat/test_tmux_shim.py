import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SHIM = Path(__file__).with_name("tmux_shim.py")


class TmuxShimTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tms-shim-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        fake = self.root / "fake-tmux"
        fake.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "with (Path(os.environ['TMS_COMPAT_ROOT']) / 'launched.jsonl').open('a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('TMS_FAKE_TMUX_EXIT', '0')))\n"
        )
        fake.chmod(0o755)
        self.env = {
            **os.environ,
            "TMS_COMPAT_ROOT": str(self.root),
            "TMS_REAL_TMUX": str(fake),
            "TMS_COMPAT_SOCKET": "private-fixture-socket",
            "TMS_TMUX_SOCKET": "default",
            "TMS_FAKE_TMUX_EXIT": "0",
        }

    def run_shim(self, args):
        return subprocess.run(
            [sys.executable, str(SHIM), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def read_log(self, name):
        return [
            json.loads(line) for line in (self.root / name).read_text().splitlines()
        ]

    def test_rejects_missing_selector_without_launching_tmux(self):
        for args in ([], ["-L"], ["kill-server"]):
            with self.subTest(args=args):
                result = self.run_shim(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr)
                self.assertFalse((self.root / "launched.jsonl").exists())

    def test_rejects_global_options_without_launching_tmux(self):
        options = [
            ["-Ldefault"],
            ["-S", "/unused/socket"],
            ["-S/unused/socket"],
            ["-u", "-L", "default"],
            ["-f", "/unused/tmux.conf"],
            ["--"],
        ]
        for prefix in ([], ["-L", "caller-socket"]):
            for option in options:
                args = [*prefix, *option, "kill-server"]
                with self.subTest(args=args):
                    result = self.run_shim(args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(result.stderr)
                    self.assertFalse((self.root / "launched.jsonl").exists())

    def test_rejects_second_socket_selector_without_launching_tmux(self):
        result = self.run_shim(["-L", "caller-socket", "-L", "default", "kill-server"])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertFalse((self.root / "launched.jsonl").exists())

    def test_forces_private_socket_and_preserves_command_arguments(self):
        commands = [
            ["kill-server"],
            ["new-session", "-d", "-s", "fixture"],
            ["list-sessions", "-F", "#{session_name}", "-f", "#{session_attached}"],
            ["send-keys", "-t", "fixture", "-Ldefault", "Enter"],
        ]
        for command in commands:
            with self.subTest(command=command):
                args = ["-L", "default", *command]
                result = self.run_shim(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.read_log("launched.jsonl")[-1],
                    [
                        "-f",
                        str(self.root / "tmux.conf"),
                        "-L",
                        "private-fixture-socket",
                        *command,
                    ],
                )
                self.assertEqual(self.read_log("tmux-argv.jsonl")[-1], args)
        self.assertEqual(
            self.read_log("keys.jsonl"),
            [["-t", "fixture", "-Ldefault", "Enter"]],
        )

    def test_start_and_client_requests_do_not_launch_tmux(self):
        commands = [
            ([], {"command": "tmux", "target": None}),
            (["attach"], {"command": "attach", "target": None}),
            (
                ["attach-session", "-t", "fixture"],
                {"command": "attach-session", "target": "fixture"},
            ),
            (
                ["switch-client", "-t", "fixture"],
                {"command": "switch-client", "target": "fixture"},
            ),
        ]
        for command, expected in commands:
            with self.subTest(command=command):
                result = self.run_shim(["-L", "caller-socket", *command])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    json.loads((self.root / "client.json").read_text()), expected
                )
                self.assertFalse((self.root / "launched.jsonl").exists())

    def test_returns_tmux_exit_status(self):
        self.env["TMS_FAKE_TMUX_EXIT"] = "23"
        result = self.run_shim(["-L", "caller-socket", "list-sessions"])
        self.assertEqual(result.returncode, 23)


if __name__ == "__main__":
    unittest.main()
