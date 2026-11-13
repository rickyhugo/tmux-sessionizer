"""Check session opening against a private server and an attached terminal."""

import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time


def check_existing_comma_session(binary, socket, root):
    if not socket.startswith("tms-port-test-"):
        raise ValueError("Unsafe test socket")
    env = dict(os.environ, TERM="xterm-256color")
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)

    def tmux(*args):
        return subprocess.check_output(
            ["tmux", "-L", socket, *args], env=env, stderr=subprocess.STDOUT
        ).decode()

    def wait_until(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            ready, _, _ = select.select([terminal], [], [], 0.02)
            if ready:
                try:
                    os.read(terminal, 65536)
                except OSError:
                    break
        raise AssertionError(message)

    with tempfile.TemporaryDirectory(prefix="comma-session-", dir=root) as directory:
        path = Path(directory)
        env.update(HOME=str(path), XDG_CONFIG_HOME=str(path), ENV="", BASH_ENV="")
        marker = path / "script-reran"
        barrier = path / "shell-ready"
        script = path / ".tms-create"
        script.write_text(f"#!/bin/sh\nprintf reran > '{marker}'\n")
        script.chmod(0o700)
        conf = path / "tmux.conf"
        conf.write_text("set -g default-shell /bin/sh\nset -g status off\n")
        child = None
        terminal = None
        try:
            tmux("-f", str(conf), "new-session", "-d", "-s", "a,b", "-c", str(path))
            session_id = tmux("display-message", "-p", "-t", "a,b", "#{session_id}")
            child, terminal = pty.fork()
            if child == 0:
                os.execve(str(binary), [str(binary), socket, str(path), "a,b"], env)
            wait_until(
                lambda: tmux("list-clients", "-F", "#{session_name}").strip() == "a,b",
                "Session opening did not attach to the existing comma session",
            )
            tmux("send-keys", "-t", "a,b", f"printf ready > '{barrier}'", "Enter")
            wait_until(
                barrier.exists,
                "The existing session's shell did not process the barrier",
            )
            assert not marker.exists(), (
                "Opening an existing comma session reran .tms-create"
            )
            assert (
                tmux("display-message", "-p", "-t", "a,b", "#{session_id}")
                == session_id
            )
            assert tmux("list-sessions", "-F", "#{session_name}").strip() == "a,b"
            print(
                "Real comma session retained its identity and did not rerun .tms-create"
            )
        finally:
            subprocess.run(
                ["tmux", "-L", socket, "kill-server"], env=env, capture_output=True
            )
            if terminal is not None:
                os.close(terminal)
            if child:
                try:
                    os.kill(child, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.waitpid(child, 0)
