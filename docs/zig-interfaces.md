# Zig worker interfaces

These are the integrated Zig domain contracts. The implementation and compatibility
gates are wired; recorded Rust fixtures remain the behavioral reference.

## Ownership

Five domain groups own these public contracts.

| Workstream | Exclusive files | Allowed imports |
| --- | --- | --- |
| Configuration and CLI | `src/config.zig`, `src/cli.zig`, private `src/config/` and `src/cli/`, `vendor/tomlc17/` | Config uses std only. CLI uses config and sessions. |
| Repositories | `src/repos.zig`, private `src/repos/` | config, process |
| Matcher | `src/matcher.zig`, private `src/matcher/` | std only |
| Picker and terminal | `src/picker.zig`, private `src/picker/` | config, matcher, tmux |
| Commands and adapters | `src/app.zig`, `src/sessions.zig`, `src/tmux.zig`, `src/process.zig`, corresponding private directories | App uses every domain. Sessions uses config, repos, tmux. Tmux uses process. Process uses std only. |

The integration layer owns `build.zig`, `build.zig.zon`, `src/main.zig`, `src/oracle.zig`, `src/contracts.zig`, mise, and hk. Domain tests live in their modules or private directories. Each module has a separate test artifact, so `zig build test` runs its tests.

Configuration owns picker options, colors, keys, bindings, actions, and VCS provider tags. Picker imports config, never the reverse. Sessions never imports picker. App maps session indices to picker IDs.

The build compiles vendored `vendor/tomlc17` by default. `-Dtomlc17=PATH`
selects another local directory. It attaches `tomlc17.c`, the include directory,
and libc to config. The native API is pinned at
`aa4ca1bc5fe6382ac631a8d1428077a9a084a64d` under MIT.
`vendor/tomlc17/README.md` records the local timestamp and underflow
compatibility patches.
The build fetches no parser; `vendor` is included in package paths.

## Lifetimes and errors

All signatures below use these aliases:

```zig
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;
```

`main` creates a command arena. Arguments, config, catalogs, domain records, strings, map backing storage, and durable process results live until command exit. Returned slices use the supplied allocator unless the contract explicitly borrows an input. No domain frees command-arena results.

Picker's `scratch` is a reclaimable allocator, not the command arena. Picker owns reusable query buffers and a resettable matching arena. It releases temporary storage on every exit. Matcher callers likewise reclaim or reset all allocations after each query. Picker restores terminal state before returning, reporting an error, or permitting process replacement.

Public domain effect APIs receive `Io`. Environment-sensitive configuration
receives the environment map explicitly. Process requests inherit the parent
environment unless `Request.env` overrides it.

There is a narrow exception for synchronous native backend helpers:

- `src/picker/terminal.zig` owns a native terminal fd, termios, descriptor flags,
  polling, and signal handlers.
- The account lookup helper in `src/config.zig` uses libc `getuid`/`getpwuid`
  when the supplied environment has no home directory.
- The metadata-preserving copy backend in `src/process/move.zig` uses native
  staging creation, no-follow file/link copying, metadata, ACL, xattr, ownership,
  timestamp, and file-flag calls. They preserve private staging, hardlinks, and
  platform metadata together, rather than substituting a generic file copy.

These helpers need no unused `Io` parameter. The exception does not permit
ordinary file traversal, subprocesses, or public domain operations to bypass
`Io`. It preserves exact platform behavior behind the owning domain boundary,
not a second application-wide effect interface.

Native calls are synchronous and do not participate in `std.Io` cancellation.
The terminal backend owns signal handling and restoration: nonblocking writes
check termination and suspension, output polling waits at most 50 ms, and the
picker checks signals around input polling (35 or 100 ms). It restores termios
before signal re-delivery or suspension; cleanup does not wait for queued output.
Account lookup can block inside libc; it has no separate cancellation guarantee.
The move adapter owns staging, metadata completion, publication, and cleanup;
native helper calls do not create detached work or transfer cleanup to callers.
Directory traversal, publication, and tree cleanup still use the supplied `Io`.
Do not describe the native portions as interruptible `Io` operations.

Public domain operations use `anyerror`. A nonzero child exit is data in
`Output.term`, not automatically an error. Domain and command owners retain
the reference's success policies.

## Data identities

