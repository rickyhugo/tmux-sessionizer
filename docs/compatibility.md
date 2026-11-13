# Rust compatibility baseline

This baseline records `tms` at `a91ea21780acb58eced5b7f52da7f212f6ca33f0`.
Rust source was retained unchanged during verification, then removed in `6c4daab`.
Captured defects describe reference behavior, not approval to keep the defects.
This document records the baseline; see [migration status](zig-migration.md)
for subsequent coverage and final results.

## Test data

`tests/compat/cases.json` contains named cases with temporary fixture operations and ordered command steps.
Each step specifies `argv` and can set its working directory, environment, input, or TOML output mode.
`tests/compat/golden.json` records normalized stdout, stderr, exit status, and state after every step.
State includes the parsed config, tmux sessions, windows, paths, client requests, and sent keys.

`tests/compat/ranking.json` contains query, input-order, and ranked-output lists.
The historical `examples/compat_oracle.rs` evaluates those lists with Nucleo.
It uses the same default matcher configuration, smart case, and smart normalization as the picker.
It waits for matching to finish instead of depending on thread timing.
The oracle has one protocol:

```sh
compat_oracle rank QUERY ITEM...
```

It prints one matched item per line in rank order.
A candidate can provide its own executable with this protocol through `TMS_ORACLE_BIN`.
Passing the Rust oracle while testing Zig verifies the stored Rust ranking only. It does not verify Zig ranking.

### Normalization

The runner replaces the temporary directory with `$ROOT` and this checkout with `$SOURCE`.
It removes ANSI escapes, Rust source-location lines, and panic process identifiers.
It keeps error text, error-tree structure, whitespace, exit status, and state changes.
TOML output and saved config use parsed values, so map order and TOML formatting do not cause failures.
Other output, including completion ordering and trailing spaces, remains exact.

The cases use Bash dynamic completion to observe complete discovery results:

```sh
COMPLETE=bash _CLAP_COMPLETE_INDEX=2 tms -- tms open-session ""
```

The trailing `--help` candidate and lack of a final newline are captured behavior.
Completion returns only `--help` when session discovery fails. An explicit `open-session` step exposes that failure where covered.

## Isolation

Every case gets a temporary HOME, config, Git identity, and unique tmux socket.
Git system and global config are disabled. Git fixture commits use a fixed date.
The tmux server loads only the fixture config. Its panes run `sleep`, not a user shell configuration.

The `tmux` shim records actual argument arrays as JSON.
It accepts only a separate `-L` and socket value, followed by no command or a command that does not start with `-`.
It rejects other global options, joined socket selectors, and extra options before the command without launching tmux.
It replaces the caller's socket selector with the private socket and forces the fixture config. Command arguments remain unchanged.
A separate fixture-only socket variable prevents a candidate's `TMS_TMUX_SOCKET` value from changing the safety destination.
State records whether the application requested the expected `-L` socket.
Attach and switch requests are recorded and return success without attaching a client.
They are not evidence of a real attached-client switch.
Sent keys reach sleeping fixture panes. Creation scripts are not executed.

The driver queries and kills only its own socket. Cleanup runs after failed assertions too.
Mise shim directories are removed from child PATH because the temporary HOME has no mise installation.
Runtime directories selected by `mise exec` remain available.
The runner assumes a trusted candidate that invokes `tmux` through PATH. It is not an operating-system sandbox.

`scripts/compat_terminal.py` uses real tmux PTYs on separate private sockets.
It waits for visible candidate counts, filtered results, selection markers, and process exit.
Its 20 ms polling interval only paces condition checks. It does not decide when to send input.
Terminal captures can be saved outside the checkout with `--artifacts`.

## Invocations

The verified toolchain uses Rust 1.99.0, Python 3.15.2, tmux 3.8, Git 2.56.0, and jj 0.38.0.
The Python runner requires Python 3.11 or later and uses only the standard library.
Git must support orphan worktrees. Existing tests also require relative worktree support.

Current candidate checks use:

```sh
mise run test:compat
mise run test:terminal:strict
```

To reproduce the Rust reference, create a detached worktree at `3ad4fda`.
That revision retains the unchanged Rust implementation, ranking oracle,
private-socket harness, and pinned Rust tasks:

```sh
git worktree add --detach ../tms-rust-reference 3ad4fda
cd ../tms-rust-reference
mise trust
mise install --locked
mise run test:compat:rust
mise run test:terminal:rust
```

The current differential scripts also accept separately built reference binaries.
An arbitrary candidate is selected with `TMS_BIN=/absolute/path/to/tms` or `--bin`.
`--case NAME` selects one case and can be repeated.
`--jj` includes the real jj fixtures. Omitting it prints explicit skips.
`--artifacts DIRECTORY` saves normalized tmux argument traces for command tests and screen captures for terminal tests.
Only `--capture` replaces goldens. Capture is reserved for an approved Rust baseline, never the candidate under comparison.
Capture updates selected cases without deleting the other cases.
`--oracle` is optional, so a command-only check must not be reported as ranking verification.

