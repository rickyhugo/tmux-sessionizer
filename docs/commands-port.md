# Command, catalog, and tmux port

## Implementation

`src/app.zig` dispatches completion before parsing and loads configuration after help and version handling.
Commands call their domain operations directly.
The command allocator owns durable results.
The picker receives the separate reclaimable allocator.

`src/sessions.zig` builds a visible-key-sorted catalog.
The key map contains stable indices into that array.
Session keys, logical names, and sources remain separate.
Duplicate basename groups share the Rust ancestor-depth algorithm.
Each duplicate group enters the catalog in reverse discovery order.
If its entries still share a key, the first discovered source wins.
This keeps a repository source when its path also appears in bookmarks.
Full-path display changes the key, not the logical name.
Repository working directories are canonicalized when opening non-bare repositories.

Catalog construction adds generated worktree entries only for bare repositories.
Worktree names come from the repository adapter.
Submodule names use the parent's visible key and the child's basename.
Opening a session does not add worktree windows.
Only `refresh` does that.

`src/tmux.zig` prefixes every request with `tmux -L SOCKET`.
Snapshots retain timestamp text and separate window-active and window-attached fields.
Session and window names retain commas.
The parsers read trailing status fields from the right without changing tmux query arguments.
Default picker ordering parses timestamps numerically.
Switch and kill compare timestamp text lexically.
Active highlighting normalizes periods and hyphens.
Opening replaces periods only.

Inside tmux, a failed captured switch tries a captured attach.
If both fail, `switchTo` replaces the process with attach.
Outside tmux, `switchTo` replaces the process directly.
`TERM_PROGRAM=tmux` determines this choice.

## Preserved policies

- Creation scripts run only after initial session creation.
- Script overrides use the normalized tmux session name.
- Startup windows inherit the reference's implicit current-session targeting.
- Startup removes `:1` when a windows collection is present, including an empty collection.
- Kill prefers an available configured default, then the first eligible session.
- Session listing retains the current-session asterisk and trailing spaces.
- Rename replaces every occurrence of the old session name in pane paths.
- Rename ignores native move failure and still sends `cd`, renames, and attaches.
- Refresh discovers from the current session's path even when a different target name is supplied.
- Clone preserves the repository adapter's ignored nonzero Git status.
- Clone switching defaults to Always.
- Foreground clone switching compares attached-session query output before and after cloning.
- Clone and init resolve a single name collision with the target parent's basename.
- Bookmarks and marks persist through typed configuration edits.
- Explicit mark lookup uses the raw map, not the filtered valid-mark list.

## Verification

The following command runs fake-process checks and a real tmux lifecycle test.

```sh
mise exec -- python3 src/app/check.py --real-tmux
```

The runner generates a unique `TMS_TMUX_SOCKET` beginning with `tms-port-test-`.
The real test rejects any other socket name.
Its server uses a private configuration and sleeping panes.
Cleanup kills only that server.

Fake-process checks cover snapshot parsing, timestamp text, active and attached window fields, fallback order, argv boundaries, startup windows, kill fallback, and creation scripts.
Rename checks record both move paths before any `send-keys` request and verify continuation after move failure.
Comma-name checks reject session recreation, script reruns, and incorrect window-attached status.
The fake adapter is a test-only module.
Production code always imports the public process adapter.

Real Git checks call `sessions.discover` and `sessions.path`.
They cover repeated roots, repository and bookmark collisions, generated worktree collisions, full-path keys, and `.git` files that point to `.bare`.
Their test configuration adapter supplies already-expanded absolute roots and bookmarks.
It does not replace catalog construction, discovery, or repository resolution.

The real tmux lifecycle includes comma session and window names.
A separate PTY test opens an existing comma session through `sessions.open`.
It attaches to the existing session and verifies that `.tms-create` does not rerun.
The test shell uses a temporary home and a private tmux configuration.

`mise exec -- zig build test` also runs pure catalog and command-format tests.
These cover shared ancestor depth, sorted keys, replacement behavior, stable indices, full-path identity, numeric default ordering, lexical switch ordering, clone-name inference, and exact session-list spacing.
Five tests inside `app.zig` skip with the production process adapter.
`src/app/check.py` reruns those tests with the fake adapter.

## Rust comparison

`session.rs` pops duplicate groups before renaming and insertion.
`repos.rs` adds generated worktree sessions before their parent repository.
Submodule insertion visits descendants before their parent, then inserts the root session.
The Zig catalog retains those rules.

A live Rust catalog check confirmed repository source precedence and `.bare` working directories.
It also confirmed duplicate generated worktree names and full-path keys.
Each case ran with full-path display enabled and disabled.

One repository-adapter difference remains outside this change.
For a directly discovered checkout of a bare Git repository, Rust reports `is_bare()` as true and generates worktree entries.
Zig's repository adapter reports `bare = false`.
When that checkout and its parent are both roots, Rust therefore generates an additional logical name.
Full-path display can collapse that name with another group's key.
Rust's hash-map group order then chooses the winner.
Repeated Rust runs produced both the deduplicated path name and the extra generated name.
No fixed precedence across different basename groups is claimed.

## Integration dependencies

This worktree still has foundation implementations of configuration and picker.
Full command differential and picker PTY verification require those workers.
No full command parity result is claimed here.
The existing `scripts/compat.py` and `scripts/compat_terminal.py` remain the integration gates.

The parent owns executable error rendering.
`app.failure` exposes contextual payloads for session-not-found, mark-not-found, missing clone or init search paths, and clone-name inference failure.
`run` clears that thread-local value on entry.
CLI parsing and configuration errors retain their domain errors.
The parent can combine these payloads with the CLI and configuration diagnostic helpers.
Slashless inferred clone names produce `error.InvalidRepositoryName`.
The Rust reference panics for that input, so its exit status still needs executable-level handling.

Independent code and comment review remain with the parent.
