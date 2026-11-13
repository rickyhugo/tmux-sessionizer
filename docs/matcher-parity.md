# Matcher parity

## Contract

`src/matcher/engine.zig` exposes one application API:

```zig
pub fn rank(
    allocator: std.mem.Allocator,
    query: []const u8,
    candidates: []const []const u8,
) ![]usize
```

Inputs are borrowed UTF-8.
The caller owns and frees the returned indices.
Indices refer to original candidates, including duplicate labels.
The matcher never changes the original bytes.
Each call frees all query, Unicode, scoring, and sorting scratch before returning.
Candidate decoding and bounded scoring arrays reuse capacity within the call.
No allocations survive between queries except the caller-owned result.

## Reference behavior

The implementation translates nucleo-matcher 0.3.1 and nucleo 0.5.0 with their default general-text configuration.
It does not use path-specific bonuses.
The scorer uses match score 16, gap-start penalty 3, gap-extension penalty 1, whitespace boundary bonus 10, delimiter boundary bonus 9, non-word bonus 8, camel-case and numeric-transition bonus 5, consecutive minimum 4, and first-character multiplier 2.

Queries split on unescaped ASCII spaces.
Atoms support fuzzy matching, quoted substrings, prefix, suffix, exact matching, negation, escaped spaces, and escaped operator markers.
Negated fuzzy syntax becomes a negated substring.
A pipe is a literal delimiter, not an OR operator.
Each atom decides smart case and asymmetric smart normalization separately.

Pure ASCII text retains one matching unit per byte.
Non-ASCII text retains the first code point of each extended grapheme.
Unicode versions intentionally differ between upstream tables.
Case folding uses Unicode 15.0.0, segmentation uses Unicode 16.0.0, and Rust 1.99.0 character properties use Unicode 17.0.0.
`vendor/licenses/matcher/NOTICE.md` records inputs, checksums, licenses, and generation.

Optimal fuzzy scoring uses the upstream rolling-row recurrence.
Greedy fallback uses the upstream first forward match followed by reverse minimization.
Fallback preserves the 102400-cell limit, the 65535-unit haystack limit, the 2048-unit needle limit, and the 133120-byte slab layout.
The byte-layout check preserves the different ASCII and Unicode character widths and alignment.

Nonempty patterns sort by descending summed score, ascending matching-unit length, then original index.
Patterns with no nonempty atoms preserve injection order.

The port retains observable upstream quirks:

- Case-sensitive ASCII exact matching compares the whole haystack, even for prefix and suffix requests.
- Unicode substring matching excludes the last possible start position and retains its match-only previous-class update.
- ASCII substring prefiltering retains the upstream non-overlapping and truncated searches.
- Unicode backslashes before non-space characters retain the upstream escape-loop behavior.
- Normalization generation evaluates the upstream function, including its use of `DATA1` values for all three generated tables.

## Verification

The matcher passed 25 unchanged stored ranking vectors and 3989 independent deterministic differential vectors against the Rust oracle.
The differential corpus includes random ASCII and Unicode queries, operator combinations, duplicates, combining marks, flags, emoji ZWJ sequences, Indic conjuncts, Hangul, case-folding exceptions, whitespace, and long inputs.
It checks both the matrix-cell boundary and the ASCII-versus-Unicode slab-byte boundary.
Comparisons use exact output bytes.
The checker never rewrites goldens.

All 14 unit tests passed in Debug, ReleaseSafe, and ReleaseFast.
They include 20 upstream default-score vectors, two matrix-boundary scores, 12 slab-boundary scores, observable ordering regressions, and exhaustive allocation-failure cleanup for a mixed Unicode query.
The fallback score expectations were also checked with a temporary Rust program linked to the locked nucleo-matcher crate.

Commands run from the matcher worktree:

```sh
mise exec -- zig test src/matcher/engine.zig
mise exec -- zig test src/matcher/engine.zig -O ReleaseSafe
mise exec -- zig test src/matcher/engine.zig -O ReleaseFast
mise exec -- zig fmt --check src/matcher/*.zig
mise exec python@3 -- python3 scripts/generate-matcher-tables.py
```

The temporary oracle used the foundation worker's production driver, not another checked-in driver:

```sh
SCRATCH=/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode
ORACLE_SOURCE=/Users/hugo.englund/personal/tms-zig-foundation/src/oracle.zig
RUST_ORACLE=/Users/hugo.englund/personal/tmux-sessionizer/target/debug/examples/compat_oracle
mise exec -- zig build-exe --dep matcher \
    -Mroot="$ORACLE_SOURCE" -Mmatcher=src/matcher/engine.zig \
    -O ReleaseSafe -femit-bin="$SCRATCH/tms-matcher-oracle"
mise exec python@3 -- python3 src/matcher/check-parity.py \
    --oracle "$SCRATCH/tms-matcher-oracle" --rust-oracle "$RUST_ORACLE"
```

After integration, `ORACLE_SOURCE` can refer to `src/oracle.zig`.
The production matcher imports only Zig standard-library modules and its own files.
Rust and Python are development-only verification and table-generation tools.

## Remaining verification

No ranking or score mismatches remain in the executed corpus.
This is not an exhaustive proof over all UTF-8 inputs.
Invalid UTF-8 returns a decoding error; the Rust reference accepts UTF-8 strings.
Highlight indices, matcher concurrency, and incremental snapshots are outside the frozen ranking API.
Independent review and application-level picker verification remain parent-owned.
