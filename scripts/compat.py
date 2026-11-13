#!/usr/bin/env python3
import argparse
import difflib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import uuid


REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / "tests" / "compat"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def expand(value, root):
    if isinstance(value, str):
        return value.replace("$ROOT", str(root))
    if isinstance(value, list):
        return [expand(item, root) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, root) for key, item in value.items()}
    return value


def normalize(value, root):
    if isinstance(value, str):
        value = (
            ANSI.sub("", value)
            .replace(str(root), "$ROOT")
            .replace(str(REPO), "$SOURCE")
        )
        value = re.sub(r"(?m)^.*╴at [^\n]*\.rs:\d+:\d+\n?", "", value)
        value = re.sub(
            r"thread 'main'(?: \(\d+\))? panicked at [^\n]*:\n", "panic:\n", value
        )
        value = re.sub(r"(?m)^│\s*\n", "", value)
        return value
    if isinstance(value, list):
        return [normalize(item, root) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item, root) for key, item in value.items()}
    return value


class Workspace:
    def __init__(self, root, binary):
        self.root = root
        path = os.pathsep.join(
            entry
            for entry in os.environ["PATH"].split(os.pathsep)
            if not (Path(entry).name == "shims" and "mise" in Path(entry).parts)
        )
        self.tmux = shutil.which("tmux", path=path)
        if not self.tmux:
            raise RuntimeError("tmux is required")
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("TMS_", "GIT_", "JJ_", "_CLAP_"))
            and key not in ("TMUX", "TMUX_PANE", "COMPLETE", "RUST_BACKTRACE")
        }
        self.env.update(
            {
                "HOME": str(root / "home"),
                "XDG_CONFIG_HOME": str(root / "home" / ".config"),
                "TMS_CONFIG_FILE": str(root / "config.toml"),
                "TMS_COMPAT_ROOT": str(root),
                "TMS_TMUX_SOCKET": "tms-compat-" + uuid.uuid4().hex,
                "TMS_REAL_TMUX": self.tmux,
                "TERM_PROGRAM": "tmux",
                "TERM": "xterm-256color",
                "LC_ALL": "C",
                "LANG": "C",
                "TZ": "UTC",
                "NO_COLOR": "1",
                "COLUMNS": "100",
                "LINES": "30",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "init.defaultBranch",
                "GIT_CONFIG_VALUE_0": "main",
                "GIT_AUTHOR_NAME": "compat",
                "GIT_AUTHOR_EMAIL": "compat@example.invalid",
                "GIT_COMMITTER_NAME": "compat",
                "GIT_COMMITTER_EMAIL": "compat@example.invalid",
                "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
                "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
                "JJ_CONFIG": "",
            }
        )
        self.env["TMS_COMPAT_SOCKET"] = self.env["TMS_TMUX_SOCKET"]
        (root / "home").mkdir()
        (root / "search").mkdir()
        (root / "bin").mkdir()
        (root / "bin" / "tms").symlink_to(binary)
        shim = root / "bin" / "tmux"
        shim.write_text(
            f"#!{sys.executable}\n" + (FIXTURES / "tmux_shim.py").read_text()
        )
        shim.chmod(0o755)
        self.env["PATH"] = str(root / "bin") + os.pathsep + path
        (root / "tmux.conf").write_text(
            "set -g default-shell /bin/sh\n"
            "set -g default-command 'exec /bin/sleep 600'\n"
            "set -g base-index 1\n"
            "set -g automatic-rename off\n"
            "set -g status off\n"
        )

    def run(self, argv):
        return subprocess.run(
            argv,
            cwd=self.root,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )

    def tmux_run(self, *argv):
        return self.run(
            [
                self.tmux,
                "-f",
                str(self.root / "tmux.conf"),
                "-L",
                self.env["TMS_COMPAT_SOCKET"],
                *argv,
            ]
        )

    def close(self):
        self.tmux_run("kill-server")

    def setup(self, operations):
        for operation in expand(operations, self.root):
            kind, *args = operation
            if kind == "mkdir":
                (self.root / args[0]).mkdir(parents=True, exist_ok=True)
            elif kind == "write":
                path = self.root / args[0]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(args[1])
            elif kind == "symlink":
                (self.root / args[1]).symlink_to(
                    self.root / args[0], target_is_directory=True
                )
            elif kind == "git":
                result = self.run(["git", *args])
                if result.returncode:
                    raise RuntimeError(result.stderr)
            elif kind == "jj":
                result = self.run(["jj", *args])
                if result.returncode:
                    raise RuntimeError(result.stderr)
            elif kind == "tmux":
                result = self.tmux_run(*args)
                if result.returncode:
                    raise RuntimeError(result.stderr)
            else:
                raise ValueError(f"Unknown setup operation {kind!r}")

    def state(self, paths):
        config_path = self.root / "config.toml"
        config = None
        if config_path.exists():
            try:
                config = tomllib.loads(config_path.read_text())
            except tomllib.TOMLDecodeError:
                config = {"invalid_toml": config_path.read_text()}
        sessions = []
        result = self.tmux_run(
            "list-sessions",
            "-F",
            "#{session_name}|#{session_path}|#{session_windows}",
        )
        for line in result.stdout.splitlines():
            name, path, count = line.split("|")
            windows = self.tmux_run(
                "list-windows", "-t", name, "-F", "#{window_name}|#{pane_current_path}"
            )
            sessions.append(
                {
                    "name": name,
                    "path": path,
                    "window_count": int(count),
                    "windows": sorted(
                        line.split("|") for line in windows.stdout.splitlines()
                    ),
                }
            )
        client_path = self.root / "client.json"
        keys_path = self.root / "keys.jsonl"
        log_path = self.root / "tmux-argv.jsonl"
        calls = (
            [json.loads(line) for line in log_path.read_text().splitlines()]
            if log_path.exists()
            else []
        )
        return normalize(
            {
                "config": config,
                "sessions": sorted(sessions, key=lambda item: item["name"]),
                "client": json.loads(client_path.read_text())
                if client_path.exists()
                else None,
                "keys": [
                    json.loads(line) for line in keys_path.read_text().splitlines()
                ]
                if keys_path.exists()
                else [],
                "tmux_socket_contract": all(
                    call[:2] == ["-L", self.env["TMS_TMUX_SOCKET"]] for call in calls
                ),
                "paths": {path: (self.root / path).exists() for path in paths},
            },
            self.root,
        )


