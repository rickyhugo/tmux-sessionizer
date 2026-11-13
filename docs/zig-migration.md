# Zig migration

Replace the Rust `tms` with Zig while preserving commands, configuration, repository discovery, session behavior, and the native picker.

The reference is commit `a91ea21780acb58eced5b7f52da7f212f6ca33f0`.

## Current status

The Zig implementation, packaging switch, and Rust retirement are integrated.
Shared local checks pass on Apple Silicon. The reviewed source at `6a16a34`
passes all 13 native aarch64 Linux verification steps, including real
cross-device metadata preservation. All four release archives build and
validate with 15 exact notices. Source installation with a spaced prefix passes.

Commit `32c24bc` was pushed to `main`. Six Sol-high review slices completed
against the Rust reference and found 19 spec findings, one documented I/O
contract mismatch, and two maintainability concerns. Their fixes and additional
targeted review repairs are integrated with regression tests.

Hosted Nix builds passed on both macOS architectures and aarch64 Linux.
The original x86_64 Linux job failed when the allocation-failure pipe test was
killed after hanging. Its fault injector is repaired and bounded. The original
CI run was cancelled after diagnosis. Hosted verification of the repaired
revision remains open.
Native Intel/x86-64 release-archive execution remains open.
Nothing has been tagged or released.

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
- [x] Phase C: Run the loop.
- [x] Phase D: Keep the audit trail.
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

The environment has Zig 0.17.1, hk 2.12.0, and jj 0.38.0 installed through mise.
It has tmux 3.8 and Git 2.56.0. Nix 2.35.6 runs in a dedicated native aarch64
Linux container; it is not installed on the macOS host.

## Verified units

- `mise run ci` passed hk validation, formatting, and all 16 existing Rust tests after tooling integration.
- `mise run test:compat:rust` passed 42 command cases and 25 ranking vectors on the integration branch.
- `mise run test:terminal:rust` passed seven real tmux terminal scenarios on the integration branch.
- The integrated Zig modules, including configuration and CLI parsing, pass `mise run test`.
- Six isolation tests prove the tmux shim rejects unsupported global options before launching a process. Four targeted Rust cases still pass with the corrected shim.
- The process adapter passes 15 runtime tests, including metadata-preservation and failed-copy privacy checks. The actual cross-device test is skipped because no writable second filesystem is available.
- Inherited-ACL and read-only staging cleanup fixes are integrated. Parent verification passes all 19 process tests across real APFS devices with ownership enabled. Review found two additional cases requiring reproduction: restrictive ACLs before cross-subdirectory hardlink creation, and immutable file flags before metadata completion and rollback.
- Command and tmux checks pass 23 tests and a real PTY comma-session regression. Independent review found no remaining issues in the comma-name and duplicate-precedence fixes.
- Repository checks pass 30 tests after the metadata-provenance and exclusion-presence fixes on macOS. All 31 pass on native Linux, including the non-UTF-8 filename fixture.
- The integrated Zig oracle matches all 25 stored ranking vectors and 3,989 independent Rust differential vectors.
- The broader Rust terminal suite reproduces 14 passes and three known defects after isolation and assertion fixes.
- All 20 harness tests pass. The continuous-output cleanup regression passes 20 consecutive runs after waiting for child reaping while draining PTY output.
- `mise run ci` passed with the integrated matcher, repository, process, and command modules before configuration integration.
- The integrated optimized picker passes 24 real PTY scenarios, including Unicode cursor placement, tiny resizes, termination signals, suspend/resume, allocation failures, and tmux previews.
- The integrated width oracle matches 6,651 Unicode width and grapheme-boundary vectors. Regeneration produces byte-identical width data.
- Expanded terminal coverage passes 22 harness tests. The Rust suite now records 17 passes and four known defects, including SIGHUP cleanup.

- The full optimized Zig application passes all 21 strict terminal and popup checks.
- CLI differential checks pass 815 completion probes, five registration scripts, 42 help forms, 13 exports, and 23 persistence comparisons.
- Full Zig replay passes all 42 command cases and all 25 ranking cases after config/CLI fixes.
- `mise run ci` passes with unconditional release command/ranking, strict terminal, and focused picker checks.
- Seven alternating release samples per implementation validated all 1,000 candidates and the unique search result without errors. The timing verdict remains inconclusive because the limiter is unmeasured and startup variation is large. Raw results are in `tests/terminal/zig-integration/benchmark-results.json`.
- Full optimized application cross-builds pass for Intel macOS, x86_64 Linux GNU with a glibc 2.28 baseline, x86_64 Linux musl, and aarch64 Linux musl. These are compilation checks, not runtime evidence.
- Native aarch64 Linux passes 94 module tests with six expected skips, all 21 strict terminal checks, seven focused picker checks, and both actual cross-device fixtures. Parent reruns independently confirm the non-UTF-8 fixture and 18 process tests with one Darwin-only skip. See `docs/linux-verification.md`.

