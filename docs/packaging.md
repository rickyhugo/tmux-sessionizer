# Zig packaging reference

## Integration status

This is a prepared packaging switch. The foundation implements only `--version`.
No archive build or version check establishes command, ranking, or terminal compatibility.
The parent integrates this change only after those gates pass.

The workflows require the mise tasks and shared hk steps listed below.
They must fail on an unimplemented candidate. They must not skip compatibility
checks or replace them with build checks.

## Developer tools and package compiler

`mise.toml` pins the developer tools, including Zig 0.17.1 and hk 2.12.0.
`mise.lock` records the available upstream downloads.
Shared CI installs all tools with `mise install --locked` and runs `mise run ci`
on Linux x86-64 and Apple Silicon.
That task runs `hk validate --deny-warnings` and `hk check --all`.
Local hooks use the same hk configuration. CI does not need `hk install`.

The [hk 2.12.0 release](https://github.com/jdx/hk/releases/tag/v2.12.0)
has no Intel macOS binary. A regenerated lock cannot fix that missing asset.
The full developer tool install, hk formatting, hooks, and shared CI task are not
supported on Intel Macs with this pin. Native archive and Nix builds still run
on Intel Macs because they do not use hk.

Archive jobs install only `zig` and `python` with `mise install --locked zig python`.
The Nix job installs no mise-managed tools. The publish job installs only `gh`.
Each of these jobs sets `MISE_AUTO_INSTALL=false` for every step.
The [mise auto-install setting](https://mise.jdx.dev/configuration/settings.html#auto_install)
disables automatic installs in `mise run`, `mise exec`, and nested task commands.
The [pinned mise settings](https://github.com/jdx/mise/blob/v2026.10.17/settings.toml)
define the same behavior.
Selecting tools for `mise install` alone does not stop a later `mise run`
from installing the other configured tools.
The shared CI job retains the full install and every compatibility check.

The Nix package uses an independent Zig 0.17.1 derivation.
Its four download hashes come from the
[official Zig download index](https://ziglang.org/download/index.json).
The locked nixpkgs revision provides Zig through 0.16.0, not the required compiler.
Nix fetches the exact compiler before the sandboxed package build.
The build runs native Zig with `--system`, which disables package downloads.
The audited dependencies must be in the source tree.
The sandbox does not install or invoke mise.
Linux Nix packages target musl so the executable does not need a host libc loader.
Darwin packages use the SDK from the locked nixpkgs revision.

`nix develop` provides mise 2026.10.17 as the developer task runner.
The locked nixpkgs mise is 2026.5.12 and lacks the `packslip` backend required by
the hk entry in `mise.lock`.
The shell uses a separate derivation of the
[official mise release](https://github.com/jdx/mise/releases/tag/v2026.10.17).
Its four archive hashes match the release's
[SHASUMS256.txt](https://github.com/jdx/mise/releases/download/v2026.10.17/SHASUMS256.txt)
and GitHub asset digests.
Linux uses the static musl binaries, which have no host loader dependency.
Darwin binaries link only to Apple's system libraries and frameworks.
The derivation preserves the upstream binaries without fixup.
Its wrapper supplies Bash, coreutils, Git, and a default CA certificate bundle.
Native Nix checks verify the mise version and `packslip` backend on every system.
`nix develop` does not expose the package compiler as a second developer toolchain.
`.envrc` watches the flake and mise files and enters that shell.

## Version source

The release version comes from the single literal `.version` in `build.zig.zon`.
Neither archives nor Nix read `Cargo.toml`.
The release tag must equal `v` followed by that version.
`scripts/package.py validate-tag` rejects a mismatch.

The application must read the same version through a build-generated options
module. For example, `build.zig` can read
`@import("build.zig.zon").version` and export it as `build_options.version`.
This preparation does not add a `-Dversion` override or edit application code.
The foundation still has a literal version in `src/main.zig`.
The parent must remove that duplicate before releasing a new version.

## Release archives

The target names retain the previous release matrix.

| Archive target | Zig target | Native runner |
| --- | --- | --- |
| `aarch64-apple-darwin` | `aarch64-macos` | `macos-15` |
| `x86_64-apple-darwin` | `x86_64-macos` | `macos-15-intel` |
| `x86_64-unknown-linux-gnu` | `x86_64-linux-gnu.2.28` | `ubuntu-22.04` |
| `x86_64-unknown-linux-musl` | `x86_64-linux-musl` | `ubuntu-24.04` |

Builds use `--release=fast` and `-Dcpu=baseline`.
The GNU target selects a glibc 2.28 ABI baseline.
That selection is not evidence of a run on a glibc 2.28 system.
There is no Linux ARM64 release archive. Nix supports that system.

An archive has the name `tms-VERSION-TARGET.tar.gz`.
Its single directory has the same name without `.tar.gz`.
The directory contains the actual `tms` executable, `LICENSE`, and source notices.
The script copies root files whose names start with `LICENSE`, `LICENCE`,
`COPYING`, `COPYRIGHT`, `NOTICE`, or `THIRD_PARTY`.
It also copies those files from `vendor` and `src`, with their relative paths.
It copies every file under `vendor/licenses`, regardless of filename.
This includes all six files under `vendor/licenses/matcher` from matcher commit
`fa12588a1133594dfb2fb313ea2a21e00286ca3c`.
The selection also includes `vendor/tomlc17/LICENSE` and its `NOTICE` files.
It rejects symlinked notice files.
Every archive also includes the Zig license, musl copyright file, and glibc
notices from the pinned compiler distribution under `notices`.
The archive excludes `tms-oracle`, Rust tools, fzf, and runtime helpers.
A matching `.tar.gz.sha256` file contains the SHA-256 digest.

The parent must add the audited Nucleo translation notices and TOML parser license
before integration. A missing notice cannot be recovered by the archive script.
The same notice selection installs under `share/licenses/tms` in source and Nix installs.

`scripts/package.py verify` checks the checksum, exact member set, permissions,
notice bytes, and executable format.
`--smoke` also extracts the binary to a temporary directory and runs `--version`.
It rejects foreign-host smoke checks.
It never treats a version check as behavioral verification.

## Workflow gates

`ci.yml` runs `mise install --locked` and `mise run ci` on Linux and macOS.
The shared hk checks own formatting, Zig tests, the reference tests during
migration, command and ranking compatibility, and terminal compatibility.

`nix.yml` runs the real Nix build and checks on all four native systems.
The flake exports `packages.default`, `packages.tmux-sessionizer`, and
`overlays.default`. Its package checks run Zig tests and compare `--version`.
It also installs shell completions through the executable's `COMPLETE` protocol.
These Nix checks do not replace the shared hk compatibility checks.
The package metadata lists MIT, MPL-2.0, Apache-2.0, and Unicode-3.0 for the
application and bundled matcher notices. Unicode code offers MIT or Apache-2.0.
The matcher notices retain that choice.

`release.yml` calls both check workflows before it builds archives.
Pull requests and manual dispatches upload workflow artifacts only.
A `v*` tag in `rickyhugo/tmux-sessionizer` creates a draft release after every gate
and archive build passes. Publishing that draft remains a separate human action.
The Cargo publish workflow is removed.
`dist-workspace.toml` remains legacy reference data until the parent retires it.
No active workflow calls Cargo-dist or publishes a crate.

## Required parent integration

The parent owns `mise.toml`, `mise.lock`, `hk.pkl`, and `build.zig`.
These tasks are required:

```toml
[tasks.package]
description = "Build and inspect a Zig release archive"
run = "python3 scripts/package.py build"

[tasks."package:verify"]
description = "Inspect a Zig release archive"
run = "python3 scripts/package.py verify"

[tasks."package:version"]
description = "Print the Zig package version"
run = "python3 scripts/package.py version"

[tasks."package:tag"]
description = "Check a release tag against build.zig.zon"
run = "python3 scripts/package.py validate-tag"

[tasks.install]
description = "Install the native Zig executable and notices"
depends = ["build:release"]
run = "sh scripts/install.sh"

[tasks."nix:check"]
description = "Check the native Nix package and exported package names"
run = """
system=$(nix eval --impure --raw --expr builtins.currentSystem)
test "$system" = "${NIX_SYSTEM:-$system}"
nix flake check -L --no-update-lock-file
nix build -L --no-link --no-update-lock-file .#default .#tmux-sessionizer
"""

[tasks."release:draft"]
description = "Create a draft release from checked archives"
run = 'gh release create "$RELEASE_TAG" --verify-tag --draft --generate-notes artifacts/*'
```

Mise forwards extra task arguments to each script.
The `test:compat` and `test:terminal:strict` tasks must become unconditional
shared hk steps after their build dependencies.
`test:compat` must pass the Zig executable and Zig oracle to the runner.
It must enable real jj cases.
`test:terminal:strict` builds the release executable and runs
`scripts/terminal_checks.py --binary zig-out/bin/tms --require-improvements --output .audit/terminal`.
The terminal runner must enforce the private candidate tmux launcher.
The strict terminal step follows command and ranking compatibility.
Both checks must use the release build, without concurrent writes to `zig-out`.
The unchanged Rust suite stays in the migration checks until the parent retires it.

Regenerate `mise.lock` for the available tool downloads on `linux-x64`,
`linux-arm64`, `macos-x64`, and `macos-arm64` before CI runs.
hk 2.12.0 has no `macos-x64` entry because upstream has no binary for that platform.
Add `gh = "2.103.3"` to the mise tools for `release:draft`.
Pin any additional formatter or workflow linter in mise before adding its task.
The Nix job's matrix identifies the expected system in `NIX_SYSTEM`.
The task rejects a runner whose native system does not match that value.

No new build option is required for archive creation.
The default Zig build can also install the oracle because the script packages
only `bin/tms`. The parent must enable the audited vendored TOML parser by default
and include `vendor` in the `build.zig.zon` source package paths.
That preserves the full `vendor/licenses` tree and the tomlc17 license and notices.
The flake's source filter already retains the entire vendor tree.
The matcher translation's source-file notices must remain in `src`.

## Lockfile edit

The lockfile edit removes only `crane`, `rust-overlay`, and their root edges.
Neither removed node has an input that another node needs.
The remaining graph is `root` to `nixpkgs` and `flake-parts`, then `flake-parts`
to `nixpkgs-lib`. All remaining revisions and hashes are unchanged.
No compiler or flake hash was invented.

## Verification limits

Local checks on 2026-11-13 used foundation commit
`9e81abc07e5b7a77b1817f9cd42756546f724c06` and temporary archives.

| Target | Build and archive checks | Native `--version` |
| --- | --- | --- |
| `aarch64-apple-darwin` | Passed | Passed |
| `x86_64-apple-darwin` | Passed | Unexecuted |
| `x86_64-unknown-linux-gnu` | Passed | Unexecuted |
| `x86_64-unknown-linux-musl` | Passed | Unexecuted |

The checks used `mise exec -- python3 scripts/package.py build` with each target.
Only the native Apple Silicon invocation added `--smoke`.
The source installer also passed with a temporary prefix that contained spaces.
Its executable reported the expected version, and its license copies matched.

Twelve negative packaging checks rejected altered checksums, extra or missing
members, duplicate members, wrong permissions, symlinks, changed notices, wrong
CPU and file types, foreign smoke checks, and duplicate version declarations.
Notice collection and copying also passed with all six matcher notices from
`fa12588a1133594dfb2fb313ea2a21e00286ca3c` and temporary tomlc17 license and notice fixtures.
The lockfile graph retained every remaining revision and hash.
All four compiler hashes matched the official Zig index.

Static checks passed with actionlint 1.7.12, ShellCheck 0.11.0, and Ruff 0.17.0
through mise. The unchanged hk configuration passed validation.
Its plan still lacks the required compatibility steps, so it is not a migration gate.
These results do not establish usable `tms` behavior.
Nix is unavailable locally, so Nix evaluation, sandbox builds, completion
installation, and all four native Nix checks remain unexecuted.
The committed Nix workflow performs those checks after the parent pushes.

The focused portability fix used mise 2026.10.17 with isolated config, data,
cache, state, and home directories. Its fixture configured Zig, Python, and a
missing HTTP tool at `http://127.0.0.1:1/missing`.
`MISE_AUTO_INSTALL=false mise install --locked zig python` installed only Zig
and Python. `mise run` then executed both tools and a nested task without
installing the missing tool. Without `MISE_AUTO_INSTALL=false`, the same task
failed on the missing tool before its commands ran.
A separate task passed with an empty install directory and automatic installs off.
This verifies the tool isolation mechanism, not a Nix build.

All four mise archives were downloaded and hashed against the release checksums
and GitHub asset digests. `file` identified both Linux binaries as static.
`otool -L` showed only Apple system dependencies for both Darwin binaries.
The downloaded Apple Silicon binary reported 2026.10.17 and listed `packslip`.
Tree-sitter-nix 0.1.0 parsed the flake without syntax errors.
Actionlint 1.7.12 passed the workflows. ShellCheck 0.11.0 passed the installer
and extracted mise derivation phases, with Nix-provided variables excluded from
the extracted phase check.
Nix evaluation and native builds remain unexecuted locally.

## Tool documentation

The workflow follows the current
[mise CI guide](https://mise.jdx.dev/continuous-integration.html),
[mise-action inputs](https://github.com/jdx/mise-action/blob/v5/action.yml),
[hk CI guide](https://hk.jdx.dev/ci.html), and
[`hk check` reference](https://hk.jdx.dev/cli/check.html).
The matrix uses the published
[GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