## Executed compatibility matrix

The final Rust check passes 42 cases with 141 command steps, 25 ranking vectors, and 7 terminal scenarios.
The unchanged Cargo suite also passes all 16 tests.
An intentional `/usr/bin/false` candidate fails the default-config comparison.

The case names below identify executable fixtures, not source-only expectations.
Each case can contain several commands and state comparisons.

| Cases | Covered observations |
| --- | --- |
| `help`, `argument-errors` | Root help and version, every command's help, marks subcommands, missing arguments, unknown commands and flags, invalid numbers, booleans, enum spellings, colors, and conflicting config arguments. |
| `config-defaults` | Absent config loads. Exported defaults, colors, shortcuts, VCS defaults, clone policy, and session sorting are captured. |
| `config-edit` | Canonical paths, one trailing slash, missing depth values default to 10, default-session period replacement, exclusions, all boolean options, list-worktrees, sort and clone policies, color override, and default-only listing. Depths without paths do not change existing depths. |
| `config-remove-without-exclusions` | Removing an exclusion before any exclusion list exists panics with exit 101. Known defect. |
| `config-missing-path` | A configured nonexistent CLI path fails without saving. |
| `invalid-toml` | Invalid TOML fails before `config list --defaults` and `sessions`. `--help` still succeeds. |
| `invalid-config-type`, `invalid-config-enum`, `invalid-config-keymap` | Invalid array-to-boolean conversion, VCS provider, and shortcut key fail config deserialization. |
| `config-type-coercion`, `unknown-config-key` | Config converts the string `yes` to boolean true, ignores an unknown top-level field, accepts `jj`, and merges a custom lowercase shortcut action with defaults. |
| `missing-search`, `invalid-search` | Missing versus invalid search paths have different errors. Marks and session listing work without search paths. |
| `discovery-depth`, `discovery-depth-zero` | Immediate and deeper repositories, hidden repositories, depth limits, repository roots at depth zero, and stopping traversal at a recognized repository. |
| `discovery-exclusions` | Exclusions match substrings of full paths and are case-sensitive. |
| `discovery-symlinks` | Directory symlinks are followed, broken links are skipped, and depth bounds a symlink cycle. Aliased repositories can produce duplicate session names with parent prefixes. |
| `discovery-duplicate-names` | Shared basenames expand to enough parent components to distinguish all duplicates. A short ambiguous name is not a lookup key. |
| `discovery-full-path` | Full-path display changes the lookup key. The resulting tmux session still uses the logical basename with periods replaced, not the visible full path. Hyphens remain unchanged. |
| `discovery-path-expansion` | Legacy search paths merge with search directories. Home and environment expansion work. Invalid entries are skipped if another path is valid. |
| `git-linked-worktree` | Main and linked checkouts appear separately. Reopening does not add windows. List-worktrees does not fan out a non-bare repository. |
| `git-bare-worktrees` | Bare repositories are listed. Enabling list-worktrees adds `project#workspace` entries. Opening a workspace uses its checkout and creates one window. Opening the bare repository itself does not create workspace windows. |
| `gitlink-dot-bare` | A project with `.git` pointing to `.bare` is discovered. Opening it uses the bare Git directory. |
| `git-submodules` | Initialized submodules are hidden by default and appear as `parent>child` when enabled. Opening one uses the submodule checkout. |
| `bookmarks` | Add, duplicate suppression, default current directory, invalid-path persistence, invalid-path omission from discovery, opening, deletion, and missing deletion. |
| `marks` | Empty list, missing index error, explicit index, first available valid index, invalid-path omission, sorted output, index shorthand, period normalization, single deletion, missing deletion, and clearing. |
| `session-create-script`, `session-create-script-override` | Default and configured creation-script paths are sent to the first pane only on initial session creation. A script need not be executable for tms to send its path. |
| `outside-tmux` | `TERM_PROGRAM=tmux`, not the presence of `TMUX`, selects switch versus attach behavior. |
| `start-empty`, `start-configured` | Empty start requests tmux. Configured start creates a session and named window, sends its command, removes the initial window, and requests attach. |
| `kill-default` | Session listing marks the current session with `*` and retains trailing spaces. Kill requests the configured fallback and removes the current session. |
| `refresh-worktree` | Refresh adds a missing worktree window and is idempotent. |
| `rename` | Rename moves the fixture directory, sends `cd`, renames the session, and requests attach. Sleeping panes retain their original current directory. |
| `rename-move-failure-ignored` | A blocking destination file makes `mv` fail. tms still exits zero, sends `cd`, and renames the session. Known defect. |
| `rename-global-replacement` | Rename replaces every occurrence of the session name in the path, including parent-directory components. Known defect. Session tokens avoid accidental matches inside the temporary directory itself. |
| `init-repo` | A single search directory permits noninteractive repository initialization and session creation. |
| `clone-local` | A real local Git clone creates a repository and session. Clone policy `Never` does not request a client switch. |
| `clone-failure-ignored` | A nonexistent clone source prints a Git error but tms exits zero and creates a session for the empty target directory. Known defect. |
| `jj-workspaces` | Real non-colocated jj default and linked workspaces are discovered and opened when jj is configured. The list-worktrees setting also captures the current failure for an empty jj repository. |
| `jj-default-provider` | Default Git-only discovery descends into a non-colocated jj repository and exposes its internal bare `git` repository. This is an observed metadata-discovery quirk, not intended jj support. |

