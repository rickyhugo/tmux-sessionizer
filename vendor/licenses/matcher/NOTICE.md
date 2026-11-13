# Matcher provenance

`src/matcher/engine.zig`, `pattern.zig`, and `scoring.zig` translate the behavior of nucleo-matcher 0.3.1 and nucleo 0.5.0.
The upstream author is Pascal Kuthe.
Both crates declare MPL-2.0.
The complete upstream license is `nucleo-MPL-2.0.txt`.
The translation omits highlight reconstruction, threading, and incremental snapshots because the public API returns ranked indices for one query.

Pinned crates.io archive SHA-256 values:

| Archive | SHA-256 |
| --- | --- |
| nucleo-matcher-0.3.1.crate | `bf33f538733d1a5a3494b836ba913207f14d9d4a1d3cd67030c5061bdd2cac85` |
| nucleo-0.5.0.crate | `5262af4c94921c2646c5ac6ff7900c2af9cbb08dc26a797e18130a7019c039d4` |
| unicode-segmentation-1.12.0.crate | `f6ccf251212114b54433ec949fd6a7841275f9ada20dddd2f29e9ceea4501493` |

`unicode.zig` translates the extended-grapheme boundary rules in unicode-segmentation 1.12.0.
That crate declares MIT OR Apache-2.0 and attributes its tables to The Rust Project Developers.
Its original license and copyright files are retained here.

`tables.zig` contains generated data from these pinned inputs:

- Simple case folding from nucleo-matcher's `src/chars/case_fold.rs`, generated upstream for Unicode 15.0.0.
- Latin normalization from nucleo-matcher's `src/chars/normalize.rs`.
- Grapheme categories and Indic-conjunct extension properties from unicode-segmentation 1.12.0, Unicode 16.0.0.
- Character properties from Rust 1.99.0, commit `b940084d7eb6a299eb4bfeb8e34901bc051e7ac4`, Unicode 17.0.0.

The Rust distribution's `share/doc/rust/COPYRIGHT-library.html` identifies `library/core/src/unicode` as Unicode-3.0, copyright 1991-2024 Unicode, Inc.
`Unicode-3.0.txt` is the unchanged license from that distribution's `share/doc/rust/licenses/Unicode-3.0.txt`.
No Rust source or library is linked into the Zig program.

`scripts/generate-matcher-tables.py` verifies archive checksums and the Rust compiler commit before generation.
It evaluates the upstream normalization function instead of interpreting its sparse data.
This preserves the upstream `generate_table` behavior that reads `DATA1` values for all three tables.
The development generator needs Rust. The matcher and executable do not.
