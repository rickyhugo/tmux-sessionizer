# Terminal verification

This report records independent verification for the Rust-to-Zig rewrite. It does not verify a Zig binary.

## Reference artifact

The worktree starts at `50ad3a80f15b5a29bd442417e4da081d5a5bbcd2`.
Its Rust source matches `a91ea21780acb58eced5b7f52da7f212f6ca33f0`.
The reference build command was `mise exec -- cargo build --release --locked`.

The tested executable is `target/release/tms`, version `tmux-sessionizer 0.6.1`.
Its SHA-256 is `d3e5deaaa76f4f4208bdaa9e52759dfaff5c14788742fffe08b8ef784b93a1d0`.
The host was macOS 26.6.2 on arm64, with 10 logical cores.
The runs used mise's Python 3.14.7 and tmux 3.8 on 2026-11-13.

## Terminal results

The reference run recorded 14 passes and three explicit baseline defects.
The [terminal results](../tests/terminal/rust-baseline/terminal-results.json) contain each verdict.

The passing assertions cover:

- Top and bottom prompts, Escape cancellation, and Ctrl-C cancellation.
- Direct PTY confirmation of `café`, its actual attached tmux session, and its repository working directory.
- Unicode scalar insertion, cursor movement, backspace, and forward deletion.
- Resize from 100 by 24 cells to 42 by 12 cells.
- Custom Ctrl-Q cancellation and custom Ctrl-X confirmation.
- Configuration-error exit with unchanged terminal modes.
- Real `display-popup -E` cancellation without a session change.
- Popup confirmation of `beta`, its selected client session, and its repository working directory.
- Bold styling of an unselected `active.repo` whose actual session is `active_repo`.
- Absence of bold styling on an unselected inactive repository.
- Session previews containing text emitted by a real tmux pane.
- Window previews containing text emitted by a different real tmux window.
- Confirmation of the previewed session and window through tmux's actual selected state.
- Terminal restoration after the attached popup client detaches.

The three known defects are not passing checks:

| Check | Observed defect |
| --- | --- |
| Wide-character cursor | Typing `界` leaves the cursor at zero-based column 3. Display width requires column 4. |
| Tiny terminal | A 1 by 1 terminal receives cursor position `CSI 1;3 H`, outside its bounds. Some runs also fail to exit after Ctrl-C within five seconds. |
| SIGTERM restoration | The target exits with signal 15 while raw-mode terminal flags and the alternate screen remain enabled. |

`--require-improvements` converts those findings to failures.
A separate strict run returned exit code 1 and failed exactly these three checks.
Its [results](../tests/terminal/rust-baseline/strict-results.json) are retained.
The option is the improvement gate for a candidate that must fix the known defects.
Without the option, known defects remain visible as `BASELINE_DEFECT`, not `PASS`.
Unrelated setup or readiness failures always remain failures.

## What the terminal driver observes

`scripts/terminal_checks.py` launches the executable with a controlling PTY.
It reads the current screen before an action, sends the action, and reads again until an assertion becomes true.
Deadlines use PTY readiness and process state, not fixed sleeps.
Each snapshot drains at most four 64 KiB reads and checks a 50 ms deadline between reads.
Continuous output cannot prevent the surrounding wait or exit deadline from running.
The driver compares semantic screen content rather than complete byte-identical frames.

Each fixture has a fresh HOME, configuration file, Git repositories, and tmux socket name.
The fixture PATH contains only `tmux`, `git`, `ls`, and `sh`.
No fzf executable is available.
Every tmux invocation uses the fixture's `-L tms-check-...` socket and `/dev/null` configuration.
Candidate calls pass through an exec launcher that accepts only `-L FIXTURE_SOCKET` before the command.
Missing, joined, repeated, or additional global options fail before tmux starts.
The launcher injects the private socket and configuration, then replaces itself with real tmux.
It does not simulate attach or switch commands.
Driver setup and observations use the real tmux executable directly.
Artifact metadata runs `--version` inside a fixture too.
Popup checks attach a real client through another controlling PTY before opening `display-popup -E`.
No check addresses the user's default tmux server.
Fixture directories and private servers are removed at the end.

JSON transcripts include before-action screens, input bytes, fresh screens, cursor positions, observed terminal modes, and chosen tmux state.
The `.vt` files retain the original terminal output.
The VT reader tracks Unicode display cells, cursor visibility, alternate-screen mode, bold styling, and ANSI foreground and background colors.
The driver suite now has 16 tests.
They cover split UTF-8, split control sequences, erasure, color attributes and resets, exact readiness counts, terminal queries, bounds, rejection of an exit-only process, and cleanup of an attached tmux client.
Fake-executable tests reject unsafe launcher arguments without calling real tmux.
They also verify that valid attach and switch calls exec the target with private options.
A continuous writer on a real PTY tests timeout failure and cleanup.
Benchmark regressions reject wrong counts even when the selected row is correct.

