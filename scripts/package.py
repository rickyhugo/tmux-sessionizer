#!/usr/bin/env python3
"""Build and inspect release archives. Run through mise."""

import argparse
import gzip
import hashlib
import io
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Required distribution notices, including names that prefix discovery misses.
# Keep the independent policy assertions in tests/packaging in sync.
REQUIRED_SOURCE_NOTICES = (
    "LICENSE",
    "src/cli/registration/LICENSE",
    "src/config/UNICODE-LICENSE",
    "src/picker/LICENSE-unicode-width",
    "src/repos/template/LICENSE",
    "vendor/licenses/matcher/NOTICE.md",
    "vendor/licenses/matcher/Unicode-3.0.txt",
    "vendor/licenses/matcher/nucleo-MPL-2.0.txt",
    "vendor/licenses/matcher/unicode-Apache-2.0.txt",
    "vendor/licenses/matcher/unicode-COPYRIGHT.txt",
    "vendor/licenses/matcher/unicode-MIT.txt",
    "vendor/tomlc17/LICENSE",
)
TARGETS = {
    "aarch64-apple-darwin": ("aarch64-macos", "Darwin", "arm64"),
    "x86_64-apple-darwin": ("x86_64-macos", "Darwin", "x86_64"),
    "x86_64-unknown-linux-gnu": ("x86_64-linux-gnu.2.28", "Linux", "x86_64"),
    "x86_64-unknown-linux-musl": ("x86_64-linux-musl", "Linux", "x86_64"),
}
VERSION_PATTERN = (
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
)


def version():
    values = re.findall(
        r'^\s*\.version\s*=\s*"([^"]+)"\s*,\s*$',
        (ROOT / "build.zig.zon").read_text(),
        re.MULTILINE,
    )
    if len(values) != 1 or not re.fullmatch(VERSION_PATTERN, values[0]):
        raise ValueError("build.zig.zon must contain one literal semantic version")
    return values[0]


def notices():
    files = {}
    for name in REQUIRED_SOURCE_NOTICES:
        path = ROOT / name
        if path.is_symlink():
            raise ValueError(f"license or notice must not be a symlink: {path}")
        if not path.is_file():
            raise ValueError(f"required license or notice is missing: {path}")
        files[Path(name)] = path
    # Include additional conventionally named notices without weakening the
    # required manifest when a source notice is removed or renamed.
    for base in (ROOT, ROOT / "vendor", ROOT / "src"):
        if not base.exists():
            continue
        candidates = base.iterdir() if base == ROOT else base.rglob("*")
        for path in candidates:
            relative = path.relative_to(ROOT)
            if path.is_file() and (
                relative.is_relative_to("vendor/licenses")
                or path.name.upper().startswith(
                    (
                        "LICENSE",
                        "LICENCE",
                        "COPYING",
                        "COPYRIGHT",
                        "NOTICE",
                        "THIRD_PARTY",
                    )
                )
            ):
                if path.is_symlink():
                    raise ValueError(f"license or notice must not be a symlink: {path}")
                files[relative] = path
    compiler = Path(shutil.which("zig")).resolve().parent
    for name, relative in {
        "zig/LICENSE": "LICENSE",
        "musl/COPYRIGHT": "lib/libc/musl/COPYRIGHT",
        "glibc/LICENSES": "lib/libc/glibc/LICENSES",
    }.items():
        files[Path("notices") / name] = compiler / relative
    return dict(sorted(files.items()))


def install_notices(destination):
    for relative, source in notices().items():
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, output)
        output.chmod(0o644)


def archive_name(target):
    return f"tms-{version()}-{target}"


def require_native(target):
    _, system, machine = TARGETS[target]
    if (platform.system(), platform.machine()) != (system, machine):
        raise ValueError(f"--smoke requires a native {target} host")


