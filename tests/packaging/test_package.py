"""Packaging policy tests. Compilation is stubbed; archive/install paths are real."""

import copy
import hashlib
import importlib.util
import io
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package", ROOT / "scripts/package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

# Independent policy oracle: never derive this list from package.notices().
SOURCE_NOTICES = (
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
COMPILER_NOTICES = {
    "notices/zig/LICENSE": "LICENSE",
    "notices/musl/COPYRIGHT": "lib/libc/musl/COPYRIGHT",
    "notices/glibc/LICENSES": "lib/libc/glibc/LICENSES",
}


class PackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tms-packaging-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "source"
        self.root.mkdir()
        self.expected = {}
        for relative in SOURCE_NOTICES:
            source = ROOT / relative
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            self.expected[relative] = source.read_bytes()
        compiler = Path(shutil.which("zig")).resolve().parent
        for relative, source in COMPILER_NOTICES.items():
            self.expected[relative] = (compiler / source).read_bytes()
        for relative in ("scripts/package.py", "scripts/install.sh", "build.zig.zon"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        root_patch = patch.object(package, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.target = "aarch64-apple-darwin"
        self.name = package.archive_name(self.target)
        self.archive = self.root / "dist" / f"{self.name}.tar.gz"
        self.run = subprocess.run

    def compile_stub(self, command, **kwargs):
        if command == ["zig", "version"]:
            return self.run(command, **kwargs)
        self.assertEqual(command[:3], ["zig", "build", "--system"])
        prefix = Path(command[command.index("--prefix") + 1])
        binary = prefix / "bin/tms"
        binary.parent.mkdir(parents=True)
        # Only a format fixture, not evidence of native execution.
        binary.write_bytes(struct.pack("<IIII", 0xFEEDFACF, 0x100000C, 0, 2))

    def build_archive(self):
        with patch.object(package.subprocess, "run", side_effect=self.compile_stub):
            package.build(self.target, self.archive.parent, smoke=False)
        return self.read_archive()

    def read_archive(self):
        with tarfile.open(self.archive) as archive:
            return [
                (copy.copy(member), archive.extractfile(member).read())
                for member in archive.getmembers()
            ]

    def rewrite_archive(self, entries):
        with tarfile.open(self.archive, "w:gz") as archive:
            for member, data in entries:
                member = copy.copy(member)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.archive.with_name(self.archive.name + ".sha256").write_text(
            f"{digest}  {self.archive.name}\n"
        )

    def test_archive_contains_every_required_notice_byte_for_byte(self):
        entries = self.build_archive()
        actual = {member.name: data for member, data in entries}
        expected = {f"{self.name}/{name}" for name in self.expected}
        self.assertEqual(set(actual), expected | {f"{self.name}/tms"})
        for name, data in self.expected.items():
            self.assertEqual(actual[f"{self.name}/{name}"], data, name)

    def test_source_installer_contains_every_required_notice_byte_for_byte(self):
        binary = self.root / "zig-out/bin/tms"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        prefix = self.root / "prefix with spaces"
        subprocess.run(
            ["sh", "scripts/install.sh", str(prefix)],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual((prefix / "bin/tms").read_bytes(), binary.read_bytes())
        destination = prefix / "share/licenses/tms"
        actual = {
            path.relative_to(destination).as_posix(): path.read_bytes()
            for path in destination.rglob("*")
            if path.is_file()
        }
        self.assertEqual(set(actual), set(self.expected))
        for name, data in self.expected.items():
            self.assertEqual(actual[name], data, name)

    def test_verifier_rejects_archive_without_config_unicode_notice(self):
        entries = self.build_archive()
        entries = [
            entry
            for entry in entries
            if entry[0].name != f"{self.name}/src/config/UNICODE-LICENSE"
        ]
        self.rewrite_archive(entries)
        with self.assertRaisesRegex(ValueError, "only tms"):
            package.verify(self.archive, self.target)

    def test_required_notice_must_exist(self):
        (self.root / "src/config/UNICODE-LICENSE").unlink()
        with self.assertRaisesRegex(ValueError, "required license or notice"):
            package.notices()

    def test_required_notice_must_not_be_symlink(self):
        notice = self.root / "src/config/UNICODE-LICENSE"
        notice.unlink()
        notice.symlink_to(self.root / "LICENSE")
        with self.assertRaisesRegex(ValueError, "symlink"):
            package.notices()

    def test_verifier_rejects_changed_checksum(self):
        self.build_archive()
        self.archive.with_name(self.archive.name + ".sha256").write_text("invalid\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            package.verify(self.archive, self.target)

    def test_verifier_rejects_invalid_members_after_checksum_is_updated(self):
        original = self.build_archive()
        notice_index = next(
            i
            for i, (member, _) in enumerate(original)
            if member.name.endswith("/src/config/UNICODE-LICENSE")
        )
        binary_index = next(
            i
            for i, (member, _) in enumerate(original)
            if member.name == f"{self.name}/tms"
        )
        for defect in (
            "bytes",
            "missing",
            "duplicate",
            "extra",
            "mode",
            "symlink",
            "cpu",
        ):
            with self.subTest(defect=defect):
                entries = [(copy.copy(member), data) for member, data in original]
                member, data = entries[notice_index]
                if defect == "bytes":
                    entries[notice_index] = (member, b"changed notice\n")
                elif defect == "missing":
                    entries.pop(notice_index)
                elif defect == "duplicate":
                    entries.append((copy.copy(member), data))
                elif defect == "extra":
                    extra = tarfile.TarInfo(f"{self.name}/unexpected")
                    entries.append((extra, b"extra"))
                elif defect == "mode":
                    member.mode = 0o755
                elif defect == "symlink":
                    member.type = tarfile.SYMTYPE
                    member.linkname = "LICENSE"
                else:
                    binary, data = entries[binary_index]
                    entries[binary_index] = (
                        binary,
                        struct.pack("<IIII", 0xFEEDFACF, 0x1000007, 0, 2),
                    )
                self.rewrite_archive(entries)
                with self.assertRaises(ValueError):
                    package.verify(self.archive, self.target)

    def test_version_and_tag_commands(self):
        version = package.version()
        for command, code in (
            (["version"], 0),
            (["validate-tag", f"v{version}"], 0),
            (["validate-tag", "v999.0.0"], 1),
            (["validate-tag", version], 1),
        ):
            with self.subTest(command=command):
                result = subprocess.run(
                    [sys.executable, "scripts/package.py", *command],
                    cwd=self.root,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, code, result.stderr)
                if code == 0:
                    self.assertEqual(
                        result.stdout.strip(),
                        command[-1] if len(command) > 1 else version,
                    )

    def test_duplicate_version_is_rejected(self):
        source = self.root / "build.zig.zon"
        source.write_text(source.read_text() + '\n.version = "9.9.9",\n')
        with self.assertRaisesRegex(ValueError, "one literal semantic version"):
            package.version()

    def test_foreign_smoke_is_rejected_before_build(self):
        with (
            patch.object(package.platform, "system", return_value="Linux"),
            patch.object(package.subprocess, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "requires a native"):
                package.build(self.target, self.archive.parent, smoke=True)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