The public record declarations in each module are canonical. These invariants govern their use:

- `config.Config` is the raw merged configuration. Every original field remains optional, including lists and maps. `null`, an empty collection, and a collection whose paths are invalid remain distinct. `SettingsEdit` carries CLI edits, not a replacement Config.
- `repos.RepoRef` has `path`, `provider`, and optional `git_metadata`, which defaults to null. `path` is the encountered spelling, not necessarily canonical. Registered submodules retain their resolved metadata path in `git_metadata`. Later resolution uses that path rather than looking for another repository. Other callers leave it null. `detect` borrows its path argument. Allocated discovery results use the command allocator.
- `sessions.Session` has `key`, `name`, and `source`. `Source` is a repository reference or bookmark path. A visible key is not a tmux name.
- `sessions.Catalog.entries` is the visible-key-sorted canonical array. `by_key` maps visible keys to entry indices. App uses `catalog.by_key.get(key)` and indexes `entries`. The array and its indices remain unchanged for the catalog lifetime. Duplicate visible keys follow baseline replacement behavior.
- `picker.Item.id` is an application identity, not an injection index. `choose` returns that ID. App uses catalog indices for session items and separate stable indices for windows or directories. `label` always retains original bytes.
- `matcher.rank` returns indices into the candidate input array. Ranking compares Nucleo score descending, matching representation length ascending, then original index ascending. Empty query retains injection order. Scores and representation lengths stay private to the matcher.
- `picker.State.query` contains UTF-8 bytes. `scalar_cursor` counts Unicode scalars. `ranked` borrows matching results. `selection` is a position in that ranked slice, not an Item ID. `scroll` is a ranked-row offset. `size` carries terminal width and height.
- `tmux.SessionInfo.last_attached` retains timestamp text. Switch and kill compare text lexically. Session ordering parses it numerically. `Window.active` and `Window.attached` are distinct tmux fields.

## Configuration and CLI

These signatures belong to `src/config.zig`:

```zig
pub fn load(io: Io, a: A, env: *const Env) anyerror!Config;
pub fn commit(io: Io, a: A, env: *const Env, cfg: *Config, edit: Edit) anyerror!void;
pub fn exportToml(a: A, cfg: *const Config, defaults: bool) anyerror![]const u8;
pub fn searchRoots(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const SearchDirectory;
pub fn bookmarkPaths(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const []const u8;
pub fn validMarks(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const Mark;
pub fn expandPath(io: Io, a: A, env: *const Env, path: []const u8) anyerror![]const u8;
pub fn pickerOptions(a: A, cfg: *const Config) anyerror!PickerOptions;
pub fn parseKey(text: []const u8) anyerror!Key;
```

`commit` applies a typed Edit and saves the merged raw config to the selected destination. Its variants cover settings, bookmark add and delete, optional-index mark set, mark delete, and mark clear. Automatic mark allocation belongs here. `validMarks` returns canonical paths sorted by valid numeric index. Raw map values remain available for explicit mark lookup, so an invalid stored path is not mistaken for a missing mark.

Configuration owns recursive table merging and array replacement. It does not use tomlc17's `toml_merge`, which appends arrays instead of replacing them.

`searchRoots` merges new and legacy roots, expands and canonicalizes them, and distinguishes missing roots from invalid roots. `bookmarkPaths` omits invalid paths. `expandPath` performs shell-style environment and tilde expansion without requiring that the result exists. This permits startup session and window paths. `pickerOptions` resolves defaults and merges bindings. `exportToml` emits the reference's exported model, not raw persistence TOML.

These signatures belong to `src/cli.zig`:

```zig
pub fn parse(a: A, args: []const []const u8) anyerror!Command;
pub fn help(a: A, path: []const []const u8) anyerror![]const u8;
pub fn complete(io: Io, a: A, args: []const []const u8, env: *const std.process.Environ.Map) anyerror!bool;
```

`parse` receives arguments without argv[0]. `Command` covers default picking, every current command, help, and version. Its `switch_session` tag represents the external `switch` command. Marks shorthand and subcommands map to `MarksCommand`. `help.path` identifies the command whose help was requested.

`complete` receives the full argv, checks the `COMPLETE` protocol before ordinary parsing or config loading, writes completion output, and returns whether it handled the invocation. Dynamic candidates use sessions and valid marks. Private CLI code owns formatting and diagnostics.