### Final integration

- `3b1bb6f` defers Darwin metadata until all hardlinks exist and applies file
  flags last. All 21 process tests pass across ownership-enabled APFS devices.
- `9d94ab3` bounds clipping to 76 width transitions per scalar and handles
  suspension during saturated terminal entry. Six width tests and nine focused
  PTY scenarios pass, including three consecutive stop/resume cycles.
- The integrated CLI differential runner passes 815 completion probes,
  40 jj child-environment cases, five registration scripts, 42 help forms,
  13 exports, 23 persistence comparisons, and the new parser/source regressions.
  Generic malformed TOML retains native parser wording except the documented
  EOF-array compatibility diagnostic.
- `3ad4fda` wires packaging tasks, pins gh, and makes musl tests static.
  Native Linux passes 97 module tests with eight expected skips, all 31
  repository tests, 42 command cases, 25 ranking vectors, 21 terminal scenarios,
  and nine focused picker scenarios.
- Nix evaluates all four systems and both aliases. Native aarch64 package
  tests, completions, and development shell verification pass. Nix's xattr
  filter causes explicit fixture skips; ordinary Linux verification requires
  xattrs and ACLs and passes both real cross-device cases.
- `6c4daab` removes Rust source, Cargo manifests, Cargo-dist, and Rust tool
  tasks after compatibility passes. The final shared `mise run ci` passes.
- Release archives validate for all four targets. Apple Silicon native smoke
  and source installation with a spaced prefix pass.
- The final executable was benchmarked again against the retained Rust release:
  seven alternating samples per side, 1,000 candidates, exact work counts,
  and no errors. Results are in `tests/terminal/final-benchmark-results.json`.
  Timing remains inconclusive; no limiter profile or speedup claim is supplied.

The coordinator reviewed and finished the interrupted picker and move work.
Repository provenance had already passed independent review.
The requested Sol workers initially exhausted their allowance. A subsequent
six-slice Sol-high review completed on `32c24bc`. Its findings are tracked in
the review-fix work; the earlier passing suites did not cover these edge cases.

### Review repairs

- `4c65d85` restores CSI-u press events, shifted Tab, keypad Enter, and
  Linux-console function keys. All 16 focused PTY scenarios pass.
- `7475a25` and `eb3b714` protect persisted configuration from serialization
  overflow, preserve source selection, timestamps and float coercion, restore
  decoder diagnostics, and accept unused sequence tails. Binding replacement
  has one configuration-owned implementation.
- `c1e9458` and `ccab1d0` restore CLI UTF-8 validation, diagnostic context,
  suggestions, and short-option completion. Shared checks run 56 diagnostic/
  preservation cases and 45 completion cases without requiring Rust.
- `05adc93` restores stdin state and bounds output fault injection.
  `1daa7c9` force-kills and reaps aborted children, including children that
  ignore SIGTERM. Native Linux passes all 29 applicable process tests.
- `975b899` and `6a16a34` preserve repository initialization policy and literal
  session names. All 35 executable regression scenarios pass on macOS and Linux.
  Initialization phases and branch policy are documented in `src/repos/init.md`.
- `af4b05c` adds an explicit required-notice manifest and independent package
  tests, refreshes the developer guide, and documents the narrow synchronous
  native-backend exception to the explicit `Io` contract.
- The shared checks include packaging, CLI, and repository regressions.
  `scripts/linux-check.sh` runs these checks too.

Evidence at `6a16a34`: `.audit/review-final-ci.log`,
`.audit/linux-review-final.log`, `.audit/review-final-archives.log`, and
`.audit/review-final-install.log`. Native Linux reports 131 module tests passed
with eight expected skips, 42 stored command cases, 25 ranking vectors,
21 strict terminal scenarios, and 16 focused picker scenarios.
The benchmark verdict remains inconclusive; these repairs claim no speedup.
Targeted independent Sol-high closure reviews passed for picker/packaging,
CLI, process cleanup, and repository initialization. Configuration review
verified the original repairs and found the trailing-sequence case, which
`eb3b714` fixes with 34 differential comparisons and normal module regressions.
No cross-family review was requested or substituted.

## Decisions

The decision trail is `docs/zig-decisions.tsv`.

All requested workers use GPT-6.1 Sol with high reasoning. Independent attempts on this model are same-model review. Cross-family review is unavailable under the current model configuration.
