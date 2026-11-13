"""Build the config/CLI driver without changing the application or build graph."""

import argparse
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--domains", type=Path, default=root / "src")
parser.add_argument("--output", type=Path, default=root / ".zig-cache/config-driver")
args = parser.parse_args()
domains = args.domains.resolve()
subprocess.run(
    [
        "zig",
        "build-exe",
        "-Odebug",
        "--dep",
        "config",
        "--dep",
        "cli",
        f"-Mroot={root / 'src/cli/driver.zig'}",
        "-cflags",
        "-std=c17",
        "--",
        str(root / "vendor/tomlc17/tomlc17.c"),
        "-I",
        str(root / "vendor/tomlc17"),
        f"-Mconfig={root / 'src/config.zig'}",
        "--dep",
        "config",
        "--dep",
        "sessions",
        f"-Mcli={root / 'src/cli.zig'}",
        "--dep",
        "config",
        "--dep",
        "repos",
        "--dep",
        "tmux",
        f"-Msessions={domains / 'sessions.zig'}",
        "--dep",
        "config",
        "--dep",
        "process",
        f"-Mrepos={domains / 'repos.zig'}",
        "--dep",
        "process",
        f"-Mtmux={domains / 'tmux.zig'}",
        f"-Mprocess={domains / 'process.zig'}",
        "-lc",
        f"-femit-bin={args.output.resolve()}",
    ],
    cwd=root,
    check=True,
)
