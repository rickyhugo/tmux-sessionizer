# Repository port

## Contract

`RepoRef` retains the encountered path and the selected provider. `discover` uses a breadth-first queue of validated search roots. It detects repositories at depth zero, follows directory symlinks, and stops below shallow repository markers. Exclusions are case-sensitive literal substrings of the whole encountered path. Configuration owns root expansion and canonicalization.

Detection does not invoke Git or jj. A broken `.git` marker still stops traversal. `resolve` opens only the selected provider, without fallback. `Resolved` separates the checkout directory, metadata directory, bare classification, and linked classification.

Every subprocess uses the imported `process` module. Filesystem operations receive `std.Io`. Results use the command allocator.

## Git

Resolution follows relative or absolute `.git` pointers. A pointer to a bare `.bare` directory resolves to that directory and is not classified as a linked checkout. Non-bare checkouts with a `.git` file are linked, including the reference's submodule classification.

Worktree enumeration reads the common Git directory's `worktrees` administrative records. Names are administrative IDs, not branch names. Relative `gitdir` pointers resolve against the administrative record's directory. The main checkout is absent from this list. Records without a `gitdir` file are absent. Missing checkout directories and unreadable or empty pointers are prunable. Invalid pointers have an empty path so downstream shallow detection cannot generate a session from them.

Submodules use `.gitmodules`, then its index version, then its HEAD version. Registered module names locate metadata. Checkout basenames determine returned names. Recursive names use `child>grandchild`, with descendants before their parents. Uninitialized modules without repository metadata are absent.

`cloneRepo` creates the target directory, inherits output, waits, and ignores a nonzero Git exit. This preserves the captured clone-failure defect. Spawn and wait failures remain errors. `initRepo` uses quiet Git initialization and checks its exit.

## jj

jj is an optional runtime dependency. The tested CLI version is pinned at 0.38.0. Reads use `--ignore-working-copy`, `--no-pager`, and `--color=never`. Log and workspace-list queries supply explicit templates.

Bare classification checks the recorded working-copy commit, without snapshotting files. The commit must be empty and a direct child of the root commit. A command failure during this classification yields false, as the reference's failed repository or commit load does.

The two workspace sets remain distinct.

- `active_other` reads active workspace names through the CLI, excludes the current workspace name, looks up registered roots, and opens each remaining checkout. Missing and damaged checkouts are absent. Names come from the validated checkouts, not potentially stale registration names.
- `registered` reads `.jj/repo/workspace_store/index` directly. Its schema-specific protobuf reader preserves record order, current-workspace records, and stale records. It does not mark stale records as prunable. Invalid path encodings are omitted, matching the reference's per-record path failure. Invalid protobuf strings or structure fail the read.

The protobuf schema comes from the cached `jj-lib` 0.38.0 `src/protos/simple_workspace_store.proto`. The outer field 1 repeats workspace messages. Each workspace has a UTF-8 name in field 1 and path bytes in field 2. The reader skips unknown varint, fixed-width, and length-delimited fields. It rejects unsupported wire types and malformed lengths or varints.

The active list also reads field 3 of `.jj/working_copy/checkout`, defined by `local_working_copy.proto`. This identifies the current workspace even if its registered path is stale. An absent name retains the reference's old-format `default` fallback. The CLI template converts workspace symbols to raw strings before delimiting them, so quoted display names do not change lookup names.

## Captured jj failure

The immutable `jj-workspaces` baseline initially completes `linked` and `project` and opens both. After `list_worktrees` is enabled, completion returns only `--help`. Opening `project` exits 1 with:

```text
Error: IO Error
╰─▶ Not a directory (os error 20)
```

The linked workspace has a `.jj/repo` file, not a directory. The reference's lazy registered-workspace path appends `workspace_store/index` to that file instead of following its pointer. This port retains that path and its `error.NotDir` result. The resolved metadata path still follows the pointer for other operations.

Following the pointer for generated entries would improve this behavior, but would change the captured result. This port does not make that improvement or change any compatibility expectations. Formatting the module error as the captured CLI diagnostic belongs to the application.

## Verification

The module tests include filesystem discovery, pointer and protobuf parsing, and temporary Git and jj fixtures. They use no tmux socket and do not change user repositories.

The isolated module run passes all 22 tests with Zig 0.17.1, Git 2.56.0, and jj 0.38.0. Eleven tests execute real Git or jj fixtures through `process.capture` or `process.inherit`. `zig build test` and the ReleaseFast build also pass with the process dependency applied. Other domain implementations remain the parent's integration work.

Run the isolated module tests with the pinned toolchain:

```sh
mise exec -- zig test --dep config --dep process \
	-Mroot=src/repos.zig -Mconfig=src/config.zig \
	-Mprocess=src/process.zig -lc
```

The parent owns command-level compatibility replay and independent review. Module fixtures cannot establish complete CLI diagnostic parity.