## Repositories

These signatures belong to `src/repos.zig`:

```zig
pub fn discover(io: Io, a: A, search: Search) anyerror![]const RepoRef;
pub fn detect(io: Io, path: []const u8, providers: []const Provider) anyerror!?RepoRef;
pub fn resolve(io: Io, a: A, ref: RepoRef) anyerror!Resolved;
pub fn worktrees(io: Io, a: A, ref: RepoRef, set: WorkspaceSet) anyerror![]const Worktree;
pub fn submodules(io: Io, a: A, ref: RepoRef, recursive: bool) anyerror![]const Submodule;
pub fn cloneRepo(io: Io, a: A, remote: []const u8, target: []const u8) anyerror!void;
pub fn initRepo(io: Io, a: A, target: []const u8, env: *const Env) anyerror!void;
```

`Search` carries validated roots, optional literal substring exclusions, and ordered providers. `excluded = null` skips exclusion-related path validation. A present list, including an empty list, requires every queued path to be UTF-8. Callers preserve configuration presence instead of replacing null with an empty list.

Detection is shallow. Resolution is lazy and cannot fall back to another provider. `Resolved` carries cwd, metadata path, bare status, and linked status. Submodule enumeration uses the known parent registration when checkout metadata is absent. Returned references preserve metadata ownership even when an unrelated repository lies between the parent and the deleted checkout.

`WorkspaceSet.active_other` serves refresh and excludes the current jj workspace. `registered` serves generated catalog entries and includes workspace-store records. Git worktree names use administrative IDs. `Submodule.name` retains the provider's name for session naming. `cloneRepo` creates the target directory, inherits output, waits, and preserves the baseline's ignored nonzero exit. Other spawn failures remain errors.

## Matcher and oracle

These signatures belong to `src/matcher.zig`:

```zig
pub fn rank(allocator: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]usize;
```

This entry point is pure except allocator use. It preserves Nucleo query grammar, smart case, smart normalization, grapheme representation, and scoring. Duplicate labels remain separate input indices. The caller owns and frees the returned slice. Matcher frees its internal scratch before returning.

`src/matcher.zig` exposes `src/matcher/engine.zig`'s `rank` with the same argument
and result types. Matching internals remain private to that directory.

The default build installs `zig-out/bin/tms-oracle`. `zig build oracle` builds and installs only this executable. Its protocol is:

```sh
tms-oracle rank QUERY ITEM...
```

The oracle calls `matcher.rank`, then prints each original `ITEM` selected by
its ranked index, one per line. It performs no label lookup or deduplication.
Invalid protocol exits 2. `mise run test:compat` checks all 25 stored Rust ranking
vectors through this Zig oracle, alongside command compatibility.

## Picker

These signatures belong to `src/picker.zig`:

```zig
pub fn reduce(a: A, state: *State, event: Event, options: config.PickerOptions) anyerror!Transition;
pub fn choose(io: Io, result: A, scratch: A, items: []const Item, options: config.PickerOptions) anyerror!?usize;
```

`Event` carries a decoded config Key, resized Size, or a borrowed ranked result slice. `Transition` is unchanged, redraw, rematch, confirm, or cancel. The local reducer owns query editing, selection, scrolling, and size. It performs no terminal IO.

`choose` owns decoding, terminal lifetime, matching, previews, rendering, and signals. Null means user cancellation. `Preview` is none, a tmux client and target pane, or a directory path. Directory preview uses native enumeration. App constructs typed previews before calling the picker.

## Sessions and command application

These signatures belong to `src/sessions.zig`:

```zig
pub fn discover(io: Io, a: A, env: *const Env, cfg: *const config.Config) anyerror!Catalog;
pub fn orderedIndices(a: A, catalog: Catalog, snapshot: tmux.Snapshot, order: config.Order) anyerror![]const Index;
pub fn fromPath(io: Io, a: A, env: *const Env, input_path: []const u8) anyerror!Session;
pub fn path(io: Io, a: A, entry: Session) anyerror![]const u8;
pub fn open(io: Io, a: A, entry: Session, client: *const tmux.Client, cfg: *const config.Config) anyerror!void;
```

