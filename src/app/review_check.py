#!/usr/bin/env python3
"""Check reviewed init/listing regressions on private compatibility sockets."""

import argparse
import importlib.util
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("compat", ROOT / "scripts/compat.py")
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)
TEMPLATES = ROOT / "src/repos/template"


def check_init(workspace, kind):
    root = workspace.root
    target = root / "search/fresh"
    metadata = target / ".git"
    if kind.startswith("existing-"):
        if kind == "existing-empty":
            metadata.mkdir(parents=True)
        elif kind == "existing-repository":
            workspace.setup([["git", "init", str(target)]])
        else:
            workspace.setup([["git", "init", str(root / "other")]])
            target.mkdir()
            metadata.write_text("gitdir: " + str(root / "other/.git") + "\n")
        before = {
            str(path.relative_to(target)): path.read_bytes()
            for path in target.rglob("*")
            if path.is_file()
        }
        result = workspace.run(["tms", "init-repo", "fresh"])
        assert result.returncode == 1, result
        assert before == {
            str(path.relative_to(target)): path.read_bytes()
            for path in target.rglob("*")
            if path.is_file()
        }
        assert not workspace.state([])["sessions"]
        return

    if kind.startswith("GIT_"):
        redirect = root / "redirect"
        redirect.mkdir()
        workspace.env[kind] = str(redirect)
    if kind in ("template-config", "template-environment"):
        template = root / "template"
        (template / "hooks").mkdir(parents=True)
        (template / "hooks/post-checkout").write_text("custom hook\n")
        (template / "HEAD").write_text("ref: refs/heads/custom\n")
        workspace.env.update(
            GIT_CONFIG_COUNT="3",
            GIT_CONFIG_KEY_0="init.defaultBranch",
            GIT_CONFIG_VALUE_0="configured",
            GIT_CONFIG_KEY_1="init.templateDir",
            GIT_CONFIG_VALUE_1=str(template),
            GIT_CONFIG_KEY_2="init.defaultObjectFormat",
            GIT_CONFIG_VALUE_2="sha256",
            GIT_DEFAULT_HASH="sha256",
        )
        if kind == "template-environment":
            workspace.env["GIT_TEMPLATE_DIR"] = str(template)
    if kind == "default-branch":
        workspace.env["GIT_CONFIG_COUNT"] = "0"

    result = workspace.run(["tms", "init-repo", "fresh"])
    assert result.returncode == 0, result
    assert (metadata / "HEAD").read_text() == (
        "ref: refs/heads/configured\n"
        if kind.startswith("template-")
        else "ref: refs/heads/main\n"
    )
    assert (metadata / "objects/info").is_dir()
    assert (metadata / "objects/pack").is_dir()
    assert "sha256" not in (metadata / "config").read_text()
    for path in TEMPLATES.rglob("*"):
        if path.is_file() and path.name not in ("README.md", "LICENSE"):
            assert (
                metadata / path.relative_to(TEMPLATES)
            ).read_bytes() == path.read_bytes()
    assert not (metadata / "hooks/post-checkout").exists()
    if kind.startswith("GIT_"):
        assert not list((root / "redirect").iterdir())


def check_listing(workspace, name, reference):
    workspace.setup(
        [
            [
                "tmux",
                "new-session",
                "-d",
                "-s",
                name,
                "-c",
                str(workspace.root / "search"),
            ]
        ]
    )
    result = workspace.run(["tms", "sessions"])
    # Rust preserves the literal list name, but strips quotes from the current
    # name. The fixed command also keeps current-session identity intact.
    expected = name + ("  \n" if reference else "*  \n")
    assert result.returncode == 0, result
    assert result.stdout == expected, repr(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/tms")
    parser.add_argument(
        "--rust", type=Path, help="Also verify the retained Rust reference"
    )
    args = parser.parse_args()
    binaries = [(args.binary.resolve(strict=True), False)]
    if args.rust:
        binaries.append((args.rust.resolve(strict=True), True))
    cases = [
        "existing-empty",
        "existing-repository",
        "existing-pointer",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "template-config",
        "template-environment",
        "default-branch",
    ]
    failures = 0
    for binary, reference in binaries:
        for case in cases + ["quo'te,ui", "'edge'", " a 'b,c "]:
            with tempfile.TemporaryDirectory(prefix="tms-review-") as directory:
                workspace = compat.Workspace(Path(directory).resolve(), binary)
                try:
                    (workspace.root / "config.toml").write_text(
                        "[[search_dirs]]\npath = '"
                        + str(workspace.root / "search")
                        + "'\ndepth = 1\n"
                    )
                    if case in cases:
                        check_init(workspace, case)
                    else:
                        check_listing(workspace, case, reference)
                    print(f"PASS {'Rust' if reference else 'Zig'} {case}")
                except (AssertionError, OSError) as error:
                    failures += 1
                    print(f"FAIL {'Rust' if reference else 'Zig'} {case}: {error}")
                finally:
                    workspace.close()
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
