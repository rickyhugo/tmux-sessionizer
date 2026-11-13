# tomlc17

Native C17 TOML parser by CK Tan, under the MIT license in `LICENSE`.
The header and license are unmodified. The C source has three local compatibility
patches.

Revision `aa4ca1bc5fe6382ac631a8d1428077a9a084a64d`.

Source URLs:

- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/src/tomlc17.c
- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/src/tomlc17.h
- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/LICENSE

Upstream SHA-256:

| File | Hash |
| --- | --- |
| `tomlc17.c` | `7476923b6c9b8f0858b82b63ed6107f57448882983390e70c31327f7d3e2a362` |
| `tomlc17.h` | `29c0909092f4b23c7edce705167064f4a90548db5334b4aa2cd95d7ad801adb9` |
| `LICENSE` | `f949d0976f85076c96fc5122f0632b5a1b806d8b2badbe968c42c97230e6e79e` |

## Local patches

`is_valid_time` accepts seconds through 60 instead of 59. This matches the
reference's `toml_datetime` 0.7.5 leap-second range for local times, local
datetimes, and offset datetimes. The parser has no option for this range.
Hours and minutes retain their upstream bounds. Seconds above 60 remain invalid.
Source bytes and decoded timestamps are not rewritten.

`is_valid_date` accepts year zero, matching the reference's four-digit
`toml_datetime` year range. Month, day, and leap-year checks are unchanged.

The float parser accepts `ERANGE` when `strtod` produces a finite value, including
signed zero. Rust accepts underflow such as `1e-999` as zero. The upstream parser
already accepts finite subnormals but rejects underflow to zero. Overflow to
infinity and other conversion errors remain invalid.

Patched `tomlc17.c` SHA-256:
`6e22c4543009586445f118467d297b189d35a6c5eab2969f6aba31063bbe79b6`.

`src/cli/check.py` compares leap-second exports and invalid time rejection
against the Rust reference. Tests in `src/config.zig` cover year-zero dates,
signed-zero underflow, and continued rejection of invalid dates and overflow.
These tests run through `zig build test` without a Rust oracle.

`src/config/toml.zig` owns recursive merge semantics. It replaces arrays rather
than using the parser's array-of-tables append operation.
