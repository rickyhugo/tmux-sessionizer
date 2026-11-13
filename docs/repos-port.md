# Repository port

## Contract

`RepoRef` retains the encountered path and the selected provider. Its optional `git_metadata` field defaults to null. Registered submodules retain their resolved metadata path in this field so later resolution uses the same repository.

`discover` uses a breadth-first queue of validated search roots. It detects repositories at depth zero, follows directory symlinks, and stops below shallow repository markers. Exclusions are case-sensitive literal substrings of the whole encountered path. Configuration owns root expansion and canonicalization.

`Search.excluded` preserves absent and present-empty configuration values. A present exclusion list, even an empty list, requires every queued path to be UTF-8. An absent list skips this validation. Sessions pass `cfg.excluded_dirs` unchanged.

UTF-8 validation also occurs when discovery returns a repository name and when a permission warning needs a path string. An unrelated non-UTF-8 filename does not fail discovery without exclusions. A non-UTF-8 ancestor does not invalidate a UTF-8 repository basename.

Detection does not invoke Git or jj. A broken `.git` marker still stops traversal. `resolve` opens only the selected provider, without fallback. `Resolved` separates the checkout directory, metadata directory, bare classification, and linked classification.

Every subprocess uses the imported `process` module. Filesystem operations receive `std.Io`. Results use the command allocator.

## Git

Resolution follows relative or absolute `.git` pointers. A pointer to a bare `.bare` directory resolves to that directory and is not classified as a linked checkout. Non-bare checkouts with a `.git` file are linked, including the reference's submodule classification.

Bare classification reads `core.bare` from the common directory's config before private worktree config, matching gix 0.85. A linked checkout of a bare common repository is both bare and linked, and retains its checkout directory. `core.worktree` applies only when its config origin is inside the current metadata directory. This includes private config includes, but excludes common config for linked checkouts and includes outside the current metadata directory.

Worktree enumeration reads the common Git directory's `worktrees` administrative records. Names are administrative IDs, not branch names. Relative `gitdir` pointers resolve against the administrative record's directory. The main checkout is absent from this list. Records without a `gitdir` file are absent. Missing checkout directories and unreadable or empty pointers are prunable. Invalid pointers have an empty path so downstream shallow detection cannot generate a session from them.

Submodules use a non-symlink `.gitmodules`, then its index version, then its HEAD version. A symlink target never supplies module configuration. A checkout's existing `.git` directory or pointer takes precedence. Otherwise, the known parent's common directory and registered module name locate `modules/<name>`. Resolution does not search ancestors for submodule ownership.

Returned references retain the resolved metadata path, including for nested modules whose checkout directories have been deleted. An unrelated repository between parent and child cannot change this ownership. Returned paths use the configured workdir even when it does not exist. Checkout basenames determine returned names. Recursive names use `child>grandchild`, with descendants before their parents. Uninitialized modules without repository metadata are absent.

Git read commands run inside existing metadata directories with an explicit `--work-tree` argument. A missing configured workdir cannot prevent metadata reads. The argument controls the subprocess context, not the returned workdir.

`cloneRepo` creates the target directory, inherits output, waits, and ignores a nonzero Git exit. This preserves the captured clone-failure defect. Spawn and wait failures remain errors.

`initRepo` refuses existing `.git` entries and uses quiet Git initialization
with SHA-1 and no ambient templates. Its child environment removes layout
redirects (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, and
`GIT_OBJECT_DIRECTORY`). Native writes install the reference's fixed gix
templates; their provenance and MIT notice live in `src/repos/template`.
The configured initial branch is retained, with the reference's `main`
fallback. Git exit status is checked.
Creation uses isolated settings before reading reference configuration and
validating the branch. Invalid configuration or branch names retain the
reference's completed fallback layout. See `src/repos/init.md` for phase order,
configuration-source rules, and branch validation.

## jj

jj is an optional runtime dependency. The tested CLI version is pinned at 0.38.0. Reads use `--ignore-working-copy`, `--no-pager`, and `--color=never`. Log and workspace-list queries supply explicit templates.