A follow-up run with these checks kept 14 passes and the same three baseline defects.
Full strict mode failed exactly those three checks.
The follow-up resize check observes the new layout before sending any key.
The retained baseline files and archive remain unchanged.

On Darwin, a session leader's exit revokes its controlling tty.
A supervisor records termios after the target exits but before that revocation.
Terminal restoration compares flags, speeds, and control characters.
The comparison ignores only `PENDIN`, the kernel's transient retype-pending flag.
Raw attributes remain in the transcript.

## Added interaction coverage

A separate run on 2026-11-13 tested the same Rust executable with the extended driver.
It recorded 17 passes and four explicit baseline defects.
The original result files and evidence archive remain unchanged.

The added checks cover:

- All five configured `picker_colors` values on rendered cells, including the prompt foreground, selected text foreground and background, border, and counter.
- Directory previews through `init-repo`, with spaces and Unicode in both directory paths and previewed filenames.
- Selection of the second directory, replacement of its visible preview, and cancellation without repository creation.
- A real attached client resized to 50 by 40 cells before opening a popup.
- Vertical session previews above the list, navigation to the second item, replacement of the visible pane content, and confirmation of that actual tmux session.
- SIGHUP after picker initialization, with terminal modes observed after the target exits.

Rust exposes `picker_colors.prompt_color`, not a configurable prompt string.
The color check observes the actual `> ` prompt.
The VT reader stores immutable per-cell bold, foreground, and background attributes.
It accepts basic, bright, indexed, and RGB ANSI colors.
Unit tests check that color payloads do not change bold state and that resets and resize preserve the expected attributes.

SIGHUP is the fourth historical defect.
The Rust target exits with signal 1 while raw terminal flags and the alternate screen remain enabled.
Normal mode reports `sighup-restoration` as `BASELINE_DEFECT`.
The full strict run exits with code 1 and fails exactly `wide-cursor`, `tiny-terminal`, `sigterm-restoration`, and `sighup-restoration`.
All 17 other checks pass in both modes.
The 16 terminal-driver unit tests and six compatibility-isolation unit tests pass.
No benchmark was run for this coverage change.

The separate run directories are `$TMPDIR/opencode/tms-rust-coverage-followup` and `$TMPDIR/opencode/tms-rust-coverage-strict`.
Each contains `results.json`, raw `.vt` output, and JSON transcripts.
These directories are local evidence, not additions to the historical archive.
The executable SHA-256 remains `d3e5deaaa76f4f4208bdaa9e52759dfaff5c14788742fffe08b8ef784b93a1d0`.

The added coverage was run with:

```sh
mise exec -- python -m unittest discover -s tests/terminal -v
mise exec -- python -m unittest discover -s tests/compat -v
mise exec -- python scripts/terminal_checks.py --binary /Users/hugo.englund/personal/tms-zig-terminal-tests/target/release/tms --output "$TMPDIR/opencode/tms-rust-coverage-followup"
mise exec -- python scripts/terminal_checks.py --binary /Users/hugo.englund/personal/tms-zig-terminal-tests/target/release/tms --require-improvements --output "$TMPDIR/opencode/tms-rust-coverage-strict"
```

## Timing results

The verdict is **INCONCLUSIVE**.
The original reference run has no Zig comparison or measured application limiter.
These are observed end-to-end PTY latencies, not evidence of an implementation speedup.

The [benchmark results](../tests/terminal/rust-baseline/benchmark-results.json) retain seven samples, their ranges, artifact hashes, work counts, and errors.
Each sample discovers 1,000 real empty Git repositories.
It waits for all 1,000 candidates, writes one complete unique query, and waits for the selected result.
The selected-result assertion excludes the input prompt.
New samples parse the complete counter row as integers and require exact matched and candidate counts.
They record the observed startup and search counts in `observed_counts`.
The retained timing evidence predates this validation change.
No extra key is sent to wake a stalled matcher.
Every sample validates cancellation and terminal restoration.
All seven samples completed the work with zero failures.

| Observation | Median | Range | Samples |
| --- | ---: | ---: | ---: |
| Version launch to validated exit | 4.701 ms | 3.990 to 10.465 ms | 7 |
| Picker launch to all candidates rendered | 23.421 ms | 18.725 to 62.107 ms | 7 |
| Query write to unique selected result | 3.289 ms | 2.846 to 6.682 ms | 7 |
| Picker launch to that search result | 26.517 ms | 21.875 to 68.796 ms | 7 |

