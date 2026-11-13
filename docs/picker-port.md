# Native Zig picker

The picker preserves stable item IDs and original labels without fzf. Its only subprocess preview dependency is tmux. Directory previews use native enumeration and libc locale collation, not `ls`.

## Ownership

`src/picker.zig` owns the pure reducer and picker loop. Configuration supplies resolved bindings through `config.pickerOptions`. The reducer does not add a second set of defaults. Rendering supplies the reference color defaults when a color remains absent.

Private modules own input decoding, terminal lifetime, previews, rendering, and Unicode width. Query editing counts Unicode scalars. Cursor placement and clipping measure complete text prefixes with the same upstream width rules. Clipping preserves complete extended grapheme clusters, including width rules that span several clusters.

The result allocator is unused because the result is an item ID. The scratch allocator owns the query, candidate-label array, and current ranked indices. Every replacement ranking frees the previous result. A resettable frame arena owns preview output and rendering bytes. No keystroke allocation survives in the command arena.

One terminal owner saves attributes, descriptor flags, and signal handlers. Nonblocking output retains partial writes and checks pending signals between polls of at most 50 milliseconds. Cleanup restores attributes before one best-effort, nonblocking escape write. A saturated output queue can prevent screen restoration sequences, but cannot block attribute restoration.

SIGTERM, SIGHUP, SIGINT, and SIGQUIT restore attributes before re-raising the original signal. SIGTSTP restores them before suspension. Resume re-enters raw mode and redraws. SIGWINCH redraws without a keypress.

Darwin `poll` rejects the `/dev/tty` alias. The owner reopens the concrete terminal device returned by `ttyname_r`. Saved-attribute comparisons ignore only Darwin's kernel-set `PENDIN` retype flag.

Labels cannot emit terminal control sequences. Previews accept bounded numeric SGR sequences and discard other escapes, OSC payloads, and control characters.

## Unicode sources

`width.zig` translates the non-CJK width rules from unicode-width 0.2.0 and extended grapheme boundaries from unicode-segmentation 1.12.0. Their Unicode versions are 15.1 and 16.0. The MIT notices are in `src/picker/LICENSE-unicode-width`.

`width-data.bin` contains sorted, fixed-width property records. It is compiled into the executable. Width calculation does not depend on the process locale.

`generate-width-data.py` checks both source hashes and the reference Rust 1.99.0 compiler before regeneration. Rust and Python are development-only regeneration tools.

```sh
mise exec -- python3 src/picker/generate-width-data.py /path/to/unicode-width-0.2.0/src/tables.rs /path/to/unicode-segmentation-1.12.0/src/tables.rs
```

## Executed verification

The host was macOS arm64. Zig 0.17.1 built the temporary native driver through mise. The driver used the real matcher and tmux adapters, explicit reference bindings, and candidate IDs unrelated to injection indices.

- All 21 picker unit tests pass. They cover every editing action, Unicode scalar edits, modified bindings, wrapping, result clamping, fragmented UTF-8 and escape sequences, sanitization, directory previews, display widths, grapheme clipping, and tiny dimensions. New cases cover invalid continuation bytes at every UTF-8 prefix length, buffered double Escape, and contextual clipping across grapheme boundaries. A seeded test compares incremental clipping against full-prefix widths for 500 mixed Unicode strings.
- All 24 controlling-PTY scenarios pass with the production-optimized driver. Each completed scenario compares saved terminal attributes and screen restoration.
- PTY scenarios cover original-ID confirmation, top and bottom navigation, Ctrl-J versus Enter, cancellation, custom bindings, no-match recovery, fragmented Unicode editing, C-locale wide/combining/emoji cursors, resize through zero and one-cell sizes, repeated edits, four termination signals, suspend/resume, and real session/window capture previews.
- Three PTY cases inject allocator failures after terminal entry. They verify restoration after label, ranking, and frame allocation errors.
- A temporary differential oracle matches upstream width and first-grapheme results for 6,651 deterministic Unicode vectors.
- All seven checked-in focused PTY scenarios pass. They cover fragmented invalid UTF-8 cancellation, buffered double Escape, saturated output during SIGTERM, complete partial writes, and Arabic, Lisu, and Hebrew query clipping with scalar edits. The baseline fails all defect cases. The partial-write control passes before and after the fixes.
- Native driver cross-compilation succeeds for macOS x86_64, Linux x86_64 GNU, and Linux x86_64 musl. These are compile checks, not runtime verification.

