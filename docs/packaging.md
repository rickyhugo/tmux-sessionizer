# Zig packaging

## Build and checks

`mise.toml` pins Zig 0.17.1, Python 3.14.7, hk 2.12.0, jj 0.38.0,
tmux 3.8, and gh 2.103.3. `mise.lock` records upstream download checksums.
Use mise 2026.10.17 or newer.

```sh
mise install --locked
mise run ci
```

CI and local hooks use the same hk checks: formatting, Zig tests, harness
isolation, command adapters, 42 command cases, 25 ranking vectors, 21 terminal
and popup scenarios, and nine focused picker regressions.
Command and terminal compatibility use the release executable.
Rust source and tooling were retired after these checks passed.
Reference fixtures and recorded evidence remain unchanged.

hk 2.12.0 has no upstream Intel macOS binary. Full developer checks therefore
run on Apple Silicon and Linux x86-64. Source installs, archives, and Nix builds
on Intel Macs do not require hk.

## Version and release archives

`build.zig.zon` is the version source. `build.zig` exports it through
`build_options`; packaging and Nix read the same value.
`mise run package:tag -- vVERSION` rejects a tag that does not match.

| Archive target | Zig target | Native CI runner |
| --- | --- | --- |
| `aarch64-apple-darwin` | `aarch64-macos` | `macos-15` |
| `x86_64-apple-darwin` | `x86_64-macos` | `macos-15-intel` |
| `x86_64-unknown-linux-gnu` | `x86_64-linux-gnu.2.28` | `ubuntu-22.04` |
| `x86_64-unknown-linux-musl` | `x86_64-linux-musl` | `ubuntu-24.04` |

There is no Linux ARM64 release archive; Nix supports that system.
GNU builds select the glibc 2.28 ABI baseline. This does not prove execution
on a glibc 2.28 host.

```sh
mise run package -- --target aarch64-apple-darwin --smoke
mise run package:verify -- \
  target/distrib/tms-0.6.1-aarch64-apple-darwin.tar.gz \
  --target aarch64-apple-darwin --smoke
```

Builds use ReleaseFast, baseline CPU features, vendored dependencies, and
`--system` to disable Zig package downloads. An archive contains `tms`,
application and vendored licenses, source notices, and Zig/libc notices.
It excludes the ranking oracle and runtime helpers.
The companion `.sha256` file identifies the archive.

Verification checks checksums, the exact member set, permissions, executable
format and CPU, and notice bytes. `--smoke` also runs `--version` on a matching
native host. Version checks do not replace behavioral tests.

## Source installation

```sh
mise install --locked zig python
MISE_AUTO_INSTALL=false mise run install -- "$HOME/.local"
```

The installer writes `bin/tms` and `share/licenses/tms` under the prefix.
tmux and Git are runtime dependencies; jj is optional. No fzf, `ls`, or `mv`
runtime helper is required.

## Nix

The flake exports `packages.default`, `packages.tmux-sessionizer`,
`overlays.default`, and a development shell on all four systems:
`aarch64-linux`, `x86_64-linux`, `aarch64-darwin`, and `x86_64-darwin`.

```sh
mise run nix:check
nix develop
```

The package uses a separately hash-pinned official Zig 0.17.1 distribution.
Locked nixpkgs provides an older compiler. Dependencies are fetched before
the sandboxed build; the build invokes native Zig, not mise.
Linux packages and test executables link musl statically.
Darwin uses the SDK from locked nixpkgs.

The check phase runs Zig tests and verifies the application version.
Installation generates bash, fish, and zsh completions through `COMPLETE`,
then installs all notices.

Nix's Linux syscall filter deliberately returns `ENOTSUP` for xattr calls.
The package explicitly permits skipping metadata fixtures only when their
xattr setup returns that error. Copying and preservation failures still fail.
Normal tests require xattrs. `scripts/linux-check.sh` explicitly disables the
exception and verifies metadata across real filesystems.
The sandbox and its syscall filter remain enabled for normal Nix builds.

`nix develop` provides mise 2026.10.17, including its `packslip` backend.
The upstream archives are hash-pinned because locked nixpkgs has mise 2026.5.12,
which lacks that backend. The wrapper supplies Bash, coreutils, Git, and a
default CA bundle. It does not expose a second developer Zig toolchain.
`.envrc` watches the flake and mise files.

The lockfile change removed only `crane`, `rust-overlay`, and their root edges.
Other dependency revisions and hashes were preserved.

## Workflows

- `ci.yml`: full pinned tools and shared hk checks on Linux and Apple Silicon.
- `nix.yml`: native package and shell checks on all four systems.
- `release.yml`: both check workflows must pass before archive jobs run.

Archive jobs install only Zig and Python; the Nix job needs no mise-managed
tools; publication installs only gh. These jobs set `MISE_AUTO_INSTALL=false`
so nested tasks cannot install unrelated tools.

Pull requests and manual dispatches upload artifacts only. A matching `v*` tag
in `rickyhugo/tmux-sessionizer` creates a draft release after all gates pass.
Publishing the draft remains a separate action. Cargo publishing and
Cargo-dist configuration have been removed.

## Verification on 2026-11-13

The integrated application at `3ad4fda` passed archive creation and inspection
for all four targets. Apple Silicon also passed native extraction and version
execution. The source installer passed with a prefix containing spaces and
byte-for-byte notice comparison.

The packaging implementation's earlier negative checks rejected altered
checksums, extra or missing members, duplicates, wrong permissions, symlinks,
changed notices, wrong CPU/file types, foreign smoke checks, and duplicate
version declarations.

Native aarch64 Linux passed full application verification, including xattrs
and ACLs, plus a real Nix sandbox package build with fallback disabled.
See [Linux verification](linux-verification.md) and
[Nix verification](nix-verification.md).

Hosted workflows and native Intel macOS/x86-64 Linux archive execution remain
unexecuted locally. Cross-build success is not native runtime evidence.
Nothing has been pushed, tagged, or released by this migration.