def run_case(case, binary, artifacts=None):
    with tempfile.TemporaryDirectory(prefix="tms-compat-") as tmp:
        root = Path(tmp).resolve()
        workspace = Workspace(root, binary)
        try:
            workspace.setup(case.get("setup", []))
            if "config" in case:
                (root / "config.toml").write_text(expand(case["config"], root))
            results = []
            for step in case["steps"]:
                workspace.setup(step.get("setup", []))
                env = {**workspace.env, **expand(step.get("env", {}), root)}
                result = subprocess.run(
                    [str(root / "bin" / "tms"), *expand(step["argv"], root)],
                    cwd=root / step.get("cwd", "."),
                    env=env,
                    text=True,
                    input=step.get("stdin", ""),
                    capture_output=True,
                    timeout=30,
                )
                stdout = result.stdout
                if step.get("stdout") == "toml" and result.returncode == 0:
                    stdout = tomllib.loads(stdout)
                results.append(
                    normalize(
                        {
                            "argv": step["argv"],
                            "stdout": stdout,
                            "stderr": result.stderr,
                            "exit": result.returncode,
                            "state": workspace.state(case.get("observe_paths", [])),
                        },
                        root,
                    )
                )
            return results
        finally:
            try:
                if artifacts:
                    artifacts.mkdir(parents=True, exist_ok=True)
                    log = root / "tmux-argv.jsonl"
                    if log.exists():
                        calls = [
                            json.loads(line) for line in log.read_text().splitlines()
                        ]
                        text = json.dumps(
                            normalize(calls, root), indent=2, ensure_ascii=False
                        )
                        text = text.replace(
                            workspace.env["TMS_COMPAT_SOCKET"], "$SOCKET"
                        )
                        (artifacts / f"{case['name']}-tmux.json").write_text(
                            text + "\n"
                        )
            finally:
                workspace.close()


def compare(name, actual, expected):
    if actual == expected:
        print(f"PASS {name}")
        return True
    print(f"FAIL {name}")
    print(
        "".join(
            difflib.unified_diff(
                json.dumps(
                    expected, indent=2, ensure_ascii=False, sort_keys=True
                ).splitlines(True),
                json.dumps(
                    actual, indent=2, ensure_ascii=False, sort_keys=True
                ).splitlines(True),
                fromfile="golden",
                tofile="actual",
            )
        )
    )
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Capture or check isolated tms compatibility fixtures."
    )
    parser.add_argument(
        "--bin", default=os.environ.get("TMS_BIN", str(REPO / "zig-out/bin/tms"))
    )
    parser.add_argument(
        "--capture",
        action="store_true",
        help="Replace goldens. Use only the approved Rust baseline.",
    )
    parser.add_argument(
        "--case", action="append", help="Run only a named case. Repeat to select more."
    )
    parser.add_argument(
        "--jj", action="store_true", help="Include cases that require jj."
    )
    parser.add_argument(
        "--artifacts", type=Path, help="Write normalized tmux argv traces."
    )
    parser.add_argument(
        "--oracle",
        default=os.environ.get("TMS_ORACLE_BIN"),
        help="Optional headless ranking executable.",
    )
    args = parser.parse_args()
    binary = Path(args.bin).resolve(strict=True)
    cases = json.loads((FIXTURES / "cases.json").read_text())
    if args.case:
        unknown = set(args.case) - {case["name"] for case in cases}
        if unknown:
            parser.error(f"Unknown cases: {sorted(unknown)}")
        cases = [case for case in cases if case["name"] in args.case]
    golden_path = FIXTURES / "golden.json"
    golden = json.loads(golden_path.read_text()) if golden_path.exists() else {}
    success = True
    executed = 0
    for case in cases:
        if case.get("requires") == "jj" and not args.jj:
            print(f"SKIP {case['name']} (pass --jj with jj installed)")
            continue
        actual = run_case(case, binary, args.artifacts)
        executed += 1
        if args.capture:
            golden[case["name"]] = actual
            print(f"CAPTURE {case['name']}")
        else:
            success = (
                compare(case["name"], actual, golden.get(case["name"])) and success
            )
    if args.capture:
        golden_path.write_text(json.dumps(golden, indent=2, ensure_ascii=False) + "\n")
    if args.oracle:
        oracle = str(Path(args.oracle).resolve(strict=True))
        vectors = json.loads((FIXTURES / "ranking.json").read_text())
        for vector in vectors:
            result = subprocess.run(
                [oracle, "rank", vector["query"], *vector["items"]],
                text=True,
                capture_output=True,
                timeout=30,
                check=True,
            )
            actual = result.stdout.splitlines()
            if args.capture:
                vector["ranked"] = actual
            else:
                success = (
                    compare(f"rank {vector['name']}", actual, vector["ranked"])
                    and success
                )
        if args.capture:
            (FIXTURES / "ranking.json").write_text(
                json.dumps(vectors, indent=2, ensure_ascii=False) + "\n"
            )
    print(f"{executed} compatibility cases executed")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