`mise exec -- zig build test` runs the committed module tests. Temporary driver sources, PTY transcripts, and differential tools remain under `$TMPDIR/opencode/picker-*` for parent integration. The latest PTY report is `picker-pty-evidence/results.json`.

`mise exec -- python3 src/picker/regression-pty.py` builds the checked-in focused driver with the real matcher. Every module uses ReleaseFast. The runner uses controlling PTYs and checks saved attributes before draining output after exit. The saturated-output case never drains the master after the wide frame starts and requires signal exit within two seconds. `--binary /path/to/driver` tests an existing compatible driver.

## Bounded contextual clipping

Backward context convergence did not bound work. Repeating the Tifinagh letter
and joiner 512 times required 524,288 width transitions; 1,024 pairs required
2,097,152. The old clipping loop therefore grew quadratically.

Two independent designs considered conditional prefix costs. One used a closed
240-context superset; the other identified 76 reachable contexts from the pinned
tables and transition rules. Clipping now uses the smaller set, checked against
table endpoints and contextual transitions.

Each vector entry is the signed cost of scanning the current prefix backward from
that right-hand context. Appending a scalar computes its transition once per
context, then adds the previous cost at the resulting context. Two fixed vectors
bound work to 76 transitions per scalar. Unicode table lookup is shared across
those transitions. Costs remain signed until the normal-context result is read.
Every grapheme boundary is considered because later characters can reduce width.

The nine focused PTY checks include a 65,534-scalar Tifinagh query and suspension
while initial terminal output is blocked. Initial entry and re-entry use the same
suspension loop. Three consecutive stop/resume cycles must restore attributes,
resume input, and permit cancellation. The coordinator reproduced the quadratic
unit failure and verified all nine PTY checks after the changes.

## Reviewed input regressions

Review of `32c24bc66b14c396c92469fff3a12880aa5b7daf` found three input
regressions against the retained Rust picker: explicit CSI-u press metadata was
discarded, shifted Tab and keypad Enter lost their semantic key codes, and Linux
console F1 inserted `A` instead of invoking its binding.

Before changing the decoder, the new tests reproduced three unit failures and
four PTY binding failures on that base. The legacy SS3 F1 control passed.
The fixes preserve the locked crossterm 0.28.1 event-kind rules and the Rust
picker's press-only policy. Explicit presses reach bindings. Repeat and release
events are consumed without editing or invoking actions. Missing, invalid, or
unknown event kinds retain the reference's Press default.

Decoder tests cover every byte split for the repaired sequences, F1-F5 console
codes, and non-press events. Unknown console sequences cannot insert their final
byte; an interrupting control key remains available for cancellation.
The fixes do not change matching, IO interfaces, or terminal ownership.

On macOS arm64 with Zig 0.17.1, all 15 input/width tests, all 27 picker tests,
and all 16 focused ReleaseFast PTY scenarios pass. These are native macOS checks,
not Linux-console runtime verification. The console key bytes are exercised
through controlling PTYs.

```sh
MISE_AUTO_INSTALL=false mise exec -- zig test --dep config \
  -Mroot=src/picker/input.zig -Mconfig=src/config.zig
MISE_AUTO_INSTALL=false mise exec -- zig test -lc \
  --dep config --dep matcher --dep tmux -Mroot=src/picker.zig \
  -Mconfig=src/config.zig -Mmatcher=src/matcher.zig \
  --dep process -Mtmux=src/tmux.zig -Mprocess=src/process.zig
MISE_AUTO_INSTALL=false mise exec -- python3 src/picker/regression-pty.py
```

## Compatibility and limits

The approved improvements use display-cell cursor placement, safe tiny-size arithmetic, signal cleanup, and immediate rendering after matching completes.

The reference's narrow vertical-preview behavior remains unchanged. Rendering puts input below the list, while navigation follows the configured input position.

The renderer is not a pixel-identical ratatui replacement. Full application, attached-popup, configuration-default integration, packaging, and performance checks belong to the parent. Linux runtime behavior remains unverified. Previews and matching remain synchronous, so signal handling waits for an in-progress preview or ranking call to return.
