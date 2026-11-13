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
- [ ] Phase B: Design the workflow.
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

- [ ] **Blocking first steps.** Capture Rust behavior and agree on shared types before implementation.
- [ ] **Independent workstreams.** Investigate commands, configuration and discovery, and picker and packaging separately. Partition implementation after interfaces are fixed.
- [ ] **Shared mutable state.** Give each writer a separate worktree. The coordinator integrates verified commits serially.
- [ ] **Smallest safe decomposition.** Keep integration under one owner. Split independent modules and verification artifacts into bounded assignments.

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

## Decisions

The decision trail is `docs/zig-decisions.tsv`.

All requested workers use GPT-6.1 Sol with high reasoning. Independent attempts on this model are same-model review. Cross-family review is unavailable under the current model configuration.
