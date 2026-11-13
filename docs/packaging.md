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
`mise.lock` records downloads for each runner platform.
CI installs them with `mise install --locked` and runs `mise run ci`.
That task runs `hk validate --deny-warnings` and `hk check --all`.
Local hooks use the same hk configuration. CI does not need `hk install`.

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

`nix develop` provides mise as the developer task runner.
It does not expose the package compiler as a second developer toolchain.
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

Regenerate `mise.lock` for `linux-x64`, `linux-arm64`, `macos-x64`, and `macos-arm64`
before CI runs. The foundation lock lacks some Intel macOS tool entries.
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

## Tool documentation

The workflow follows the current
[mise CI guide](https://mise.jdx.dev/continuous-integration.html),
[mise-action inputs](https://github.com/jdx/mise-action/blob/v5/action.yml),
[hk CI guide](https://hk.jdx.dev/ci.html), and
[`hk check` reference](https://hk.jdx.dev/cli/check.html).
The matrix uses the published
[GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