Fixture creation and Python supervisor startup are outside picker timings.
Target subprocess launch, repository discovery, tmux queries, matching, rendering, PTY delivery, and Python screen observation remain inside.
Version timing includes its subprocess launch.
The filesystem is warm. Each sample starts a new application process and matcher.
No warmup sample is discarded.

The one-minute load average was 20.20 on 10 logical cores.
A separate process snapshot found substantial Jamf Protect and Chrome activity.
The snapshot does not identify the application's limiter.
The terminal suite ran concurrently with this baseline timing run.
The timings cannot support an adoption decision under these conditions.

The comparator was also exercised with the same Rust artifact under both labels.
That is a driver control, not a Zig measurement.
Its two-label output is retained in the evidence archive.
The samples alternate Rust, Zig, Rust, Zig when two paths are supplied.
There must be at least five samples per side.
`--release-builds` requires the caller to attest production-optimized builds.
The script does not infer compiler optimization settings from a binary.
It always reports `INCONCLUSIVE` because it does not collect a separate application profile.
Failures appear in `errors` and cause a nonzero exit.

## Commands and retained evidence

### Integrated Zig comparison

The full optimized Zig application passed all 21 strict PTY and popup checks on
macOS arm64. Its SHA-256 was
`c0e17565e6f62a0aeab99ce1e78bc023e52d1b7cc1175be56b42e8ad0f664bd8`.
The separate picker driver also passed suspend/resume and allocation-failure cleanup.
Blocked-output, malformed-input, doubled-Escape, and contextual-width fixes
subsequently passed seven focused PTY regressions and all 21 full application checks.
That executable's SHA-256 was
`e4ca174dd5431532339fd8628048cc88c38389be4c64b2474e1dff5063c7e2f0`.

The [integrated comparison](../tests/terminal/zig-integration/benchmark-results.json)
records seven alternating release samples per implementation over 1,000 repositories.
Every sample verified exact candidate counts, one selected result, and cleanup.
There were no errors.

| Observation | Rust median (range) | Zig median (range) |
| --- | ---: | ---: |
| Picker startup | 20.327 ms (17.862–122.723) | 18.454 ms (16.924–144.112) |
| Query to selected result | 2.803 ms (2.708–6.265) | 1.805 ms (1.792–2.128) |

The verdict remains **INCONCLUSIVE**. The limiter and observer overhead were not
measured. Other migration work ran concurrently. Startup spread exceeds the median
difference. These observations establish completed work, not a speedup.

### Reference reproduction

The following commands reproduce the reference checks from this worktree:

```sh
mise exec -- cargo build --release --locked
mise exec -- python -m unittest discover -s tests/terminal -v
mise exec -- python scripts/terminal_checks.py --binary target/release/tms --output "$TMPDIR/opencode/tms-rust-terminal"
mise exec -- python scripts/terminal_checks.py --binary target/release/tms --require-improvements --pty-only --output "$TMPDIR/opencode/tms-rust-strict"
mise exec -- python scripts/benchmark.py --rust target/release/tms --release-builds --samples 7 --candidates 1000 --output "$TMPDIR/opencode/tms-rust-benchmark"
```

The strict Rust command intentionally exits with code 1.
`TMS_BIN` can replace `--binary`.
`--pty-only` omits the popup checks.
Output directories are overwritten by a repeated run with the same case names.

The candidate invocations accept independently built release artifacts:

```sh
mise exec -- python scripts/terminal_checks.py --binary /absolute/zig-out/bin/tms --require-improvements --output "$TMPDIR/opencode/tms-zig-terminal"
mise exec -- python scripts/benchmark.py --rust /absolute/rust-release/tms --zig /absolute/zig-out/bin/tms --release-builds --samples 7 --candidates 1000 --output "$TMPDIR/opencode/tms-comparison"
```

The committed [evidence archive](../tests/terminal/rust-baseline/evidence.tar.gz) contains terminal output, JSON transcripts, strict-run output, benchmark transcripts, and the same-binary comparator control.
The readable result files beside it are copies of the archived results.
The original run directories are under `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/`.

## Limits

- The runs verify macOS arm64 only. Linux, musl, macOS x86_64, and Linux arm64 remain unverified.
- The screen reader implements the VT subset emitted by these runs, not a complete terminal emulator or pixel comparison.
- Vertical directory and window preview layouts remain unverified.
- Error restoration uses invalid configuration before raw mode. Restoration after a runtime terminal-I/O error remains unverified.
- SIGTERM and SIGHUP are tested. Suspend/resume was verified through the separate Zig picker driver.
- Timing covers a unique query entered as one input burst over 1,000 empty repositories. It does not measure preview latency, large Git histories, network filesystems, or human keystroke cadence.
- No application CPU, syscall, or I/O profile was collected. The timing limiter and observer overhead remain unresolved.
- The integrated Zig comparison above covers macOS arm64. Linux runtime verification is separate.
