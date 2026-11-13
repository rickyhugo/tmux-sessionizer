# Develop with mise

## Set up the tools

Install [mise](https://mise.jdx.dev/getting-started.html).
Install Git with your system package manager.
mise supplies tmux, jj, and the development tools.
Outside mise, the runtime needs Git, tmux, and jj on `PATH`.

From the repository root, run:

```sh
mise trust
mise install
```

Use `mise run` for project tasks.
Use `mise exec --` before other development commands.
No shell activation is required.

mise pins Zig 0.17.1, hk 2.12.0, jj 0.38.0, tmux 3.8, Python 3.14.7, and Rust 1.99.0.
The mise environment overrides `rust-toolchain.toml` for Rust reference work.
The existing Rust and release configuration remains unchanged.
`mise.lock` records download metadata for Linux and macOS.
hk 2.12.0 supplies no Intel macOS binary.
Use an Apple Silicon Mac or a Linux host for this development setup.

## Build and test

Run the Rust reference tasks:

```sh
mise run build:rust
mise run test:rust
```

The debug executable is `target/debug/tms`.

Once the Zig implementation supplies `build.zig`, run:

```sh
mise run build
mise run test
mise run build:release
```

The release executable is `zig-out/bin/tms`.
These tasks call `zig build`, `zig build test`, and
`zig build -Doptimize=ReleaseFast`.
They fail if the build definition is missing.

## Check a change

```sh
mise run fmt
mise run fmt:check
mise run check
mise run ci
```

`hk.pkl` defines the checks shared by pre-commit and CI.
The full check runs Rust tests and formatting checks.
Zig formatting applies to selected Zig files.
Zig tests and the release build run when `build.zig` exists.
Compatibility checks are not wired yet.
Do not treat a passing check as proof of Rust and Zig compatibility.

To install hooks in a standalone clone, run:

```sh
mise run hooks:setup
```

The setup task refuses linked worktrees to protect the shared Git directory.
It installs no global hooks.
The launcher uses mise without requiring shell activation.
hk applies available formatting fixes before a commit.

## Run checks in CI

Install mise and the system prerequisites on the runner.
Then run:

```sh
mise install
mise run ci
```

The existing workflows still build and publish Rust.
Before switching releases, add the compatibility scripts to hk with `TMS_BIN`
pointing to each executable.
Run the same checks on Linux and macOS.

For configuration details, see [mise tasks](https://mise.jdx.dev/tasks/toml-tasks.html),
[hk configuration](https://hk.jdx.dev/configuration.html), and
[hk mise integration](https://hk.jdx.dev/mise_integration.html).
