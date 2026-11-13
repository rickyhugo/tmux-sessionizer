#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile
import time

from compat import REPO, Workspace


def screen(workspace):
    return workspace.tmux_run("capture-pane", "-p", "-t", "driver").stdout


def wait_for(workspace, description, predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = screen(workspace)
        if predicate(value):
            return value
        time.sleep(0.02)
    raise AssertionError(f"Timed out waiting for {description}\n{screen(workspace)}")


def send(workspace, key, literal=False):
    args = ["send-keys", "-t", "driver"]
    if literal:
        args.append("-l")
    result = workspace.tmux_run(*args, key)
    assert result.returncode == 0, result.stderr


def dead_status(workspace):
    return workspace.tmux_run(
        "display-message", "-p", "-t", "driver", "#{pane_dead}:#{pane_dead_status}"
    ).stdout.strip()


def run_scenario(binary, name, position, actions, target, artifacts):
    with tempfile.TemporaryDirectory(prefix="tms-terminal-") as tmp:
        root = Path(tmp).resolve()
        workspace = Workspace(root, binary)
        transcript = {}
        try:
            workspace.setup(
                [
                    ["git", "init", str(root / "search" / repo)]
                    for repo in ("alpha", "beta", "gamma")
                ]
            )
            (root / "config.toml").write_text(
                f"search_paths = ['{root}/search']\ninput_position = '{position}'\n"
                "[shortcuts]\nctrl-q = 'cancel'\n"
            )
            with (root / "tmux.conf").open("a") as config:
                config.write("set -g remain-on-exit on\n")
            result = workspace.tmux_run(
                "new-session",
                "-d",
                "-s",
                "driver",
                "-x",
                "100",
                "-y",
                "30",
                "-c",
                str(root),
                "exec " + shlex.quote(str(root / "bin/tms")),
            )
            assert result.returncode == 0, result.stderr
            transcript["ready"] = wait_for(
                workspace,
                "all three candidates",
                lambda text: "3/3" in text and "alpha" in text and "gamma" in text,
            )
            for index, (key, literal, expected) in enumerate(actions):
                send(workspace, key, literal)
                if expected:
                    transcript[f"action-{index}"] = wait_for(
                        workspace, expected, lambda text: expected in text
                    )
            wait_for(
                workspace,
                "picker exit",
                lambda _: dead_status(workspace).startswith("1:"),
            )
            assert dead_status(workspace) == "1:0", dead_status(workspace)
            state = workspace.state([])
            session_names = [
                session["name"]
                for session in state["sessions"]
                if session["name"] != "driver"
            ]
            assert session_names == ([target] if target else []), state
            if target:
                assert state["client"]["target"] == target, state
            transcript["final"] = screen(workspace)
            if artifacts:
                artifacts.mkdir(parents=True, exist_ok=True)
                (artifacts / f"{name}.json").write_text(
                    json.dumps(transcript, indent=2, ensure_ascii=False) + "\n"
                )
            print(f"PASS terminal {name}")
        finally:
            workspace.close()


def main():
    parser = argparse.ArgumentParser(
        description="Drive the native picker through real tmux PTYs on private sockets."
    )
    parser.add_argument(
        "--bin", default=os.environ.get("TMS_BIN", str(REPO / "zig-out/bin/tms"))
    )
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    binary = Path(args.bin).resolve(strict=True)
    scenarios = [
        ("escape", "Bottom", [("Escape", False, None)], None),
        ("ctrl-c", "Bottom", [("C-c", False, None)], None),
        ("custom-cancel", "Top", [("C-q", False, None)], None),
        (
            "filter-confirm",
            "Bottom",
            [("bet", True, "1/3"), ("Enter", False, None)],
            "beta",
        ),
        (
            "bottom-navigation",
            "Bottom",
            [("Up", False, "> beta"), ("Enter", False, None)],
            "beta",
        ),
        (
            "top-navigation",
            "Top",
            [("Down", False, "> beta"), ("Enter", False, None)],
            "beta",
        ),
        (
            "edit-backspace",
            "Bottom",
            [
                ("betx", True, "0/3"),
                ("BSpace", False, "1/3"),
                ("Enter", False, None),
            ],
            "beta",
        ),
    ]
    for scenario in scenarios:
        run_scenario(binary, *scenario, args.artifacts)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
