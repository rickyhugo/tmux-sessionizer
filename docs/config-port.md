# Configuration and CLI port

## Public contracts

`src/config.zig` keeps every raw field optional. Empty lists and maps do not become
absent values. `commit` saves the merged raw model. `exportToml` resolves defaults
and omits `input_position` and deprecated `search_paths`.

`src/config/toml.zig` copies native TOML values into the command allocator, merges
tables recursively, and replaces arrays before typed decoding. Unknown fields do
not survive a save. Decoding retains the config crate's Boolean, number, string,
enum-table, and sequence-struct conversions. Ratatui's legacy color maps retain
their stricter untagged decoding.

Sequence structs require their declared field count as a minimum, including
optional fields. Like the Rust Serde visitor, decoding consumes that prefix and
ignores trailing values without decoding their types. This also applies to the
zero-field `Pane`. The TOML parser still validates the entire source, including
unused trailing values. Short sequences retain their indexed length diagnostic.

`load` selects only `TMS_CONFIG_FILE` when present. Otherwise it loads
`~/.config/tms/config.toml` and then the platform config location. Saving selects
the override or platform location. Missing files are optional. Extension inference,
unregistered file extensions, a UTF-8 BOM, and lossy UTF-8 file decoding follow the
reference's TOML-only config source.
Optional sources also suppress stat, open, and read failures. Parser and decoder
failures remain fatal. A selected but unreadable source does not trigger extension
inference for another filename.

Serialization rejects unsigned depths above TOML's signed 64-bit range before
creating the destination directory or replacing the configuration file. Export
rejects the same values. NaN-to-string coercion produces `NaN` for every TOML sign.

Path expansion supports braced and unbraced variables, literal `${NAME:-fallback}`
defaults, escaped dollars, and a leading tilde. Empty variables remain empty even
when a fallback exists. A variable-supplied tilde does not expand. Variable names
use Unicode 17 alphanumeric properties, matching the pinned Rust toolchain.
Expansion does not require an existing path. Roots, bookmarks, and valid marks
canonicalize separately.

Automatic mark allocation considers only valid numeric indices with usable paths.
Raw marks retain invalid paths for explicit lookup. Bookmark edits compare literal
stored strings and suppress duplicate additions.

`src/cli/spec.zig` defines command names, positional arguments, option names,
descriptions, and enum values. Parsing, help, and static completion use that model.
`complete` runs before ordinary parsing and supports Bash, Elvish, Fish,
PowerShell, and Zsh. Dynamic session completion returns catalog visible keys,
not session names. Mark completion includes only valid marks.
Repeated vector options append values. Scalar options still reject repetition.
An attached short-option value consumes at most one `=` separator.

Completion disables `COMPLETE` in the inherited process environment before
discovery. Otherwise child tools such as jj can return their own completion
scripts instead of repository data. It sets `COMPLETE=0` rather than removing
the entry because Zig's IO backend retains the original environment block length.

## Diagnostic integration

The frozen `parse` and `load` signatures remain unchanged.

- `cli.parse` returns `error.InvalidArguments` and sets `cli.failure`.
- `cli.complete` sets `cli.failure` for unsupported shells and an invalid completion index.
- `config.load` sets `config.failure` when loading or deserialization fails.
- Each failure is a typed `Diagnostic` with `text` and `exit_code`.
- Each entry point clears its previous failure before work.
- `cli.parseDetailed` returns `ParseResult.command` or `ParseResult.diagnostic`.
- `config.loadDetailed` returns `LoadResult.config` or `LoadResult.diagnostic`.
- `config.editDiagnostic(err)` formats missing paths, access errors, missing or invalid search roots, unnamed root marks, and removal without an exclusion list.

The application can keep calling the frozen entry points. On failure, the parent
must write the relevant diagnostic's `text` to stderr and exit with `exit_code`.
It must not return the Zig error after printing, because that adds an error trace.
Argument errors exit 2. Config errors exit 1. The reference's unsupported-completion
and remove-without-exclusions failures retain exit 101.

The driver in `src/cli/driver.zig` demonstrates this handling without changing
`main.zig` or `app.zig`. It supports config, bookmark, and non-opening mark commands.
The parent still owns version consolidation and the default native-parser build path.

## Verification

Native build and module tests:

```sh
mise exec -- zig build -Dtomlc17=vendor/tomlc17
mise exec -- zig build test -Dtomlc17=vendor/tomlc17
```

Build the scoped driver with local domain modules:

```sh
mise exec -- python3 src/cli/build_driver.py
```

`--domains /absolute/path/to/src` selects integrated session, repository, tmux,
and process modules without changing this worktree's files.

Compare with a separately built Rust reference:

```sh
mise exec -- python3 src/cli/check.py \
  --bin .zig-cache/config-driver \
  --rust /absolute/path/to/target/debug/tms \
  --dynamic --jj
```

Executed results:

