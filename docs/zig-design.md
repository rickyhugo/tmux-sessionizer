# Zig implementation design

## Goal

Replace Rust with Zig while preserving `tms` commands, configuration, session behavior, and its embedded picker. Keep tmux, Git, and optional jj as runtime programs. Use mise and hk for development and CI.

## Decision

Use domain-owned modules from candidate A. Adopt candidate B's picker-local reducer and stable candidate identities. Do not use a command-wide effect interpreter.

Both candidates ran independently on GPT-6.1 Sol with high reasoning. No cross-family judge was configured.

The comparison used five criteria.

| Criterion | Candidate A | Candidate B |
| --- | --- | --- |
| Compatibility ownership | Keeps naming, config, VCS, and terminal rules in their owners | Preserves rules but adds continuations around command operations |
| Interface size | Direct domain operations with explicit IO | Command, event, effect, continuation, and executor interfaces |
| Resource ownership | Command arena and picker-local reusable storage | Same lifetime split plus durable event payloads |
| Independent verification | Black-box command tests and pure matching tests | Adds pure command-policy tests |
| Parallel implementation | Separate domain modules | Separate modules plus shared event and effect contracts |

Candidate A keeps command traces shorter. Candidate B's additional command-policy testability does not justify its interpreter for this synchronous CLI. Its picker reducer does justify a local state model because editing, selection, resize, and cancellation share state.

## Data shape

- Configuration retains absent values separately from explicit empty values.
- A repository reference contains its encountered path and selected provider.
- A session entry contains a visible key, session name, and repository or bookmark source.
- The catalog owns entries and maps visible keys to stable entry indices.
- A picker item contains a stable ID, original label, active flag, and typed preview request.
- Matching returns ranked candidate indices. It never reconstructs a candidate from displayed text.
- Picker state owns the query, scalar cursor position, ranked indices, selection, scroll position, and terminal dimensions.

## Module ownership

| Module | Responsibility |
| --- | --- |
| CLI and application | Parse commands and execute command-specific policies |
| Configuration | TOML parsing, coercion, precedence, defaults, mutations, persistence, bookmarks, marks, and key configuration |
| Repositories | Shallow detection, breadth-first discovery, lazy resolution, Git and jj subprocesses, worktrees, and submodules |
| Sessions | Catalog construction, duplicate names, visible keys, and opening policy |
| tmux and process adapter | Socket-specific argv, output capture, inherited streams, replacement, and child lifetime |
| Matcher | Nucleo query grammar, scoring, normalization, Unicode representation, and ranking |
| Picker and terminal | State reduction, input decoding, previews, layout, rendering, terminal attributes, and signal cleanup |

The build owns allowed imports. Modules expose domain records rather than process output or private parser trees. A shared types file is justified only for genuinely shared data that would otherwise cause cyclic imports.

## Lifetimes

Use Zig 0.17.1 and explicit `std.Io`. A command arena owns arguments, configuration, catalog entries, and durable subprocess results. Picker buffers and matcher workspace reuse storage. They must not retain an allocation for every keystroke.

Public domain effect APIs retain `std.Io`. Synchronous native backend helpers
are a narrow exception: terminal fd/signal management, libc account lookup, and
filesystem metadata preservation use native APIs. They do not accept ignored
`Io` parameters or claim `Io` cancellation. Their domain owners retain cleanup;
the terminal owner also retains interruption and signal restoration.
See [interfaces](zig-interfaces.md#lifetimes-and-errors) for the exact scope and
cancellation limits.

One terminal owner restores saved attributes and screen state before returning or replacing the process. One process adapter owns child launch and wait or kill behavior. Nonzero exit handling remains command-specific.

## Dependencies

Use a pinned TOML parser compiled into the executable. Both candidates proposed tomlc99, but its upstream README now marks it obsolete. Use the native tomlc17 API at commit `aa4ca1bc5fe6382ac631a8d1428077a9a084a64d`, with its MIT license.

Configuration coercion, merge, and serialization remain Zig-owned. Do not use tomlc17's merge operation because it appends arrays of tables. The Rust reference replaces arrays.

Sources are the pinned [tomlc99 notice](https://github.com/cktan/tomlc99/blob/62ce93ceb713dc49909d0fef1411f9d37bef83f2/README.md) and [tomlc17 header](https://github.com/cktan/tomlc17/blob/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/src/tomlc17.h). Parser compatibility remains a test gate.

Port the locked Nucleo matcher semantics to Zig. Preserve upstream notices for translated files and tables. Record dependency versions and licenses. Use native directory enumeration and file movement instead of adding `ls` and `mv` runtime requirements. Verify their observable behavior, including overwrite and cross-device moves.

Use Git and jj subprocesses for repository operations. Preserve the reference's separate jj registered-workspace and active-workspace contracts. The former needs a small workspace-store decoder because active-workspace CLI output omits stale records.

## Deliberate terminal improvements

Restore terminal state on supported termination signals. Handle tiny sizes without arithmetic underflow. Position the query cursor by display cells while retaining scalar-based editing. Ensure completed matching can render without an extra keypress. These address Unicode, cleanup, resize, and responsiveness requirements in the requested plan.

Keep remaining behavior differences visible in the compatibility report. Do not silently replace lexical timestamps, configuration coercions, name normalization, or query grammar with simpler rules.

## Implementation sequence

1. Add the Zig build and compile-checked module contracts alongside Rust.
2. Finish and run the Rust compatibility harness before porting behavior.
3. Implement separate configuration, repository, matcher, picker, and command workstreams in isolated worktrees.
4. Integrate each verified unit serially.
5. Run differential, PTY, tmux-popup, packaging, and benchmark checks.
6. Remove Rust only after the compatibility gates pass.
