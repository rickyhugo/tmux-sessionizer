#!/usr/bin/env python3
"""Measure release-binary startup and picker search. Timings alone prove no speedup."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time

from terminal_checks import Fixture, artifact


def picker_counts(text):
    matches = re.findall(r"(?m)^ *([0-9]+)/([0-9]+)─* *$", text)
    return tuple(map(int, matches[0])) if len(matches) == 1 else None


def sample(binary, fixture, count, output, label):
    start = time.perf_counter()
    version = subprocess.run(
        [str(binary), "--version"],
        env=fixture.env,
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    )
    version_ms = (time.perf_counter() - start) * 1000
    assert version.stdout.lower().startswith(("tmux-sessionizer ", "tms ")), (
        version.stdout
    )
    terminal = fixture.terminal(binary, rows=30, cols=100)
    try:
        terminal.wait(
            lambda s: picker_counts(s.text) == (count, count),
            "all candidates rendered",
        )
        startup_counts = picker_counts(terminal.screen.text)
        startup_ms = (time.perf_counter() - terminal.started) * 1000
        query = f"project-{count - 1:04d}"
        start = time.perf_counter()
        terminal.send(query.encode(), "search unique project")
        terminal.wait(
            lambda s: (
                picker_counts(s.text) == (1, count)
                and any(
                    line.strip() == f"> {query}" for line in s.text.splitlines()[:-1]
                )
            ),
            "unique search result",
            timeout=3,
        )
        search_ms = (time.perf_counter() - start) * 1000
        search_counts = picker_counts(terminal.screen.text)
        picker_to_search_ms = (time.perf_counter() - terminal.started) * 1000
        terminal.send(b"\x03", "cancel measured picker")
        terminal.exit()
        terminal.restored()
        return {
            "version_ms": version_ms,
            "picker_startup_ms": startup_ms,
            "search_ms": search_ms,
            "picker_to_search_ms": picker_to_search_ms,
            "candidates": search_counts[1],
            "matched": search_counts[0],
            "observed_counts": {
                "startup": {
                    "matched": startup_counts[0],
                    "candidates": startup_counts[1],
                },
                "search": {
                    "matched": search_counts[0],
                    "candidates": search_counts[1],
                },
            },
            "errors": 0,
        }
    finally:
        terminal.save(output, label)
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument("--zig", type=Path)
    parser.add_argument(
        "--release-builds",
        action="store_true",
        required=True,
        help="Attest both paths are production-optimized release builds",
    )
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--candidates", type=int, default=1000)
    parser.add_argument("--output", type=Path, default=Path("benchmark-results"))
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("at least five samples per binary are required")
    if args.candidates < 10:
        parser.error("at least ten candidates are required")
    args.output.mkdir(parents=True, exist_ok=True)
    sides = {"rust": args.rust.resolve()}
    if args.zig:
        sides["zig"] = args.zig.resolve()
    report = {
        "verdict": "INCONCLUSIVE",
        "decision": "Only a repeatable gap larger than within-side spread with an identified "
        "limiter could support an adoption claim. This script supplies timings, "
        "not limiter evidence.",
        "limiter": "NOT IDENTIFIED. Collect a separate profile before claiming a speedup.",
        "host": platform.platform(),
        "cores": os.cpu_count(),
        "load": os.getloadavg(),
        "uptime": subprocess.run(
            ["uptime"], capture_output=True, text=True, check=True
        ).stdout.strip(),
        "artifacts": {name: artifact(binary) for name, binary in sides.items()},
        "release_builds_attested": args.release_builds,
        "release_build_command_templates": {
            "rust": "mise exec -- cargo build --release --locked",
            "zig": "mise exec -- zig build -Doptimize=ReleaseFast",
        },
        "invocation": [sys.executable, *sys.argv],
        "tmux": subprocess.run(
            ["tmux", "-V"], capture_output=True, text=True, check=True
        ).stdout.strip(),
        "timing_boundary": "Version uses subprocess launch through validated exit. Picker "
        "uses target launch inside the PTY supervisor through a complete candidate count. "
        "Search uses input write through a unique selected result, not the echoed prompt. "
        "Python supervisor startup and fixture creation are outside picker timings.",
        "cache": "warm filesystem, new process and matcher for every sample, no warmup discarded",
        "search": "Full unique query typed into the real picker after all candidates render. "
        "No extra redraw key is sent. Timeout is a failure, not a latency sample.",
        "samples": [],
        "errors": [],
    }
    fixture = Fixture(args.candidates)
    try:
        for index in range(args.samples):
            for name in sides:
                label = f"{index + 1:02d}-{name}"
                try:
                    result = sample(
                        sides[name], fixture, args.candidates, args.output, label
                    )
                    report["samples"].append(
                        {"side": name, "sample": index + 1, **result}
                    )
                except (AssertionError, OSError, subprocess.SubprocessError) as error:
                    report["errors"].append(
                        {"side": name, "sample": index + 1, "detail": str(error)}
                    )
        report["summary"] = {}
        for name in sides:
            rows = [row for row in report["samples"] if row["side"] == name]
            report["summary"][name] = {
                key: {
                    "median": statistics.median([row[key] for row in rows]),
                    "min": min(row[key] for row in rows),
                    "max": max(row[key] for row in rows),
                    "unit": "ms",
                    "n": len(rows),
                }
                for key in (
                    "version_ms",
                    "picker_startup_ms",
                    "search_ms",
                    "picker_to_search_ms",
                )
                if rows
            }
    finally:
        fixture.close()
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(bool(report["errors"]))


if __name__ == "__main__":
    raise SystemExit(main())