def verify(archive, target, smoke=False):
    name = archive_name(target)
    if archive.name != f"{name}.tar.gz":
        raise ValueError(f"expected archive name {name}.tar.gz")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    checksum = archive.with_name(archive.name + ".sha256").read_text()
    if checksum != f"{digest}  {archive.name}\n":
        raise ValueError("archive checksum does not match")
    legal_files = {
        f"{name}/{path.as_posix()}": source for path, source in notices().items()
    }
    expected = {f"{name}/tms": 0o755}
    expected.update({path: 0o644 for path in legal_files})
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        if (
            len(members) != len(expected)
            or {m.name for m in members} != expected.keys()
        ):
            raise ValueError(
                "archive must contain only tms and the current licenses and notices"
            )
        for member in members:
            if (
                not member.isfile()
                or member.mode != expected[member.name]
                or not member.size
            ):
                raise ValueError(f"invalid archive member: {member.name}")
            if member.name != f"{name}/tms" and (
                tar.extractfile(member).read() != legal_files[member.name].read_bytes()
            ):
                raise ValueError(f"notice differs from source: {member.name}")
        executable = tar.extractfile(f"{name}/tms").read()
    if TARGETS[target][1] == "Linux":
        valid = (
            len(executable) >= 20
            and executable[:6] == b"\x7fELF\x02\x01"
            and struct.unpack_from("<H", executable, 16)[0] in (2, 3)
            and struct.unpack_from("<H", executable, 18)[0] == 62
        )
    else:
        cpu = 0x100000C if target == "aarch64-apple-darwin" else 0x1000007
        valid = (
            len(executable) >= 16
            and executable[:4] == b"\xcf\xfa\xed\xfe"
            and struct.unpack_from("<I", executable, 4)[0] == cpu
            and struct.unpack_from("<I", executable, 12)[0] == 2
        )
    if not valid:
        raise ValueError(f"tms is not an executable for {target}")
    if smoke:
        require_native(target)
        with tempfile.TemporaryDirectory(prefix="tms-smoke-") as temporary:
            binary = Path(temporary) / "tms"
            binary.write_bytes(executable)
            binary.chmod(0o755)
            result = subprocess.run(
                [str(binary), "--version"],
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.stdout != f"tmux-sessionizer {version()}\n" or result.stderr:
                raise ValueError(f"unexpected --version output: {result}")
    print(f"Verified archive contents and checksum: {archive}")
    if smoke:
        print(
            "Native --version passed. This is not behavioral compatibility verification."
        )


def build(target, output, smoke):
    if smoke:
        require_native(target)
    compiler = subprocess.check_output(["zig", "version"], text=True).strip()
    if compiler != "0.17.1":
        raise ValueError(f"expected Zig 0.17.1, found {compiler}")
    output.mkdir(parents=True, exist_ok=True)
    name = archive_name(target)
    archive = output / f"{name}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="tms-package-") as temporary:
        prefix = Path(temporary) / "install"
        subprocess.run(
            [
                "zig",
                "build",
                "--system",
                "--release=fast",
                "-Dcpu=baseline",
                f"-Dtarget={TARGETS[target][0]}",
                "--prefix",
                str(prefix),
            ],
            cwd=ROOT,
            check=True,
        )
        files = {Path("tms"): prefix / "bin/tms"}
        files.update(notices())
        with (
            archive.open("wb") as raw,
            gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed,
            tarfile.open(fileobj=compressed, mode="w") as tar,
        ):
            for relative, source in sorted(files.items()):
                data = source.read_bytes()
                member = tarfile.TarInfo(f"{name}/{relative.as_posix()}")
                member.size = len(data)
                member.mode = 0o755 if relative == Path("tms") else 0o644
                tar.addfile(member, io.BytesIO(data))
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    archive.with_name(archive.name + ".sha256").write_text(
        f"{digest}  {archive.name}\n"
    )
    verify(archive, target, smoke)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version")
    tag = commands.add_parser("validate-tag")
    tag.add_argument("tag")
    licenses = commands.add_parser("notices")
    licenses.add_argument("--dest", type=Path, required=True)
    package = commands.add_parser("build")
    package.add_argument("--target", choices=TARGETS, required=True)
    package.add_argument("--output", type=Path, default=ROOT / "target/distrib")
    package.add_argument("--smoke", action="store_true")
    check = commands.add_parser("verify")
    check.add_argument("archive", type=Path)
    check.add_argument("--target", choices=TARGETS, required=True)
    check.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    if args.command == "version":
        print(version())
    elif args.command == "validate-tag":
        if args.tag != f"v{version()}":
            raise ValueError(f"release tag must be v{version()}")
        print(args.tag)
    elif args.command == "notices":
        install_notices(args.dest)
    elif args.command == "build":
        build(args.target, args.output, args.smoke)
    elif args.command == "verify":
        verify(args.archive, args.target, args.smoke)


if __name__ == "__main__":
    main()