`discover` owns bookmarks, duplicate names, full-path keys, submodule names, and generated worktree entries. `orderedIndices` returns catalog indices in default-picker order without changing the catalog. App computes active flags from the snapshot and constructs picker items.

`fromPath` expands and canonicalizes a bookmark or mark path and constructs its session identity. `path` resolves repository working directories. `open` normalizes the tmux name, creates only when absent, sends the selected creation script only on creation, then attaches or switches. Refresh alone adds worktree windows.

This signature belongs to `src/app.zig`:

```zig
pub fn run(io: std.Io, command: std.mem.Allocator, scratch: std.mem.Allocator, argv: []const []const u8, env: *const std.process.Environ.Map) anyerror!void;
```

`argv` includes argv[0]. App checks completion first, parses, handles help and version before config loading, then dispatches. App owns switch and kill's lexical ordering, clone switch policy, refresh, rename, startup sessions, marks, and output. App calls domain operations directly. There is no command-wide effect interpreter.

## Tmux

These methods belong to `src/tmux.zig.Client`. `Output` aliases `process.Output`.

```zig
pub fn snapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot;
pub fn windows(self: *const Client, io: Io, a: A, session: ?[]const u8) anyerror![]const Window;
pub fn panes(self: *const Client, io: Io, a: A) anyerror![]const Pane;
pub fn capture(self: *const Client, io: Io, a: A, target: []const u8) anyerror![]const u8;
pub fn attachedSession(self: *const Client, io: Io, a: A) anyerror![]const u8;
pub fn newSession(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!Output;
pub fn newWindow(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8, session: ?[]const u8) anyerror!Output;
pub fn killSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output;
pub fn killWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output;
pub fn selectWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output;
pub fn renameSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output;
pub fn sendKeys(self: *const Client, io: Io, a: A, text: []const u8, target: ?[]const u8) anyerror!Output;
pub fn switchClient(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output;
pub fn switchTo(self: *const Client, io: Io, a: A, name: []const u8) anyerror!void;
pub fn attach(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!noreturn;
pub fn refreshClient(self: *const Client, io: Io, a: A) anyerror!Output;
pub fn start(self: *const Client, io: Io, a: A) anyerror!Output;
```

`Client` carries socket and inside_tmux. App sets these from `TMS_TMUX_SOCKET` and `TERM_PROGRAM == "tmux"`. Every invocation includes `-L` and the socket.

`Snapshot.current` is the current client's session name and path, or null. Its `sessions` list includes all session records. `attachedSession` preserves the reference's attached-session query result for clone foreground comparisons. `panes` provides the reference's window-index and pane-index targets, commands, and paths for rename.

`switchClient` owns its inherited attach fallback. `switchTo` owns inside versus outside tmux and the final replacement fallback, preserving invocation order. `attach` replaces the process and only returns on error. `start` invokes tmux without a subcommand.

## Process and filesystem adapter

These signatures belong to `src/process.zig`:

```zig
pub fn capture(io: Io, a: A, request: Request) anyerror!Output;
pub fn inherit(io: Io, request: Request) anyerror!std.process.Child.Term;
pub fn replace(io: Io, request: Request) anyerror!noreturn;
pub fn movePath(io: Io, a: A, from: []const u8, to: []const u8) anyerror!void;
```

`Request` contains argv, optional cwd, optional environment map, and inherited or ignored stdin. `capture` returns separate stdout, stderr, and termination status. `inherit` inherits stdout and stderr and returns termination status. The adapter owns each child's wait and kill cleanup. It does not interpret domain success.

`movePath` replaces the reference's `mv` operation with native filesystem operations, including observable overwrite and cross-device behavior. The rename command retains the baseline's ignored move failure at its call site.

## Integrated checks

`mise run build` installs tms and the oracle. `mise run test` compiles every public domain declaration and Client method, then runs all module tests. Contract tests check optional collection presence, stable identity across reordered injection, and scalar cursor representation. The oracle test checks output order, original Unicode bytes, and duplicate labels without claiming matcher parity.

`mise run fmt` formats Zig through hk. `mise run ci` validates hk, checks
formatting, tests Zig, builds ReleaseFast, and runs harness isolation, command
adapters, command/ranking compatibility, strict terminal/popup checks, and
focused picker regressions. Rust tooling was retired after compatibility passed.
See [development](development.md) for commands and Rust reference reproduction.