### Picker evidence

The ranking fixtures cover empty-pattern injection order, subsequences, word and path boundaries, equal-score input ties, shorter matches, smart-case atoms, normalization, composed and decomposed accents, emoji graphemes, multiple atoms, prefix, suffix, whole-string, substring, negation, escaping, empty input, and no matches.
These are exact returned-order fixtures. They do not record score values or highlighted character positions.

The terminal script covers Escape, Ctrl-C, a custom cancel shortcut, filtering and confirmation, bottom and top navigation, and recovery from no matches with Backspace.
It asserts the chosen real tmux session, rather than only checking screen text.
It does not compare terminal control bytes or pixel layout.
The reference picker is native Rust. Neither implementation uses fzf.

### Existing Rust tests

The unchanged Cargo suite contains 7 library tests, 3 CLI tests, and 6 repository tests.
They also cover non-ASCII editing, duplicate-name generation, bare-repository workspace classification, and relative Git worktree paths.
The historical `--rust-tests` entry point supplies the private-socket shim.
It is retained in the reference worktree, not the current Zig runner.
The existing CLI test has its own fake tmux and logs joined arguments. The new shim keeps argument boundaries.

## Source-derived behavior and remaining gaps

These items come from source inspection unless an executed case above explicitly covers them:

| Source | Behavior or gap |
| --- | --- |
| `src/configs.rs` | Without `TMS_CONFIG_FILE`, config loading merges `~/.config/tms/config.toml` and the platform config location. The second source has precedence. Saving uses the platform config location. The baseline fixes `TMS_CONFIG_FILE` and does not test platform-specific fallback paths. |
| `src/configs.rs`, `src/cli.rs` | The export omits `input_position` even though the runtime supports Top and Bottom. Extra max-depth values are ignored. Exclusion additions need not be unique. |
| `src/repos.rs` | Permission-denied directories print a warning. Unreadable entries and invalid expansion values are skipped. Non-UTF-8 paths, permission warnings, uninitialized submodules, recursive submodules, prunable worktrees, and damaged repository metadata lack dedicated command fixtures. |
| `src/session.rs` | Bookmarks and repositories share duplicate-name handling. Overlapping search roots and duplicate bookmarks that resolve to the same repository lack dedicated fixtures. |
| `src/main.rs`, `src/cli.rs` | Default picker LastAttached ordering parses timestamps as numbers. Switch and kill compare timestamp strings lexically. Controlled differing-width timestamp fixtures are not included. |
| `src/cli.rs` | Switch can filter unknown sessions. Windows uses window IDs. The PTY script does not yet exercise switch or windows previews, narrow-terminal preview layout, active-session styling, or filter-unknown behavior. |
| `src/cli.rs` | `refresh NAME` uses the current session path for repository discovery, even when NAME names another target. The current fixture uses the same current and target session. |
| `src/cli.rs` | Clone `Always` and `Foreground`, delayed clone switching, clone-name inference, name collisions, multiple-path pickers, and default-session absence during kill lack dedicated fixtures. No network remotes are contacted. |
| `src/tmux.rs` | A failed real switch can fall back to attach, including process replacement. The safety shim returns success for switch and attach, so these fallbacks and real attached-client behavior remain unverified. |
| `src/picker/mod.rs` | The redraw callback is empty. Matching can finish while `event::read` waits, without a redraw until another event. |
| `src/picker/mod.rs` | Selection clamping uses `selected > matched_count`, not `>=`. An index equal to the new count can remain unselected after filtering. This source defect is not a required terminal fixture. |
| `src/picker/mod.rs` | A narrow preview forces bottom rendering locally but navigation still uses the configured input position. The script does not assert this rendering defect as desirable behavior. |
| `src/keymap.rs` | Text edits use Unicode scalar positions rather than terminal display width. Cursor movement, delete-word, delete-to-line-boundary, resize, all configurable actions, wide characters, and combining marks lack complete PTY coverage. |

The checked-in results were produced on macOS. Linux filesystem case behavior, error wording, Git stderr, and tmux behavior still need a CI run.
The runner intentionally preserves diagnostic wording, so a deliberate error-message change needs an explicit compatibility decision.
No Zig candidate has been validated by this baseline commit.
