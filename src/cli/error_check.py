#!/usr/bin/env python3
"""Check expected CLI diagnostics and config preservation; optionally compare Rust."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
USAGE = {
    "": "tms [COMMAND]",
    "bookmark": "tms bookmark [OPTIONS] [PATH]",
    "config": "tms config [OPTIONS]\n       tms config <COMMAND>",
    "config list": "tms config list [OPTIONS]",
    "clone-repo": "tms clone-repo [OPTIONS] <REPOSITORY>",
    "marks": "tms marks [INDEX]\n       tms marks <COMMAND>",
    "marks set": "tms marks set [OPTIONS] [INDEX]",
    "marks open": "tms marks open <INDEX>",
    "help": "tms help [COMMAND]...",
    "config help": "tms config help [COMMAND]...",
    "marks help": "tms marks help [COMMAND]...",
}
MORE = "\nFor more information, try '--help'.\n"


def usage_error(command, message):
    more = "" if command.endswith("help") else MORE
    return f"error: {message}\n\nUsage: {USAGE[command]}\n{more}"


def invalid_utf8(command):
    return usage_error(command, "invalid UTF-8 was detected in one or more arguments")


def unrecognized(command, value):
    return usage_error(command, f"unrecognized subcommand '{value}'")


def literal_command(command, value):
    return usage_error(
        command,
        f"unexpected argument '{value}' found\n\n"
        f"  tip: subcommand '{value}' exists; to use it, remove the '--' before it",
    )


def missing_value(option):
    return f"error: a value is required for '{option}' but none was supplied\n{MORE}"


CASES = [
    ([b"bookmark", b"invalid-\xff"], invalid_utf8("bookmark")),
    ([b"bookmark", b"--", b"invalid-\xff"], invalid_utf8("bookmark")),
    ([b"config", b"--session", b"invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--session=invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"-sinvalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--paths", b"invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--paths=invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--excluded", b"valid", b"invalid-\xff"], invalid_utf8("config")),
    (
        [b"config", b"--full-path", b"\xff"],
        "error: invalid value '�' for '--full-path <true | false>'\n"
        f"  [possible values: true, false]\n{MORE}",
    ),
    ([b"config", b"--max-depths", b"\xff"], invalid_utf8("config")),
    ([b"config", b"--picker-border-color", b"\xff"], invalid_utf8("config")),
    ([b"clone-repo", b"--name", b"\xff", b"url"], invalid_utf8("clone-repo")),
    ([b"marks", b"set", b"--path", b"\xff"], invalid_utf8("marks set")),
    ([b"marks", b"open", b"\xff"], invalid_utf8("marks open")),
    (["help", "config", "--help"], unrecognized("config", "--help")),
    (["help", "marks", "--help"], unrecognized("marks", "--help")),
    (["help", "config", "list", "--help"], unrecognized("config list", "--help")),
    (["help", "help", "config"], unrecognized("help", "config")),
    (["config", "help", "help", "list"], unrecognized("config help", "list")),
    (["marks", "help", "help", "list"], unrecognized("marks help", "list")),
    (["--", "config"], literal_command("", "config")),
    (["config", "--", "list"], literal_command("config", "list")),
    (["config", "--", "help"], literal_command("config", "help")),
    (["config", "--", "unknown"], unrecognized("config", "unknown")),
    (["config", "--paths", "--"], missing_value("--paths <search paths>...")),
    (["config", "-p", "--"], missing_value("--paths <search paths>...")),
    (["config", "--session", "--"], missing_value("--session <default session>")),
    *[
        (
            ["config", "--full-path", "true", "--", command],
            usage_error(
                "config",
                f"the subcommand '{command}' cannot be used with '--full-path <true | false>'",
            ),
        )
        for command in ("list", "unknown")
    ],
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=ROOT / "zig-out/bin/tms")
    parser.add_argument("--reference", type=Path)
    args = parser.parse_args()
    binaries = [args.bin.resolve(strict=True)]
    if args.reference:
        binaries.append(args.reference.resolve(strict=True))
    failures = 0
    (ROOT / ".zig-cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="cli-errors-", dir=ROOT / ".zig-cache"
    ) as d:
        config = Path(d) / "config.toml"
        original = b"default_session = 'preserved'\n"
        env = os.environ | {
            "HOME": d,
            "XDG_CONFIG_HOME": d,
            "TMS_CONFIG_FILE": str(config),
            "NO_COLOR": "1",
        }
        for key in ("COMPLETE", "TMUX"):
            env.pop(key, None)
        for case, stderr in CASES:
            for binary in binaries:
                config.write_bytes(original)
                result = subprocess.run(
                    [str(binary), *case],
                    cwd=d,
                    env=env,
                    capture_output=True,
                    timeout=10,
                )
                actual = (
                    result.returncode,
                    result.stdout,
                    result.stderr,
                    config.read_bytes(),
                )
                expected = (2, b"", stderr.encode(), original)
                if actual != expected:
                    failures += 1
                    print(
                        f"FAIL {binary}: {case!r}\n"
                        f"  expected: {expected!r}\n  actual: {actual!r}"
                    )
    print(f"{len(CASES)} CLI diagnostic/preservation cases; {failures} failures")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
