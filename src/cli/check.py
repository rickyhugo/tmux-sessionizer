"""Compare the scoped driver with a separately built Rust reference."""

import argparse
import json
import os
from pathlib import Path
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


def compare(binary, rust, dynamic):
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
        "--dynamic",
        action="store_true",
        help="Require integrated repository and session modules",
    )
    args = parser.parse_args()
    compare(args.bin.resolve(), args.rust.resolve(), args.dynamic)
