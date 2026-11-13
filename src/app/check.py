#!/usr/bin/env python3
"""Run command, catalog, and tmux tests without contacting the default socket."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

from real_check import check_existing_comma_session

ROOT = Path(__file__).resolve().parents[2]


def graph(root, process, root_deps, catalog_config=False):
    modules = [
        (root, root_deps, "root"),
        (
            "src/sessions/catalog_config.zig" if catalog_config else "src/config.zig",
            ["config_types"] if catalog_config else [],
            "config",
        ),
        ("src/config.zig", [], "config_types"),
        (process, [], "process"),
        ("src/repos.zig", ["config", "process"], "repos"),
        ("src/tmux.zig", ["process"], "tmux"),
        ("src/sessions.zig", ["config", "repos", "tmux"], "sessions"),
        ("src/matcher.zig", [], "matcher"),
        ("src/picker.zig", ["config", "matcher", "tmux"], "picker"),
        ("src/cli.zig", ["config", "sessions"], "cli"),
    ]
    needed = {"root"}
    pending = ["root"]
    by_name = {name: dependencies for _, dependencies, name in modules}
    while pending:
        for dependency in by_name[pending.pop()]:
            if dependency not in needed:
                needed.add(dependency)
                pending.append(dependency)
    args = ["zig", "test", "-cflags", "-std=c17", "--", "vendor/tomlc17/tomlc17.c"]
    for source, dependencies, name in modules:
        if name not in needed:
            continue
        for dependency in dependencies:
            args.extend(["--dep", dependency])
        args.append(f"-M{name}={source}")
    return args + ["-lc"]


def run(args, env=None):
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real-tmux", action="store_true")
    options = parser.parse_args()
    fake = "src/tmux/fake_process.zig"
    run(graph("src/tmux/spec.zig", fake, ["tmux", "process"]))
    run(graph("src/sessions/spec.zig", fake, ["sessions", "config", "tmux", "process"]))
    run(
        graph(
            "src/app.zig",
            fake,
            ["config", "process", "repos", "tmux", "sessions", "picker", "cli"],
        )
    )
    run(
        graph(
            "src/sessions/real_spec.zig",
            "src/process.zig",
            ["sessions", "config", "process"],
            catalog_config=True,
        )
    )
    if options.real_tmux:
        env = dict(os.environ, TMS_TMUX_SOCKET="tms-port-test-" + uuid.uuid4().hex)
        run(
            graph("src/tmux/real_spec.zig", "src/process.zig", ["tmux", "process"]), env
        )
        with tempfile.TemporaryDirectory(
            prefix="session-driver-", dir=ROOT / ".zig-cache"
        ) as directory:
            binary = Path(directory) / "open-session"
            args = graph(
                "src/sessions/open_driver.zig",
                "src/process.zig",
                ["sessions", "config", "tmux"],
            )
            args[1] = "build-exe"
            run(args + [f"-femit-bin={binary}"])
            check_existing_comma_session(binary, env["TMS_TMUX_SOCKET"], directory)


if __name__ == "__main__":
    main()
