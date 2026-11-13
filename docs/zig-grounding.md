# Rust reference architecture

This source-derived summary describes commit `a91ea21780acb58eced5b7f52da7f212f6ca33f0`. It is not runtime verification.

## Overview

`tms` parses a command, loads configuration, discovers repositories when needed, and controls tmux through subprocesses. The default command presents discovered sessions in an embedded picker. The Rust version already has no fzf dependency.

## Key concepts

- `Config` owns optional settings, search paths, bookmarks, marks, startup sessions, and picker settings.
- `Session` has a name and either a lazy repository provider or a bookmark path.
- The session container maps a visible key to a session. A visible key can be a full path.
- The tmux session name is a separate value. Opening a discovered session replaces periods with underscores.
- `Picker` takes original candidate strings and returns an original string or cancellation.

## Command flow

`src/main.rs` handles shell completion before argument parsing and configuration loading. `src/cli.rs` loads configuration before dispatch. Without a subcommand, `src/session.rs` discovers repositories, adds bookmarks, disambiguates names, and builds the visible-key map.

Opening a session resolves its working directory, checks whether its tmux name exists, creates it if absent, runs its creation script only on creation, and attaches or switches. It does not create worktree windows. `src/tmux.rs` always passes `-L` and the configured socket. It checks `TERM_PROGRAM=tmux` to choose switching rather than attachment.

`src/marks.rs` stores decimal index keys and literal path strings. Listing omits invalid paths. Automatic allocation finds the first missing valid index.

## Picker flow

`src/picker/mod.rs` injects candidate strings into Nucleo, merges configured keys over defaults, enters raw mode and the alternate screen, and runs matching and rendering until confirmation or cancellation.

The reference uses `nucleo-matcher` 0.3.1. Compatibility includes its query grammar, per-atom smart case, smart normalization, score, length tie-break, and original-index tie-break. An empty pattern preserves injection order.

The grammar includes fuzzy atoms, quoted substrings, prefixes, suffixes, exact matches, negation, and escaped spaces. It splits on unescaped ASCII spaces. A literal pipe is not an OR operator.

Nucleo reduces each grapheme to its first code point for matching. Editing instead uses Unicode scalar positions. These are separate representations. The original candidate bytes remain the selection result.

The picker defaults to bottom input. Navigation wraps. Horizontal preview switches to vertical preview when the terminal becomes narrow relative to its height. Active names render bold, including names matched after dot and hyphen normalization.

Previews run synchronously. Session and window previews use tmux capture-pane. Directory previews use `ls -1`. The application and cached dependency sources establish these facts. Differential and terminal tests must verify the replacement.

## Known reference defects

These need explicit disposition in the compatibility record.

- Clone ignores Git's exit status. Rename ignores the result of `mv`.
- `refresh NAME` discovers repositories from the current session's path.
- `switch` and `kill` sort timestamps lexically. Default picker ordering sorts them numerically.
- Unicode query cursor placement counts scalars rather than display cells.
- Vertical preview can render bottom input while navigation still uses the configured top position.
- Preview ANSI handling is incomplete. Very small dimensions can underflow.
- Matcher completion has no wakeup callback, so results can wait for another input event.
- There is no application-level SIGTERM or SIGHUP restoration handler.

## Build constraints

The reference has four release targets. They are macOS arm64, macOS x86_64, Linux x86_64 GNU, and Linux x86_64 musl. Nix also exposes Linux arm64.

Nix, Cargo-dist, crates.io publishing, and installation instructions depend on Cargo. They require replacement after compatibility passes.

The pinned replacement compiler is Zig 0.17.1. Its local standard library uses `std.process.Init`, explicit `std.Io`, and `std.process.run(allocator, io, options)`. Older Zig subprocess examples do not match this version.

Translated Nucleo files and generated tables need their upstream license notices. The cached matcher declares MPL-2.0.

## Configuration and discovery constraints

`src/configs.rs` loads only `TMS_CONFIG_FILE` when set. Otherwise it merges the home-based configuration and then the platform configuration. On macOS the latter is `~/Library/Application Support/tms/config.toml`. Tables merge recursively and later arrays replace earlier arrays.

Missing configuration files are optional. Invalid TOML is fatal. Unknown fields are ignored. The `config` crate accepts Boolean, string, and numeric coercions that a strict TOML-to-struct decoder would reject. Absent values and explicit empty lists must remain distinguishable.

`ConfigExport` omits `input_position` and deprecated `search_paths`. Saving uses the raw model, drops unknown fields and comments, and writes merged values to the selected destination.

Search roots expand environment variables and a leading tilde, then canonicalize. Invalid roots are discarded. New-format roots precede legacy roots. A missing root list differs from a list whose entries are all invalid. Bookmarks alone do not bypass this requirement.

`src/repos.rs` scans breadth-first. Depth zero checks the root itself. A detected repository stops descent. Descendant paths are not canonicalized. Symlinks are followed, and depth bounds cycles. Exclusions are case-sensitive literal substrings of the whole path.

Provider order matters. Git detection checks shallow markers. jj detection checks `.jj/repo`. Resolution is lazy and does not fall back to another provider after an open failure.

Independently discovered linked worktrees appear regardless of `list_worktrees`. Enabling that option adds generated entries only for repositories classified as bare. Git generated names use worktree administrative IDs, not branch names.

jj uses a special bare test. The current commit must be empty, and its first parent's change ID must be the root change ID. The reference has two workspace lists. Resolved consumers use active workspaces and omit the current workspace. Generated picker entries read the workspace-store protobuf, including stale records and potentially the current workspace. A plain `jj workspace list` substitution does not preserve the latter.

Submodule discovery runs separately from directory traversal. It includes initialized Git submodules, uses `parent>child` names, and does not apply search-depth or exclusion rules.

Source investigation found these constraints in `src/configs.rs`, `src/repos.rs`, and their cached Rust dependencies. The compatibility harness must establish the supported input cases before the replacement relies on them.
