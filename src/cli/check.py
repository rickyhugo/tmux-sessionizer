"""Compare the scoped driver with a separately built Rust reference."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib


def run(binary, args, env):
    return subprocess.run(
        [str(binary), *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def regressions(binary, rust, config, env):
    env = env | {"NO_COLOR": "1"}
    forms = [
        ["config", "--excluded", "first", "--excluded", "second"],
        [
            "config",
            "--paths",
            env["HOME"],
            "--paths",
            env["HOME"],
            "--max-depths",
            "1",
            "--max-depths",
            "2",
        ],
        ["config", "--remove", "first", "--remove", "second"],
        ["config", "-s==work"],
        ["config", "-s==="],
        ["config", "-s="],
        ["config", "--paths", "--help"],
        ["config", "--paths", "-h"],
        ["config", "--paths", "--full-path", "true", "--help"],
        ["config", "--max-depths", "bad", "--help"],
        ["config", "--full-path", "true", "--full-path", "false"],
    ]
    for args in forms:
        results = []
        for executable in (rust, binary):
            config.write_text("excluded_dirs = ['first', 'second']\n")
            result = run(executable, args, env)
            results.append(
                (
                    result.returncode,
                    result.stdout,
                    result.stderr,
                    tomllib.loads(config.read_text()),
                )
            )
        assert results[0] == results[1], (args, results)
    timestamps = [
        "2016-12-31T23:59:60Z",
        "2016-12-31 23:59:60.123456789+02:30",
        "2016-12-31t23:59:60z",
        "23:59:60",
        "00:00:60.000000001",
    ]
    for timestamp in timestamps:
        config.write_text(f"default_session = {timestamp}\n")
        results = [
            run(executable, ["config", "list"], env) for executable in (rust, binary)
        ]
        assert all(r.returncode == 0 for r in results), (timestamp, results)
        assert tomllib.loads(results[0].stdout) == tomllib.loads(results[1].stdout)
        assert config.read_text() == f"default_session = {timestamp}\n"
    for timestamp in ("23:59:61", "24:00:60", "23:60:60"):
        config.write_text(f"default_session = {timestamp}\n")
        assert all(
            run(executable, ["config", "list"], env).returncode == 1
            for executable in (rust, binary)
        ), timestamp
    malformed = [
        "directories = [",
        "directories = [\n",
        "directories = [\n\n",
        "directories = [1",
        "directories = [1 \n",
        "directories = [1,\n",
        "directories = [ # ] ignored\n",
        "directories = [\n [1,\n",
        'directories = ["[", # ]\n',
        'directories = [\n "é",\n',
        "directories = [\r\n",
        'directories = ["escaped \\" ]",\n',
        "directories = [1979-05-27 07:32:00,\n",
        "[nested]\ndirectories = [\n",
        "[[nested]]\ndirectories = [\n",
        "directories = ['unfinished",
        'directories = [\n """unfinished\n',
        "directories = [\n '''unfinished\n",
        "\n" * 10 + "directories = [\n",
    ]

    def diagnostic(text):
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
        text = re.sub(r"(?m)^.*╴at [^\n]*\.rs:\d+:\d+\n?", "", text)
        return re.sub(r"(?m)^│\s*\n", "", text)

    for text in malformed:
        config.write_text(text)
        results = [
            run(executable, ["config", "list"], env) for executable in (rust, binary)
        ]
        assert all(r.returncode == 1 for r in results), (text, results)
        assert diagnostic(results[0].stderr) == diagnostic(results[1].stderr), (
            text,
            results[0].stderr,
            results[1].stderr,
        )
        assert config.read_bytes() == text.encode()
    fallbacks = (
        "directories = [1 2",
        "directories = [1,,",
        "directories = [\n 1\n 2",
        'directories = ["bad\\q",\n',
        "directories = [{path = ,},\n",
        "[unclosed\n",
    )
    for text in fallbacks:
        config.write_text(text)
        result = run(binary, ["config", "list"], env)
        assert result.returncode == 1 and "unclosed array" not in result.stderr, (
            text,
            result.stderr,
        )
    config.write_text("default_session = 'unreadable'\n")
    config.chmod(0)
    try:
        results = [
            run(executable, ["config", "list"], env) for executable in (rust, binary)
        ]
        assert all(r.returncode == 0 for r in results), results
        assert tomllib.loads(results[0].stdout) == tomllib.loads(results[1].stdout)
        assert "default_session" not in tomllib.loads(results[0].stdout)
    finally:
        config.chmod(0o600)
    config.unlink()
    print(
        f"PASS {len(forms)} argument regressions, {len(timestamps) + 3} timestamp "
        f"regressions, {len(malformed)} source diagnostics, {len(fallbacks)} native "
        "diagnostic fallbacks, unreadable optional source"
    )