- 615 static completion probes across all five shells passed.
- All five registration scripts matched after executable-path substitution.
- 13 exported configuration comparisons passed.
- 42 long, short, and generated-help comparisons passed.
- 23 settings, bookmark, and mark persistence comparisons passed.
- 200 dynamic visible-key and valid-mark completion probes passed against the parent's integrated domain modules.
- 40 mixed Git/jj completion probes passed across all five shells, with linked workspaces and both worktree-list settings.
- 11 argument regressions passed, including repeated vectors, attached equals signs, scalar repetition, and help after a missing value.
- Five leap-second exports and three invalid-time rejections matched Rust.
- 19 EOF-array diagnostic comparisons and six conservative-fallback checks passed.
- An unreadable optional TOML source matched Rust's default configuration.
- The unchanged compatibility runner passed `help`, `argument-errors`, `config-defaults`, `config-edit`, `config-remove-without-exclusions`, `config-missing-path`, `invalid-config-type`, `invalid-config-enum`, `invalid-config-keymap`, `config-type-coercion`, and `unknown-config-key`.
- Config test artifacts compiled for `x86_64-linux-gnu` and `aarch64-linux-musl`. These were compile-only checks, not Linux runtime tests.
- The updated full executable also compiled for both Linux targets. No Linux runtime test ran.

The module tests cover malformed TOML, merge precedence and replacement,
absent versus empty values, platform locations, raw saves, defaults, edits,
canonical paths, invalid marks, Unicode variable names, keys, colors, enum-table
and sequence-struct coercions, and nanosecond timestamp conversion.

No fixture or golden changed. Neither executable reads a golden.

## Parser diagnostic conversion

The native parser still decides acceptance and receives the original source.
It exposes an error category and line, but no failure column. After rejection,
`src/config/diagnostic.zig` recognizes EOF inside arrays with a diagnostic-only
delimiter scanner. It tracks comments, quoted strings, nested arrays, and table
headers. Native EOF categories become the reference's unclosed-array diagnostic,
with a source excerpt and Unicode-aware column. EOF after a newline uses the
reference parser's preceding-line convention. No config key or fixture text is
recognized.

Earlier syntax errors and ambiguous recovery, including inline tables, retain
the native diagnostic. This is not full Rust-parser diagnostic equivalence.
Full equivalence would require its lexer, recovery rules, and error ordering,
not only a native-message translation table.

Decoded enum errors retain the enum representation or variant and the field
index. Short sequence-struct errors retain the Rust struct name, expected element
count, and nested key. These decoder errors are separate from the native parser
diagnostic exemption.

`vendor/tomlc17/README.md` records the leap-second, year-zero, and finite-underflow
compatibility patches and both upstream and patched source hashes.

### Review regressions

Eight additional module tests run through ordinary `zig build test`, without
Rust. They cover byte-for-byte preservation and successful reload after failed
serialization, the signed-64 serialization boundary, an unreadable selected
source with a competing inferred filename, year-zero dates, signed-zero
underflow, NaN coercion, enum and sequence-struct diagnostics, and shared
shortcut replacement semantics. The unreadable-source test skips when run as
root because mode bits cannot make its fixture unreadable.

Each of the seven behavior regressions failed before its corresponding fix.
The binding-policy test covers the behavior-preserving extraction shared by
typed TOML decoding and picker default merging.

Review verification on macOS:

- `MISE_AUTO_INSTALL=false mise exec -- zig build test --summary all` passed
  all build steps: 105 tests passed and eight skipped. All 16 configuration
  tests passed.
- The unchanged `src/cli/check.py --dynamic --jj` runner passed against the
  retained Rust release, including 815 completion probes and 40 jj cases.
- Supplemental review comparisons passed 25 exports or decoder errors, two
  byte-preserving failed mutations, unreadable-source selection, and four
  parser rejection controls.
- Configuration test artifacts compiled for `x86_64-linux-gnu` and
  `aarch64-linux-musl`. These are compile-only checks, not Linux runtime tests.

This workstream does not claim the full application, ranking, or terminal suite.
Those remain integration checks owned by the parent.

### Overlong sequence follow-up

Rust accepts overlong `SessionConfig`, `SearchDirectory`, `Window`, `Session`,
`PickerColorConfig`, and zero-field `Pane` sequences. The decoder now checks
the minimum length before indexing, rather than requiring an exact length.
New module regressions compare exact-length exports with 18 differently typed
tail variants. They also verify that invalid declared fields and malformed TOML
in unused tails still fail. Short-sequence checks include the one-element-short
`Window` and `PickerColorConfig` boundaries.

On macOS, all 18 configuration tests pass. Focused Rust/Zig comparisons pass
24 exact/overlong exports, five short-sequence diagnostics, and five declared
field rejection controls. Both binaries also reject two malformed unused-tail
inputs. Invalid color rejection is checked by status; its pre-existing detailed
diagnostic wording is outside this follow-up. No Linux runtime check is claimed.

## Attribution

`vendor/tomlc17/README.md` records the native parser revision, source URLs,
SHA-256 hashes, and MIT license.

The shell registration templates adapt `clap_complete` 4.5.55
`src/env/shells.rs`. Their MIT notice is in `src/cli/registration/LICENSE`.

`src/config/generate_unicode.py` derives alphanumeric ranges from the pinned
Rust standard library's Unicode 17 database. The checked-in table needs no Rust
runtime. Its Unicode notice is in `src/config/UNICODE-LICENSE`.