Bare classification checks the recorded working-copy commit, without snapshotting files. The commit must be empty and a direct child of the root commit. The query selects `@` and reads commit-template methods for emptiness and root parents. User revset aliases for `empty()`, `root()`, and `children()` cannot change the result. User config remains enabled. A command failure during this classification yields false, as the reference's failed repository or commit load does.

The two workspace sets remain distinct.

- `active_other` reads active workspace names through the CLI, excludes the current workspace name, looks up registered roots, and opens each remaining checkout. Missing and damaged checkouts are absent. Names come from the validated checkouts, not potentially stale registration names.
- `registered` reads `.jj/repo/workspace_store/index` directly. Its schema-specific protobuf reader preserves record order, current-workspace records, and stale records. It does not mark stale records as prunable. Invalid path encodings are omitted, matching the reference's per-record path failure. Invalid protobuf strings or structure fail the read.

The protobuf schema comes from the cached `jj-lib` 0.38.0 `src/protos/simple_workspace_store.proto`. The outer field 1 repeats workspace messages. Each workspace has a UTF-8 name in field 1 and path bytes in field 2. The reader skips unknown varint, fixed-width, and length-delimited fields. It rejects unsupported wire types and malformed lengths or varints.

The active list also reads field 3 of `.jj/working_copy/checkout`, defined by `local_working_copy.proto`. This identifies the current workspace even if its registered path is stale. An absent name retains the reference's old-format `default` fallback. The CLI template converts workspace symbols to raw strings before delimiting them, so quoted display names do not change lookup names. Root lookups use one `--name=<name>` argument so leading hyphens remain part of the workspace name.

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

The isolated module run passes 30 tests and skips one on macOS arm64 with Zig 0.17.1, Git 2.56.0, and jj 0.38.0. Seventeen tests execute real Git or jj fixtures through `process.capture` or `process.inherit`. The alias regression gives its own `std.Io.Threaded` an isolated config environment instead of changing user config.

A small Rust oracle linked the unchanged `src/repos.rs` reference and exercised gix 0.85 and jj-lib 0.38 on temporary fixtures. It confirmed these results:

| Fixture | Rust result |
| --- | --- |
| Bare common repository with linked checkout | Bare and linked, even with private `core.bare=false` |
| Linked checkout with common `core.worktree=..` | Common setting ignored, private setting and private include accepted, outside include ignored |
| jj with `empty()=none()` | Recorded empty root child remains bare |
| Invalid UTF-8 queued path that cannot be opened | Detection fails without a UTF-8 error, explicit string conversion fails |
| jj workspace named `-topic` | Active workspace returned |
| Deleted submodule checkout with retained metadata | Configured workdirs returned for child and nested module |
| Deleted submodule checkout beneath an unrelated `vendor` repository | Parent registration still opens the child and nested module |
| Symlinked `.gitmodules` with different target content | Index version used, then HEAD after index removal |

The unrelated-ancestor regression failed before the fix with zero returned children. It now verifies enumeration, resolution of returned references, nested enumeration through a returned reference, and recursive order.

macOS rejects creation of the byte-`0xff` filename with `EILSEQ`. The real-file UTF-8 regression skips only that platform error. The synthetic queued-path boundary tests pass, including absent versus present-empty exclusions without filesystem access. Real non-UTF-8 file and ancestor behavior still needs a Linux run. The real-file fixture checks both empty and nonempty exclusion lists. The reference's `search_dirs` constructs an excluder for `Some([])` and converts every queued path when that excluder is present.

A separate Rust boundary probe uses the reference's Aho-Corasick builder and `DirtyUtf8Path` conversion on synthetic invalid bytes. `None` skips conversion, while `Some([])` returns `NonUtf8Path`. This probe does not exercise filesystem traversal.

`zig build test`, ReleaseFast tests, and the ReleaseFast build pass. Compatibility fixture goldens are unchanged. Command-level compatibility replay remains deferred until configuration integration is ready.

Run the isolated module tests with the pinned toolchain:

```sh
mise exec -- zig test --dep config --dep process \
	-Mroot=src/repos.zig -Mconfig=src/config.zig \
	-Mprocess=src/process.zig -lc
```

The parent owns command-level compatibility replay and independent review. Module fixtures cannot establish complete CLI diagnostic parity.
