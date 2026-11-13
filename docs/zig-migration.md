# Zig migration

Replace the Rust `tms` with Zig while preserving commands, configuration, repository discovery, session behavior, and the native picker.

The reference is commit `a91ea21780acb58eced5b7f52da7f212f6ca33f0`.

## Completion checks

The migration is complete when all of these checks pass.

- Recorded command, configuration, discovery, Git, jj, bookmark, mark, and session cases pass against Zig.
- Recorded Rust search rankings match Zig for smart case, Unicode, and query syntax.
- Terminal tests verify selection, cancellation, resize, configurable keys, colors, prompt placement, previews, and terminal restoration.
- The picker works in an attached terminal and a tmux popup.
- A repeatable benchmark records Rust and Zig startup and search responsiveness under the same conditions.
- mise supplies pinned development tools and runs the build, tests, checks, and release scripts.
- hk runs the same checks in pre-commit hooks and CI.
- Nix and release builds produce a Zig `tms` with no fzf or Rust runtime dependency.
- Rust is removed only after the compatibility checks pass.

An unexecuted check remains open. A failing reference case is recorded separately from a regression.

## Workflow

- [x] Read the Principles section of the poteto-mode skill.
- [x] Phase A: Frame.
- [x] Phase B: Design the workflow.
- [ ] Phase C: Run the loop.
- [ ] Phase D: Keep the audit trail.
- [ ] Phase E: Verify and hand back.

The implementation follows these units.

1. Record reference behavior and add executable compatibility fixtures.
2. Compare two module designs and choose explicit ownership and interfaces.
3. Pin Zig and add mise build and test tasks alongside Rust.
4. Port configuration, repository discovery, bookmarks, and marks.
5. Port command dispatch, tmux operations, and session management.
6. Port fuzzy matching and the terminal picker.
7. Run differential tests, real terminal tests, popup tests, and benchmarks.
8. Switch packaging, CI, releases, and documentation after compatibility passes.
9. Run independent review and final checks.

Each unit ends with an executable check before its dependent unit begins.

## Throughput checkpoint

- [x] **Blocking first steps.** Rust fixtures pass independently. The shared Zig contracts compile and pass `mise run test` on the integration branch.
- [x] **Independent workstreams.** Separate baseline compatibility tests, terminal verification, tooling, and build contracts. Split behavior implementation into configuration, repositories, matching, picker, and command integration after contracts compile.
- [x] **Shared mutable state.** Give each writer a separate worktree. The coordinator integrates verified commits serially.
- [x] **Smallest safe decomposition.** Keep integration under the coordinator. Workers cannot delegate further because the harness limits subagent depth.

## Coverage

| Workstream | Required evidence |
| --- | --- |
| Commands and sessions | Argument cases, output, exit status, isolated tmux state |
| Configuration and repositories | Defaults, TOML fixtures, real Git and jj fixtures |
| Picker and matching | Rust ranking oracle, PTY transcripts, popup transcript |
| Build and packaging | mise and hk checks, release builds, Nix validation |

## Scope and rigor

The baseline has 3,997 Rust source lines and 449 integration-test lines, counted with `wc -l src/*.rs src/picker/*.rs tests/*.rs`.

The work spans 13 commands, the default picker, shell completion, two repository providers, persistent configuration, and four release targets. Compatibility requires high rigor because replacing libraries changes parsing, matching, terminal handling, and repository interpretation together.

The initial exploration identified three difficult boundaries. Nucleo has richer semantics than generic fuzzy matching. Configuration parsing includes legacy coercions. jj generated picker entries include workspace-store records that its active-workspace CLI does not return.

The environment has Zig 0.17.1, hk 2.12.0, and jj 0.38.0 installed through mise. It has tmux 3.8 and Git 2.56.0. Nix was not found on PATH. Nix execution remains open until a suitable environment runs it.

## Verified units

- `mise run ci` passed hk validation, formatting, and all 16 existing Rust tests after tooling integration.
- `mise run test:compat:rust` passed 42 command cases and 25 ranking vectors on the integration branch.
- `mise run test:terminal:rust` passed seven real tmux terminal scenarios on the integration branch.
- The integrated Zig modules, including configuration and CLI parsing, pass `mise run test`.
- Six isolation tests prove the tmux shim rejects unsupported global options before launching a process. Four targeted Rust cases still pass with the corrected shim.
- The process adapter passes 15 runtime tests, including metadata-preservation and failed-copy privacy checks. The actual cross-device test is skipped because no writable second filesystem is available.
- Review found inherited-ACL and read-only staging cleanup gaps in the move fallback. Fixes are in progress.
- Command and tmux checks pass 23 tests and a real PTY comma-session regression. Independent review found no remaining issues in the comma-name and duplicate-precedence fixes.
- Repository checks pass 30 tests after the metadata-provenance and exclusion-presence fixes. The non-UTF-8 filename fixture is skipped on macOS and still needs Linux.
- The integrated Zig oracle matches all 25 stored ranking vectors and 3,989 independent Rust differential vectors.
- The broader Rust terminal suite reproduces 14 passes and three known defects after isolation and assertion fixes.
- All 20 harness tests pass. The continuous-output cleanup regression passes 20 consecutive runs after waiting for child reaping while draining PTY output.
- `mise run ci` passed with the integrated matcher, repository, process, and command modules before configuration integration.
- The integrated optimized picker passes 24 real PTY scenarios, including Unicode cursor placement, tiny resizes, termination signals, suspend/resume, allocation failures, and tmux previews.
- The integrated width oracle matches 6,651 Unicode width and grapheme-boundary vectors. Regeneration produces byte-identical width data.
- Expanded terminal coverage passes 22 harness tests. The Rust suite now records 17 passes and four known defects, including SIGHUP cleanup.

- The full optimized Zig application passes all 21 strict terminal and popup checks.
- CLI differential checks pass 815 completion probes, five registration scripts, 42 help forms, 13 exports, and 23 persistence comparisons.
- Full Zig replay passes 40 of 42 command cases and all 25 ranking cases. Invalid-TOML diagnostics and jj completion output still differ.

Review fixes remain open for blocked terminal output, malformed UTF-8 cancellation, doubled Escape, and consistent cursor width. Repository provenance fixes await independent review. Full compatibility remains gated on the two command differences.

## Decisions

The decision trail is `docs/zig-decisions.tsv`.

All requested workers use GPT-6.1 Sol with high reasoning. Independent attempts on this model are same-model review. Cross-family review is unavailable under the current model configuration.