def jj_regressions(binary, rust, config, env):
    search = Path(env["HOME"]) / "jj-search"
    search.mkdir()
    commands = [
        ["git", "init", "--quiet", str(search / "ordinary")],
        ["jj", "git", "init", "--no-colocate", str(search / "primary")],
        [
            "jj",
            "-R",
            str(search / "primary"),
            "workspace",
            "add",
            str(search / "linked"),
        ],
    ]
    env = env | {
        "JJ_CONFIG": "",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    for command in commands:
        subprocess.run(command, env=env, capture_output=True, check=True)
    count = 0
    for worktrees in ("false", "true"):
        config.write_text(
            f"vcs_providers = ['jj', 'git']\nlist_worktrees = {worktrees}\n"
            f"search_paths = [{json.dumps(str(search))}]\n"
        )
        for shell in ("bash", "elvish", "fish", "powershell", "zsh"):
            for token in ("", "p", "o", "--h"):
                words = ["tms", "open-session", token]
                complete_env = env | {
                    "COMPLETE": shell,
                    "_CLAP_COMPLETE_INDEX": "2",
                }
                results = [
                    run(executable, ["--", *words], complete_env)
                    for executable in (rust, binary)
                ]
                assert all(r.returncode == 0 for r in results), results
                assert (results[0].stdout, results[0].stderr) == (
                    results[1].stdout,
                    results[1].stderr,
                ), (worktrees, shell, token, results)
                count += 1
    config.unlink()
    print(f"PASS {count} jj child-environment and discovery-failure completions")


def compare(binary, rust, dynamic, jj=False):
    commands = [
        [],
        ["config"],
        ["config", "list"],
        ["start"],
        ["switch"],
        ["windows"],
        ["kill"],
        ["sessions"],
        ["rename"],
        ["refresh"],
        ["clone-repo"],
        ["init-repo"],
        ["bookmark"],
        ["open-session"],
        ["marks"],
        ["marks", "list"],
        ["marks", "set"],
        ["marks", "open"],
        ["marks", "delete"],
    ]
    probes = [
        (shell, ["tms", *command, token])
        for command in commands
        for shell in ("bash", "fish", "zsh", "elvish", "powershell")
        for token in ("", "-", "--", "--h", "-h", "x")
    ]
    for command in (
        ["config", "--full-path"],
        ["config", "--paths", "x"],
        ["config", "--session-sort-order"],
        ["config", "--clone-repo-switch"],
        ["marks", "--"],
        ["help"],
        ["help", "marks"],
        ["help", "marks", "set"],
        ["config", "help"],
    ):
        probes.extend(
            ("bash", ["tms", *command, token]) for token in ("", "-", "t", "L", "--h")
        )
    with tempfile.TemporaryDirectory(prefix="tms-config-check-") as directory:
        config = Path(directory) / "config.toml"
        env = os.environ | {
            "HOME": directory,
            "TMS_CONFIG_FILE": str(config),
        }
        env.pop("COMPLETE", None)
        regressions(binary, rust, config, env)
        if jj:
            jj_regressions(binary, rust, config, env)
        help_forms = [
            [*command, flag] for command in commands for flag in ("--help", "-h")
        ] + [
            ["help", "help"],
            ["config", "help", "help"],
            ["marks", "help", "help"],
            ["help", "config", "help"],
        ]
        for args in help_forms:
            actual = run(binary, args, env)
            expected = run(rust, args, env)
            assert (actual.returncode, actual.stdout, actual.stderr) == (
                expected.returncode,
                expected.stdout,
                expected.stderr,
            ), (args, expected.stdout, actual.stdout)
        for shell, words in probes:
            complete_env = env | {
                "COMPLETE": shell,
                "_CLAP_COMPLETE_INDEX": str(len(words) - 1),
            }
            actual = run(binary, ["--", *words], complete_env)
            expected = run(rust, ["--", *words], complete_env)
            assert (actual.returncode, actual.stdout) == (
                expected.returncode,
                expected.stdout,
            ), (shell, words, expected.stdout, actual.stdout, actual.stderr)
        for shell in ("bash", "elvish", "fish", "powershell", "zsh"):
            registration = []
            for executable in (rust, binary):
                result = run(executable, [], env | {"COMPLETE": shell})
                assert result.returncode == 0, result.stderr
                registration.append(
                    result.stdout.replace(str(executable), "$EXE").replace(
                        executable.name, "$BIN"
                    )
                )
            assert registration[0] == registration[1], (
                shell,
                registration[0],
                registration[1],
            )
        configs = [
            "",
            "display_full_path = 'yes'\nsearch_submodules = 2\nrecursive_submodules = 0.5\n"
            "switch_filter_unknown = 'OFF'\nlist_worktrees = 'On'\n",
            "search_dirs = [{path = true, depth = 2.6}, {path = 1.2, depth = 'yes'}]\n"
            "search_paths = []\nbookmarks = []\nexcluded_dirs = []\nvcs_providers = []\n",
            "default_session = 1.0\nsession_sort_order = 'LastAttached'\n"
            "clone_repo_switch = 'Foreground'\ninput_position = 'Top'\n"
            "vcs_providers = ['jj', 'git', 'jujutsu']\n",
            "sessions = [{name = 9, path = false, windows = [{name = '一', path = '~/项目', "
            "command = 2.5, panes = [{ignored = true}, {}]}]}]\n",
            "[picker_colors]\nhighlight_color = 'bright-blue'\n"
            "highlight_text_color = {Indexed = 5}\nborder_color = {Rgb = [1, 3, 255]}\n"
            "info_color = 'silver'\nprompt_color = 'light-black'\n",
            "[shortcuts]\n'ctrl-Q' = 'cancel'\n'garbage-ins' = ''\n"
            "'SHIFT-CTRL-X' = 'delete_to_line_end'\n",
            "[marks]\n'0' = 4\n'bad' = '/missing'\n[session_configs.'项目']\n"
            "create_script = false\n",
            "default_session = 1979-05-27t07:32:00.1234567899z\n",
            "default_session = 1979-05-27 07:32:00.000100000-00:00\n",
            "default_session = 07:32:00.001000000\n",
            "default_session = 1979-05-27\n",
            "search_dirs = [['one', 'yes']]\nsessions = [['一', 'b', []]]\n"
            "session_sort_order = {LastAttached = false}\nvcs_providers = [{jj = 1}]\n"
            "[shortcuts]\n'ctrl-c' = {cancel = []}\n",
        ]
        for text in configs:
            config.write_text(text)
            results = []
            for executable in (rust, binary):
                result = run(executable, ["config", "list"], env)
                assert result.returncode == 0, (text, result.stderr)
                results.append(tomllib.loads(result.stdout))
            assert results[0] == results[1], (text, results)
        project = Path(directory) / "项目"
        project.mkdir()
        missing = str(project / "missing")
        edits = [
            ["config", "--paths", f"{project}/", directory, "--max-depths", "2"],
            ["config", "--max-depths", "7", "8", "9"],
            ["config", "--session", "a.b-c", "--excluded", "vendor*", "vendor*"],
            ["config", "--excluded", "skip", "--remove", "vendor*"],
            ["config", "--picker-prompt-color", "bright-red"],
            ["bookmark", str(project)],
            ["bookmark", str(project)],
            ["bookmark", missing],
            ["bookmark"],
            ["bookmark", "--delete", str(project)],
            ["bookmark", "--delete", missing],
            ["bookmark", "--delete", missing],
            ["marks", "set", "0", "--path", missing],
            ["marks", "set", "--path", str(project)],
            ["marks", "set", "--path", str(project)],
            ["marks", "set", "3", "--path", missing],
            ["marks", "set", "--path", str(project)],
            ["marks", "set", "9"],
            ["marks", "list"],
            ["marks", "delete", "0"],
            ["marks", "delete", "0"],
            ["marks", "delete", "--all"],
            ["marks", "list"],
        ]
        edit_runs = []
        for executable in (rust, binary):
            config.write_text(
                "input_position = 'Top'\nsearch_paths = ['legacy']\nunknown = 42\n"
            )
            states = []
            for args in edits:
                result = run(executable, args, env)
                assert result.returncode == 0, (args, result.stderr)
                states.append(
                    (
                        result.stdout,
                        result.stderr,
                        tomllib.loads(config.read_text()),
                    )
                )
            edit_runs.append(states)
        for args, expected, actual in zip(edits, *edit_runs):
            assert expected == actual, (args, expected, actual)
        dynamic_count = 0
        if dynamic:
            search = Path(directory) / "search"
            paths = [
                search / "a" / "project",
                search / "b" / "project",
                search / "dot.name",
                search / "一 项目",
            ]
            for path in paths:
                path.mkdir(parents=True)
                subprocess.run(
                    ["git", "init", "--quiet", str(path)],
                    env=env
                    | {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull},
                    check=True,
                    capture_output=True,
                )
            bookmark = Path(directory) / "book mark"
            bookmark.mkdir()
            for full_path in ("false", "true"):
                config.write_text(
                    f"display_full_path = {full_path}\n"
                    f"search_dirs = [{{path = {json.dumps(str(search))}, depth = 3}}]\n"
                    f"bookmarks = [{json.dumps(str(bookmark))}]\n"
                    "[marks]\n"
                    f"'0' = {json.dumps(str(search / 'missing'))}\n"
                    f"'1' = {json.dumps(str(paths[0]))}\n"
                    f"'3' = {json.dumps(str(paths[3]))}\n"
                    f"'bad' = {json.dumps(str(paths[0]))}\n"
                )
                for command in (
                    ["open-session"],
                    ["marks"],
                    ["marks", "open"],
                    ["marks", "delete"],
                ):
                    for shell in ("bash", "fish", "zsh", "elvish", "powershell"):
                        for token in ("", "p", "/", "一", "3"):
                            words = ["tms", *command, token]
                            complete_env = env | {
                                "COMPLETE": shell,
                                "_CLAP_COMPLETE_INDEX": str(len(words) - 1),
                            }
                            expected = run(rust, ["--", *words], complete_env)
                            actual = run(binary, ["--", *words], complete_env)
                            assert (actual.returncode, actual.stdout) == (
                                expected.returncode,
                                expected.stdout,
                            ), (full_path, shell, words, expected.stdout, actual.stdout)
                            dynamic_count += 1
    print(
        f"PASS {len(probes)} completion probes, 5 registration scripts, {len(configs)} exports"
    )
    print(f"PASS {len(edits)} settings, bookmark, and mark persistence comparisons")
    print(f"PASS {len(help_forms)} long, short, and generated-help comparisons")
    if dynamic:
        print(
            f"PASS {dynamic_count} dynamic visible-key and valid-mark completion probes"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, required=True)
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument(
        "--jj",
        action="store_true",
        help="Require jj and compare mixed-provider completion with linked workspaces",
    )
    parser.add_argument(
        "--dynamic",
        action="store_true",
        help="Require integrated repository and session modules",
    )
    args = parser.parse_args()
    compare(args.bin.resolve(), args.rust.resolve(), args.dynamic, args.jj)
