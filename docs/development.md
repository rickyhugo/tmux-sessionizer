# Develop with mise

## Set up the tools

Install [mise](https://mise.jdx.dev/getting-started.html) 2026.10.17 or newer.
Install Git with your system package manager. From the repository root, run:

```sh
mise trust
mise install --locked
```

mise pins Zig 0.17.1, hk 2.12.0, jj 0.38.0, tmux 3.8, Python 3.14.7,
and gh 2.103.3. `mise.lock` records platform download checksums.
Rust is not part of the current toolchain.

Use `mise run` for project tasks and `mise exec --` for other development
commands. No shell activation is required. Set `MISE_AUTO_INSTALL=false` after
installation to prevent commands from installing missing tools.

hk 2.12.0 has no Intel macOS binary. Run the full shared checks on Apple Silicon
or Linux. Intel Mac source installs and native Nix/archive builds do not need hk.
For source installation only, install `mise install --locked zig python`, then
run `MISE_AUTO_INSTALL=false mise run install`.

Outside mise, the runtime needs Git and tmux on `PATH`. jj is optional unless a
configured repository provider uses it. No fzf, `ls`, `mv`, or Rust runtime is
required.

## Build and test

```sh
MISE_AUTO_INSTALL=false mise run build
MISE_AUTO_INSTALL=false mise run test
MISE_AUTO_INSTALL=false mise run build:release
```

These tasks run `zig build`, `zig build test`, and
`zig build -Doptimize=ReleaseFast`. The application is `zig-out/bin/tms`.
The build also installs `zig-out/bin/tms-oracle` for ranking checks.

Focused checks:

```sh
MISE_AUTO_INSTALL=false mise run test:harness
MISE_AUTO_INSTALL=false mise run test:adapters
MISE_AUTO_INSTALL=false mise run test:compat
MISE_AUTO_INSTALL=false mise run test:terminal:strict
MISE_AUTO_INSTALL=false mise run test:picker:regressions
MISE_AUTO_INSTALL=false mise exec -- python3 -m unittest discover -s tests/packaging -p 'test_*.py'
```

Command compatibility checks all 42 stored command cases and 25 Rust ranking
vectors. Strict terminal checks run 21 real PTY/popup scenarios. The picker
regression task runs nine focused scenarios. Compatibility tasks build the
release executable before checking it.

Packaging policy tests use an independent notice list. They check real archive
writing, verification, source installation, and negative cases. Compilation is
stubbed in those tests; they do not prove native executable behavior.

## Check a change

```sh
MISE_AUTO_INSTALL=false mise run fmt
MISE_AUTO_INSTALL=false mise run fmt:check
MISE_AUTO_INSTALL=false mise run check
MISE_AUTO_INSTALL=false mise run ci
```

`hk.pkl` defines checks shared by local hooks and CI: Zig formatting, module
tests, a release build, harness isolation, command adapters, command/ranking
compatibility, strict terminal compatibility, and picker regressions.
`check` runs `hk check --all`. `ci` first validates hk with warnings denied,
then runs the same check. Neither task runs Rust.

To install hooks, run `mise run hooks:setup` from a standalone clone.
The task refuses linked worktrees to protect the shared Git directory.
It installs no global hooks. The launcher uses mise without shell activation.
hk applies available formatting fixes before a commit.

## Workflows and packaging

`.github/workflows/ci.yml` installs locked tools and calls `mise run ci` on
Linux x86-64 and Apple Silicon. `nix.yml` checks native packages and development
shells on all four supported Nix systems. `release.yml` requires both workflows
before building and inspecting the four release archives.

Pull requests and manual release dispatches upload artifacts only. A matching
`v*` tag in `rickyhugo/tmux-sessionizer` creates a draft release after the gates
pass. Publishing that draft is a separate action. Cargo publishing is removed.

`nix develop` supplies pinned mise, not a second developer Zig toolchain.
The Nix package uses its own hash-pinned Zig compiler.
See [packaging](packaging.md) for source installation, release commands, Nix
details, and platform verification limits.

## Reproduce the Rust reference

The behavioral reference is `a91ea21780acb58eced5b7f52da7f212f6ca33f0`.
The last pre-retirement revision below retains that Rust implementation,
its oracle, pinned Rust 1.99.0, and the compatibility harness:

```sh
git worktree add --detach ../tms-rust-reference 3ad4fdaada461f84d150ed516a3234dd1861ffbb
cd ../tms-rust-reference
mise trust
mise install --locked
TMS_BIN="$PWD/target/debug/tms" MISE_AUTO_INSTALL=false mise run test:compat:rust
TMS_BIN="$PWD/target/debug/tms" MISE_AUTO_INSTALL=false mise run test:terminal:rust
```

These tasks build the Rust application and ranking oracle before replay.
Keep reference work outside the current Zig checkout. Do not capture new
goldens from the Zig candidate. See [compatibility](compatibility.md) for the
fixture protocol, isolation rules, and recorded reference defects.
